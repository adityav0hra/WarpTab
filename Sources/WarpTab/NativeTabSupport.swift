import Foundation

enum NativeTabSupport {
    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera"
    ]

    static func allowsIndividualTabs(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return true }
        return !browserBundleIdentifiers.contains(bundleIdentifier)
    }
}
