import Foundation
import SwiftUI

enum Safety: String {
    case safe, review, caution

    var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .caution: "Caution"
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .caution: .red
        }
    }
}

enum RuleGroup: String, CaseIterable, Identifiable {
    case system = "System Junk"
    case developer = "Developer Junk"
    case backups = "Backups, Downloads & Leftovers"
    case trash = "Trash"
    var id: String { rawValue }
}

enum RuleMode {
    /// Every direct child of each root is one cleanable item.
    case children
    /// Each root itself is one item.
    case root
    /// Direct children whose name starts with a prefix.
    case childrenNamed(prefix: String)
    /// Direct children with one of these file extensions.
    case extensions([String])
    /// Data folders/plists whose bundle ID belongs to no installed app.
    case orphanedAppData
}

struct CleanupRule: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let group: RuleGroup
    let safety: Safety
    let roots: [String]
    let mode: RuleMode
    var permanent = false
    /// Broad rules (e.g. all of ~/Library/Caches) yield to more specific rules that claim the same item.
    var catchAll = false
    var selectedByDefault: Bool { safety == .safe }
}

enum CleanupRules {
    static let all: [CleanupRule] = [
        // System
        CleanupRule(id: "user_caches", title: "User Cache Files",
                    detail: "Temporary data apps keep to load faster. Apps rebuild it automatically when needed.",
                    icon: "internaldrive", group: .system, safety: .safe,
                    roots: ["~/Library/Caches"], mode: .children, catchAll: true),
        CleanupRule(id: "user_logs", title: "User Logs & Crash Reports",
                    detail: "Diagnostic logs and crash reports written by apps. Only useful when debugging.",
                    icon: "doc.text", group: .system, safety: .safe,
                    roots: ["~/Library/Logs"], mode: .children, catchAll: true),
        CleanupRule(id: "saved_state", title: "Saved Application State",
                    detail: "Window positions apps restore on relaunch. Removing only resets window layout.",
                    icon: "macwindow.on.rectangle", group: .system, safety: .safe,
                    roots: ["~/Library/Saved Application State"], mode: .children),
        CleanupRule(id: "system_caches", title: "System-wide Caches",
                    detail: "Caches shared by all users. Items owned by macOS are skipped automatically.",
                    icon: "server.rack", group: .system, safety: .review,
                    roots: ["/Library/Caches"], mode: .children),
        CleanupRule(id: "system_logs", title: "System Logs",
                    detail: "Logs from system services and installers. Some need administrator rights.",
                    icon: "doc.text.magnifyingglass", group: .system, safety: .review,
                    roots: ["/Library/Logs"], mode: .children),
        CleanupRule(id: "macos_installers", title: "Old macOS Installers",
                    detail: "Full macOS installer apps (12+ GB each) left in Applications after upgrading.",
                    icon: "arrow.down.app", group: .system, safety: .review,
                    roots: ["/Applications"], mode: .childrenNamed(prefix: "Install macOS")),

        // Developer
        CleanupRule(id: "xcode_derived", title: "Xcode DerivedData",
                    detail: "Build products and indexes. Xcode regenerates them on the next build.",
                    icon: "hammer", group: .developer, safety: .safe,
                    roots: ["~/Library/Developer/Xcode/DerivedData"], mode: .children),
        CleanupRule(id: "xcode_cache", title: "Xcode Cache",
                    detail: "Xcode's own download and module cache.",
                    icon: "hammer.circle", group: .developer, safety: .safe,
                    roots: ["~/Library/Caches/com.apple.dt.Xcode"], mode: .root),
        CleanupRule(id: "sim_caches", title: "Simulator Caches",
                    detail: "Dyld and runtime caches for iOS Simulators. Rebuilt on next launch.",
                    icon: "iphone", group: .developer, safety: .safe,
                    roots: ["~/Library/Developer/CoreSimulator/Caches"], mode: .children),
        CleanupRule(id: "device_support", title: "Device Support Files",
                    detail: "Debug symbols copied from each iPhone/Watch OS version you connected. Old versions are rarely needed.",
                    icon: "cable.connector", group: .developer, safety: .review,
                    roots: ["~/Library/Developer/Xcode/iOS DeviceSupport",
                            "~/Library/Developer/Xcode/watchOS DeviceSupport",
                            "~/Library/Developer/Xcode/tvOS DeviceSupport",
                            "~/Library/Developer/Xcode/visionOS DeviceSupport"], mode: .children),
        CleanupRule(id: "xcode_archives", title: "Xcode Archives",
                    detail: "Archived app builds with dSYMs. Keep ones you may need to symbolicate crash reports for.",
                    icon: "archivebox", group: .developer, safety: .caution,
                    roots: ["~/Library/Developer/Xcode/Archives"], mode: .children),
        CleanupRule(id: "package_caches", title: "Package Manager Caches",
                    detail: "Download caches for Homebrew, npm, Yarn, pip, Gradle, CocoaPods, Cargo, Go, Bun and SwiftPM. Re-downloaded on demand.",
                    icon: "shippingbox", group: .developer, safety: .safe,
                    roots: ["~/Library/Caches/Homebrew", "~/.npm/_cacache", "~/Library/Caches/Yarn",
                            "~/Library/Caches/pip", "~/.gradle/caches", "~/Library/Caches/CocoaPods",
                            "~/.cargo/registry/cache", "~/Library/Caches/go-build", "~/.bun/install/cache",
                            "~/Library/Caches/org.swift.swiftpm", "~/Library/Caches/pnpm"], mode: .root),

        // Backups, downloads & leftovers
        CleanupRule(id: "ios_backups", title: "iPhone & iPad Backups",
                    detail: "Local device backups. Delete only if you back up to iCloud or no longer own the device.",
                    icon: "iphone.gen3", group: .backups, safety: .caution,
                    roots: ["~/Library/Application Support/MobileSync/Backup"], mode: .children),
        CleanupRule(id: "ios_updates", title: "iOS Software Updates",
                    detail: "Downloaded iPhone/iPad firmware files. Safe to remove.",
                    icon: "arrow.down.circle", group: .backups, safety: .safe,
                    roots: ["~/Library/iTunes/iPhone Software Updates", "~/Library/iTunes/iPad Software Updates"],
                    mode: .children),
        CleanupRule(id: "mail_downloads", title: "Mail Attachment Downloads",
                    detail: "Copies of attachments you opened in Mail. Originals stay in your mailbox.",
                    icon: "paperclip", group: .backups, safety: .review,
                    roots: ["~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"], mode: .children),
        CleanupRule(id: "download_installers", title: "Installers in Downloads",
                    detail: "Disk images and installer packages. Usually not needed after the app is installed.",
                    icon: "externaldrive.badge.plus", group: .backups, safety: .review,
                    roots: ["~/Downloads"], mode: .extensions(["dmg", "pkg", "mpkg", "iso", "xip"])),
        CleanupRule(id: "orphans", title: "Leftovers of Removed Apps",
                    detail: "Containers, caches and preferences whose app is no longer installed.",
                    icon: "puzzlepiece.extension", group: .backups, safety: .review,
                    roots: ["~/Library/Containers", "~/Library/Application Scripts", "~/Library/HTTPStorages",
                            "~/Library/WebKit", "~/Library/Preferences", "~/Library/Caches",
                            "~/Library/Saved Application State"], mode: .orphanedAppData),

        // Trash
        CleanupRule(id: "trash", title: "Trash",
                    detail: "Items already in your Trash. Removing them is permanent.",
                    icon: "trash", group: .trash, safety: .safe,
                    roots: ["~/.Trash"], mode: .children, permanent: true),
    ]
}

// MARK: - Evaluation (runs off the main thread)

enum RuleEvaluator {
    static func evaluate(_ rule: CleanupRule, installedBundleIDs: Set<String>, excluded: [String]) -> CategoryResult? {
        var urls: [URL] = []
        for root in rule.roots.map(Paths.expand) {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            switch rule.mode {
            case .root:
                urls.append(root)
            case .children:
                urls += Paths.children(of: root)
            case .childrenNamed(let prefix):
                urls += Paths.children(of: root).filter { $0.lastPathComponent.hasPrefix(prefix) }
            case .extensions(let exts):
                urls += Paths.children(of: root).filter { exts.contains($0.pathExtension.lowercased()) }
            case .orphanedAppData:
                urls += Orphans.find(in: root, installed: installedBundleIDs)
            }
            if Task.isCancelled { return nil }
        }

        let items: [ScanItem] = urls.compactMap { url in
            guard !SafetyGuard.isExcluded(url, list: excluded), SafetyGuard.blockReason(for: url) == nil else { return nil }
            let size = FileSizer.size(of: url)
            guard size > 0 else { return nil }
            return ScanItem(url: url, size: size, modified: Paths.modified(url))
        }
        .sorted { $0.size > $1.size }

        return items.isEmpty ? nil : CategoryResult(rule: rule, items: items)
    }
}

enum Orphans {
    private static let strippedSuffixes = [".plist", ".savedstate", ".binarycookies"]

    static func find(in root: URL, installed: Set<String>) -> [URL] {
        let vendors = Set(installed.map(vendor))
        return Paths.children(of: root).filter { url in
            var id = url.lastPathComponent.lowercased()
            for s in strippedSuffixes where id.hasSuffix(s) { id = String(id.dropLast(s.count)) }
            guard looksLikeBundleID(id), !id.hasPrefix("com.apple.") else { return false }
            if installed.contains(id) || installed.contains(where: { id.hasPrefix($0 + ".") }) { return false }
            // Conservative: if the vendor still has any app installed, treat the data as possibly shared.
            if vendors.contains(vendor(id)) { return false }
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { return false }
            return true
        }
    }

    private static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count >= 3, !s.contains(" "), let f = s.first, f.isLetter else { return false }
        return parts.allSatisfy { !$0.isEmpty }
    }

    private static func vendor(_ id: String) -> String {
        id.split(separator: ".").prefix(2).joined(separator: ".")
    }
}
