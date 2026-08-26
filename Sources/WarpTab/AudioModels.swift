import AppKit
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let hasInput: Bool
    let hasOutput: Bool

    var iconName: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "airpodspro"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeUSB:
            return "cable.connector"
        default:
            return hasInput && !hasOutput ? "mic" : "speaker.wave.2"
        }
    }

    var isHeadphoneLike: Bool {
        let lowered = name.lowercased()
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
            || lowered.contains("headphone")
            || lowered.contains("airpod")
            || lowered.contains("headset")
    }
}

struct AudioApp: Identifiable, Hashable {
    let id: pid_t
    let processObjectID: AudioObjectID
    let bundleIdentifier: String
    let name: String
    let icon: NSImage?
    let isProducingAudio: Bool
}

struct AppAudioPreference: Codable, Equatable {
    var volumePercent: Int = 100
    var outputUID: String?
    var isHidden = false
}
