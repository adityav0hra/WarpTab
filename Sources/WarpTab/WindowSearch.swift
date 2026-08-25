import Foundation

enum WindowSearch {
    static func results(for query: String, in windows: [WarpWindow]) -> [WarpWindow] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return windows }
        return windows.compactMap { window -> (WarpWindow, Int)? in
            score(query: query, candidate: "\(window.appName) \(window.title)").map { (window, $0) }
        }
        .sorted { left, right in
            if left.1 != right.1 { return left.1 > right.1 }
            let leftIndex = windows.firstIndex(where: { $0.identity == left.0.identity }) ?? .max
            let rightIndex = windows.firstIndex(where: { $0.identity == right.0.identity }) ?? .max
            return leftIndex < rightIndex
        }
        .map(\.0)
    }

    static func score(query: String, candidate: String) -> Int? {
        let normalizedQuery = query.lowercased()
        let normalizedCandidate = candidate.lowercased()
        if let range = normalizedCandidate.range(of: normalizedQuery) {
            let offset = normalizedCandidate.distance(from: normalizedCandidate.startIndex, to: range.lowerBound)
            return 10_000 - offset * 5 - normalizedCandidate.count
        }

        let needle = Array(normalizedQuery)
        let haystack = Array(normalizedCandidate)
        guard !needle.isEmpty else { return 0 }
        var queryIndex = 0
        var score = 0
        var lastMatch = -2
        for (index, character) in haystack.enumerated() where queryIndex < needle.count {
            if character == needle[queryIndex] {
                score += index == lastMatch + 1 ? 8 : 2
                lastMatch = index
                queryIndex += 1
            }
        }
        return queryIndex == needle.count ? score : nil
    }
}
