import Foundation

/// Keeps the display and system awake while WarpTab's Stay Awake mode is enabled.
final class AwakeController {
    private(set) var isEnabled = false
    private var activity: NSObjectProtocol?

    func toggle() {
        setEnabled(!isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }

        if enabled {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                reason: "WarpTab Stay Awake is keeping this Mac awake"
            )
            isEnabled = true
        } else {
            stop()
        }
    }

    func stop() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        isEnabled = false
    }

    deinit {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
