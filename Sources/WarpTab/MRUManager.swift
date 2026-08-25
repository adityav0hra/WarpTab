import Foundation

enum SwitcherSequence {
    static func initialSelectionIndex(windowCount: Int, backwards: Bool) -> Int? {
        guard windowCount > 0 else { return nil }
        guard windowCount > 1 else { return 0 }
        return backwards ? windowCount - 1 : 1
    }
}

final class MRUManager {
    private var identities: [String] = []
    private var lastFocusedAt: [String: Date] = [:]
    private var isSuspended = false

    func beginSwitching() {
        isSuspended = true
    }

    func cancelSwitching() {
        isSuspended = false
    }

    func commit(_ window: WarpWindow) {
        isSuspended = false
        record(window.identity)
    }

    func observeFocused(_ identity: String?) {
        guard !isSuspended, let identity else { return }
        record(identity)
    }

    func reconcile(with windows: [WarpWindow]) {
        let valid = Set(windows.map(\.identity))
        identities.removeAll { !valid.contains($0) }
        lastFocusedAt = lastFocusedAt.filter { valid.contains($0.key) }
        for window in windows where !identities.contains(window.identity) {
            identities.append(window.identity)
        }
    }

    func ordered(_ windows: [WarpWindow]) -> [WarpWindow] {
        let positions = Dictionary(uniqueKeysWithValues: identities.enumerated().map { ($0.element, $0.offset) })
        return windows.sorted { left, right in
            let leftPosition = positions[left.identity] ?? Int.max
            let rightPosition = positions[right.identity] ?? Int.max
            if leftPosition != rightPosition { return leftPosition < rightPosition }
            if left.isWindowlessApplication != right.isWindowlessApplication {
                return !left.isWindowlessApplication
            }
            let appOrder = left.appName.localizedStandardCompare(right.appName)
            if appOrder != .orderedSame { return appOrder == .orderedAscending }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }

    func lastFocusDate(for identity: String) -> Date? {
        lastFocusedAt[identity]
    }

    private func record(_ identity: String) {
        identities.removeAll { $0 == identity }
        identities.insert(identity, at: 0)
        lastFocusedAt[identity] = Date()
    }
}
