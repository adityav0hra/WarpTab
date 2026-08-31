import AppKit
import CoreAudio
import Foundation

enum AudioServiceError: LocalizedError {
    case coreAudio(OSStatus)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let status):
            return "Core Audio returned error \(status)."
        case .unavailable(let message):
            return message
        }
    }
}

final class CoreAudioService {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func devices() throws -> [AudioDevice] {
        let ids = try audioObjectIDArrayProperty(
            object: systemObject,
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        )

        return ids.compactMap { id in
            guard let uid = stringProperty(object: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(object: id, selector: kAudioObjectPropertyName) else { return nil }
            return AudioDevice(
                id: id,
                uid: uid,
                name: name,
                transport: uint32Property(object: id, selector: kAudioDevicePropertyTransportType) ?? 0,
                hasInput: channelCount(device: id, scope: kAudioDevicePropertyScopeInput) > 0,
                hasOutput: channelCount(device: id, scope: kAudioDevicePropertyScopeOutput) > 0
            )
        }
    }

    func defaultOutputID() -> AudioObjectID? {
        deviceProperty(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    func defaultInputID() -> AudioObjectID? {
        deviceProperty(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    func setDefaultOutput(_ id: AudioObjectID) throws {
        try setSystemDevice(id, selector: kAudioHardwarePropertyDefaultOutputDevice)
        try? setSystemDevice(id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    func setDefaultInput(_ id: AudioObjectID) throws {
        try setSystemDevice(id, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    func volume(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Float {
        if let master = floatProperty(
            object: device,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        ) { return master }

        let values = (1...2).compactMap {
            floatProperty(object: device, selector: kAudioDevicePropertyVolumeScalar, scope: scope, element: UInt32($0))
        }
        return values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
    }

    func setVolume(_ value: Float, on device: AudioObjectID, scope: AudioObjectPropertyScope) throws {
        let clamped = min(max(value, 0), 1)
        if isSettable(object: device, selector: kAudioDevicePropertyVolumeScalar, scope: scope, element: kAudioObjectPropertyElementMain) {
            try setFloat(clamped, object: device, selector: kAudioDevicePropertyVolumeScalar, scope: scope, element: kAudioObjectPropertyElementMain)
            return
        }

        var changed = false
        for channel in 1...2 where isSettable(object: device, selector: kAudioDevicePropertyVolumeScalar, scope: scope, element: UInt32(channel)) {
            try setFloat(clamped, object: device, selector: kAudioDevicePropertyVolumeScalar, scope: scope, element: UInt32(channel))
            changed = true
        }
        if !changed { throw AudioServiceError.unavailable("This device does not expose a software volume control.") }
    }

    func isMuted(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        (uint32Property(object: device, selector: kAudioDevicePropertyMute, scope: scope) ?? 0) != 0
    }

    func setMuted(_ muted: Bool, device: AudioObjectID, scope: AudioObjectPropertyScope) throws {
        let value: UInt32 = muted ? 1 : 0
        if isSettable(object: device, selector: kAudioDevicePropertyMute, scope: scope, element: kAudioObjectPropertyElementMain) {
            try setUInt32(value, object: device, selector: kAudioDevicePropertyMute, scope: scope)
        } else if scope == kAudioDevicePropertyScopeInput {
            try setVolume(muted ? 0 : 1, on: device, scope: scope)
        } else {
            throw AudioServiceError.unavailable("This device does not expose mute control.")
        }
    }

    @available(macOS 14.2, *)
    func audioApps() -> [AudioApp] {
        guard let processIDs = try? audioObjectIDArrayProperty(
            object: systemObject,
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        ) else { return [] }

        return processIDs.compactMap { processObject -> AudioApp? in
            guard let pidValue = int32Property(object: processObject, selector: kAudioProcessPropertyPID) else { return nil }
            let pid = pid_t(pidValue)
            guard pid != getpid() else { return nil }
            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = stringProperty(object: processObject, selector: kAudioProcessPropertyBundleID)
                ?? app?.bundleIdentifier
                ?? "pid.\(pid)"
            let runningOutput = (uint32Property(object: processObject, selector: kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            guard runningOutput,
                  let app,
                  app.activationPolicy == .regular,
                  app.localizedName != nil else { return nil }
            return AudioApp(
                id: pid,
                processObjectID: processObject,
                bundleIdentifier: bundleID,
                name: app.localizedName ?? URL(fileURLWithPath: bundleID).lastPathComponent,
                icon: app.icon,
                isProducingAudio: runningOutput
            )
        }
        .reduce(into: [String: AudioApp]()) { result, app in result[app.bundleIdentifier] = app }
        .values
        .sorted { lhs, rhs in
            if lhs.isProducingAudio != rhs.isProducingAudio { return lhs.isProducingAudio }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func deviceProperty(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &value)
        return status == noErr && value != kAudioObjectUnknown ? value : nil
    }

    private func setSystemDevice(_ id: AudioObjectID, selector: AudioObjectPropertySelector) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = id
        let status = AudioObjectSetPropertyData(systemObject, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
        guard status == noErr else { throw AudioServiceError.coreAudio(status) }
    }

    private func channelCount(device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func isSettable(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, element: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    private func setFloat(_ value: Float, object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, element: AudioObjectPropertyElement) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var mutable = value
        let status = AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &mutable)
        guard status == noErr else { throw AudioServiceError.coreAudio(status) }
    }

    private func setUInt32(_ value: UInt32, object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var mutable = value
        let status = AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mutable)
        guard status == noErr else { throw AudioServiceError.coreAudio(status) }
    }

    private func stringProperty(object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private func uint32Property(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        scalarProperty(object: object, selector: selector, scope: scope, initial: UInt32(0))
    }

    private func int32Property(object: AudioObjectID, selector: AudioObjectPropertySelector) -> Int32? {
        scalarProperty(object: object, selector: selector, scope: kAudioObjectPropertyScopeGlobal, initial: Int32(0))
    }

    private func floatProperty(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, element: AudioObjectPropertyElement) -> Float? {
        scalarProperty(object: object, selector: selector, scope: scope, element: element, initial: Float(0))
    }

    private func scalarProperty<T>(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value : nil
    }

    private func audioObjectIDArrayProperty(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard sizeStatus == noErr else { throw AudioServiceError.coreAudio(sizeStatus) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var values = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = values.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return OSStatus(-50) }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, baseAddress)
        }
        guard status == noErr else { throw AudioServiceError.coreAudio(status) }
        return values
    }
}
