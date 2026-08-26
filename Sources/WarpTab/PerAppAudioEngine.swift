import CoreAudio
import AudioToolbox
import Foundation

@available(macOS 14.2, *)
final class PerAppAudioEngine {
    private var sessions: [String: ProcessAudioSession] = [:]

    func apply(app: AudioApp, volumePercent: Int, output: AudioDevice) throws {
        let gain = Float(volumePercent) / 100
        if let session = sessions[app.bundleIdentifier], session.outputUID == output.uid {
            session.gain = gain
            return
        }

        sessions.removeValue(forKey: app.bundleIdentifier)?.stop()
        let session = try ProcessAudioSession(app: app, output: output, gain: gain)
        sessions[app.bundleIdentifier] = session
    }

    func remove(bundleIdentifier: String) {
        sessions.removeValue(forKey: bundleIdentifier)?.stop()
    }

    func removeMissingApps(_ bundleIdentifiers: Set<String>) {
        for key in sessions.keys where !bundleIdentifiers.contains(key) {
            sessions.removeValue(forKey: key)?.stop()
        }
    }

    deinit { sessions.values.forEach { $0.stop() } }
}

@available(macOS 14.2, *)
private final class ProcessAudioSession {
    let outputUID: String
    var gain: Float

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(app: AudioApp, output: AudioDevice, gain: Float) throws {
        self.outputUID = output.uid
        self.gain = gain

        do {
            try createTap(for: app)
            try createAggregate(outputUID: output.uid)
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }

    private func createTap(for app: AudioApp) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [app.processObjectID])
        description.name = "WarpTab · \(app.name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw AudioServiceError.coreAudio(status) }
    }

    private func createAggregate(outputUID: String) throws {
        let tapUID = try stringProperty(object: tapID, selector: kAudioTapPropertyUID)
        let uid = "com.warptab.audio.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "WarpTab App Audio",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else { throw AudioServiceError.coreAudio(status) }
    }

    private func startIO() throws {
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { [weak self] _, inputData, _, outputData, _ in
            guard let self else { return }
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let outputs = UnsafeMutableAudioBufferListPointer(outputData)
            guard !inputs.isEmpty, !outputs.isEmpty else { return }

            for index in outputs.indices {
                let source = inputs[min(index, inputs.count - 1)]
                var destination = outputs[index]
                guard let sourceData = source.mData, let destinationData = destination.mData else { continue }
                let byteCount = min(Int(source.mDataByteSize), Int(destination.mDataByteSize))
                let sampleCount = byteCount / MemoryLayout<Float>.size
                let sourceSamples = sourceData.assumingMemoryBound(to: Float.self)
                let destinationSamples = destinationData.assumingMemoryBound(to: Float.self)
                let level = self.gain
                for sample in 0..<sampleCount {
                    destinationSamples[sample] = sourceSamples[sample] * level
                }
                destination.mDataByteSize = UInt32(byteCount)
                outputs[index] = destination
            }
        }
        guard status == noErr, let proc else { throw AudioServiceError.coreAudio(status) }
        ioProcID = proc
        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else { throw AudioServiceError.coreAudio(startStatus) }
    }

    private func stringProperty(object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { throw AudioServiceError.coreAudio(status) }
        return value.takeUnretainedValue() as String
    }
}
