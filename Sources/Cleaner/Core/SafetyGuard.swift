import Foundation

/// The final authority on what may be deleted. Neither scan rules nor AI can override it.
enum SafetyGuard {
    private static let home = Paths.home.path

    /// Anything under these is part of the OS (most of it is also SIP-protected).
    private static let systemPrefixes = [
        "/System/", "/usr/", "/bin/", "/sbin/", "/etc/", "/var/", "/private/var/db/",
        "/private/var/protected/", "/private/etc/", "/Library/Apple/", "/cores/",
    ]

    /// Folders that must never be removed themselves (their *contents* may be).
    private static let protectedExact: Set<String> = {
        let h = home
        return [
            "/", "/System", "/Applications", "/Library", "/Users", "/private", "/usr", "/bin", "/sbin",
            "/opt", "/Volumes", "/Library/Caches", "/Library/Logs", "/Library/Application Support",
            "/Library/Preferences", "/Library/LaunchAgents", "/Library/LaunchDaemons",
            h, "\(h)/Library", "\(h)/Documents", "\(h)/Desktop", "\(h)/Downloads", "\(h)/Pictures",
            "\(h)/Movies", "\(h)/Music", "\(h)/Applications", "\(h)/Public", "\(h)/.Trash",
            "\(h)/Library/Caches", "\(h)/Library/Logs", "\(h)/Library/Application Support",
            "\(h)/Library/Containers", "\(h)/Library/Group Containers", "\(h)/Library/Preferences",
            "\(h)/Library/Developer", "\(h)/Library/Saved Application State",
        ]
    }()

    /// User data that a cleaner should never touch (deleting iCloud Drive content deletes it everywhere).
    private static let protectedUserTrees: [String] = [
        "\(home)/Library/Keychains", "\(home)/Library/Mobile Documents", "\(home)/Library/Mail",
        "\(home)/Library/Messages", "\(home)/Library/Accounts", "\(home)/Library/CloudStorage",
        "\(home)/Library/Photos", "\(home)/Library/Calendars",
        // Credentials and keys — irreplaceable if lost.
        "\(home)/.ssh", "\(home)/.gnupg", "\(home)/.aws", "\(home)/.azure", "\(home)/.kube",
        "\(home)/.password-store", "\(home)/.android-keys", "\(home)/Library/Application Support/1Password",
    ]

    /// Key and certificate files are never deleted, wherever they are.
    private static let protectedFileExtensions: Set<String> = [
        "keystore", "jks", "p12", "pfx", "pem", "key", "mobileprovision", "cer", "kdbx",
    ]

    private static let protectedPackageExtensions: Set<String> = [
        "photoslibrary", "musiclibrary", "tvlibrary", "photolibrary", "aplibrary", "migratedphotolibrary",
    ]

    static var excludedPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "excludedPaths") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "excludedPaths") }
    }

    static func isExcluded(_ url: URL, list: [String]? = nil) -> Bool {
        let p = url.path
        return (list ?? excludedPaths).contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// Returns why `url` must not be deleted, or nil when deletion is allowed.
    /// This user's own cache/temp folders under /var/folders — the only place below /var we allow cleaning.
    private static let userScratchRoots: [String] = {
        [Paths.darwinCacheDir, Paths.darwinTempDir]
            .filter { !$0.isEmpty }
            .flatMap { [$0, $0.hasPrefix("/private") ? String($0.dropFirst(8)) : "/private" + $0] }
    }()

    static func blockReason(for url: URL) -> String? {
        let p = url.standardizedFileURL.path
        if protectedExact.contains(p) || userScratchRoots.contains(p) { return "Protected folder" }
        let inUserScratch = userScratchRoots.contains { p.hasPrefix($0 + "/") }
        if !inUserScratch, systemPrefixes.contains(where: { p.hasPrefix($0) }) { return "Part of macOS (system-protected)" }
        if protectedUserTrees.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) {
            return "Protected personal data"
        }
        if protectedPackageExtensions.contains(url.pathExtension.lowercased())
            || protectedPackageExtensions.contains(where: { p.contains(".\($0)/") }) {
            return "Media library — manage it inside its own app"
        }
        if protectedFileExtensions.contains(url.pathExtension.lowercased()) {
            return "Key or certificate file — irreplaceable if lost"
        }
        if isExcluded(url) { return "In your exclusion list" }
        return nil
    }
}
