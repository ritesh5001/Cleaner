import Foundation
import CoreServices

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let lastUsed: Date?
    var size: Int64?
    var id: URL { url }
}

enum AppCatalog {
    static func appURLs(includeSystem: Bool) -> [URL] {
        var dirs = ["/Applications", Paths.home.appendingPathComponent("Applications").path]
        if includeSystem { dirs += ["/System/Applications", "/System/Applications/Utilities"] }
        var result: [URL] = []
        for d in dirs {
            for c in Paths.children(of: URL(fileURLWithPath: d)) {
                if c.pathExtension == "app" {
                    result.append(c)
                } else if Paths.isDirectory(c) {
                    result += Paths.children(of: c).filter { $0.pathExtension == "app" }
                }
            }
        }
        return result
    }

    static func installedBundleIDs() -> Set<String> {
        Set(appURLs(includeSystem: true).compactMap { Bundle(url: $0)?.bundleIdentifier?.lowercased() })
    }

    static func installedApps() -> [InstalledApp] {
        appURLs(includeSystem: false).map { url in
            let b = Bundle(url: url)
            return InstalledApp(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                bundleID: b?.bundleIdentifier,
                version: b?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                lastUsed: lastUsed(url),
                size: nil
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "Last opened" date from Spotlight metadata.
    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// Finds support files an app leaves behind in Library folders.
enum LeftoverFinder {
    private static let userDirs = [
        "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Preferences/ByHost",
        "Library/Containers", "Library/Group Containers", "Library/Logs", "Library/Saved Application State",
        "Library/HTTPStorages", "Library/WebKit", "Library/Cookies", "Library/LaunchAgents",
        "Library/Application Scripts",
    ]
    private static let systemDirs = [
        "/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/LaunchAgents",
        "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools", "/Library/Logs",
    ]
    private static let strippedSuffixes = [".plist", ".savedstate", ".binarycookies"]

    static func find(for app: InstalledApp) -> [ScanItem] {
        let bid = app.bundleID?.lowercased()
        let name = app.name.lowercased()
        let dirs = userDirs.map { Paths.home.appendingPathComponent($0) } + systemDirs.map { URL(fileURLWithPath: $0) }

        var found: [URL] = []
        for dir in dirs {
            for c in Paths.children(of: dir) {
                var base = c.lastPathComponent.lowercased()
                for s in strippedSuffixes where base.hasSuffix(s) { base = String(base.dropLast(s.count)) }
                var match = false
                if let bid, !bid.isEmpty {
                    match = base == bid || base.hasPrefix(bid + ".") || base.hasSuffix("." + bid)
                }
                if !match, name.count >= 4, base == name { match = true }
                if match { found.append(c) }
            }
        }
        return found
            .filter { SafetyGuard.blockReason(for: $0) == nil }
            .map { ScanItem(url: $0, size: FileSizer.size(of: $0), modified: Paths.modified($0)) }
            .sorted { $0.size > $1.size }
    }
}
