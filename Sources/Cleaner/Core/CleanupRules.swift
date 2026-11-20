import Foundation
import SwiftUI
import AppKit

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
    case apps = "App Caches & Runtimes"
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
    /// Folders with one of these names, found up to `maxDepth` levels below each root.
    case nestedNamed(Set<String>, maxDepth: Int)
    /// Regenerable build output (`.next`, `.turbo`…) or reinstallable dependencies (`node_modules`…) in projects.
    case projectArtifacts(dependencies: Bool)
    /// VS Code-family extension folders that the editor's own registry no longer references.
    case obsoleteEditorExtensions
    /// Direct children whose name starts with any of these prefixes.
    case childrenWithPrefixes([String])
    /// Archives (.zip, .tar.gz…) that sit next to a folder with the same name (already extracted).
    case extractedArchives
    /// Editor per-project storage whose project folder no longer exists.
    case orphanedWorkspaceStorage
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
    /// Only include items not modified for at least this many days.
    var minAgeDays = 0
    /// Skip items belonging to an app that is currently running (owner = folder under Application Support).
    var skipRunningApps = false
    /// Skip com.apple.* items (used for macOS-owned temp/cache areas).
    var skipApplePrefixed = false
    var selectedByDefault: Bool { safety == .safe }
}

enum CleanupRules {
    private static let appSupport = "~/Library/Application Support"

    static let all: [CleanupRule] = [
        // System
        CleanupRule(id: "user_caches", title: "User Cache Files",
                    detail: "Temporary data apps keep to load faster. Apps rebuild it automatically when needed.",
                    icon: "internaldrive", group: .system, safety: .safe,
                    roots: ["~/Library/Caches"], mode: .children, catchAll: true),
        CleanupRule(id: "darwin_cache", title: "Hidden macOS App Caches",
                    detail: "Per-user cache folder macOS keeps in /var/folders (shader, compiler and app caches). Apple's own entries are skipped.",
                    icon: "eye.slash", group: .system, safety: .safe,
                    roots: ["$DARWIN_CACHE"], mode: .children, skipApplePrefixed: true),
        CleanupRule(id: "darwin_temp", title: "Old Temporary Files",
                    detail: "Temporary files older than 3 days that apps forgot to delete.",
                    icon: "clock.badge.xmark", group: .system, safety: .safe,
                    roots: ["$DARWIN_TEMP"], mode: .children, minAgeDays: 3, skipApplePrefixed: true),
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

        // App caches & runtimes
        CleanupRule(id: "app_internal_caches", title: "Caches Inside Apps",
                    detail: "Browser-engine caches that Electron/Chromium apps (VS Code, Slack, Discord, Claude, Chrome…) keep inside Application Support. Caches of running apps are skipped — quit them to include.",
                    icon: "square.stack.3d.down.right", group: .apps, safety: .safe,
                    roots: [appSupport],
                    mode: .nestedNamed(["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache",
                                        "DawnWebGPUCache", "GraphiteDawnCache", "GrShaderCache", "ShaderCache",
                                        "CachedData", "CachedExtensionVSIXs", "Crashpad"], maxDepth: 4),
                    skipRunningApps: true),
        CleanupRule(id: "web_app_caches", title: "Web App Offline Caches",
                    detail: "Service-worker storage that browsers and Electron apps keep for web pages and extensions. Sites re-download it; some may lose offline content. Skipped while the app runs.",
                    icon: "globe.badge.chevron.backward", group: .apps, safety: .review,
                    roots: [appSupport], mode: .nestedNamed(["CacheStorage", "ScriptCache"], maxDepth: 6),
                    skipRunningApps: true),
        CleanupRule(id: "app_logs", title: "App Log Folders",
                    detail: "Log folders that desktop apps (VS Code, Electron apps…) keep inside Application Support.",
                    icon: "list.bullet.rectangle", group: .apps, safety: .safe,
                    roots: [appSupport], mode: .nestedNamed(["logs"], maxDepth: 2), skipRunningApps: true),
        CleanupRule(id: "workspace_storage", title: "Editor Data for Deleted Projects",
                    detail: "VS Code / Cursor / Windsurf keep per-project state; these entries belong to project folders that no longer exist.",
                    icon: "folder.badge.questionmark", group: .apps, safety: .safe,
                    roots: ["\(appSupport)/Code/User/workspaceStorage", "\(appSupport)/Cursor/User/workspaceStorage",
                            "\(appSupport)/Windsurf/User/workspaceStorage", "\(appSupport)/Code - Insiders/User/workspaceStorage"],
                    mode: .orphanedWorkspaceStorage),
        CleanupRule(id: "editor_extensions", title: "Old Editor Extension Versions",
                    detail: "Previous versions of VS Code / Cursor / Windsurf extensions that the editor no longer uses.",
                    icon: "puzzlepiece", group: .apps, safety: .safe,
                    roots: ["~/.vscode/extensions", "~/.vscode-insiders/extensions", "~/.cursor/extensions",
                            "~/.windsurf/extensions", "~/.vscode-oss/extensions"],
                    mode: .obsoleteEditorExtensions),
        CleanupRule(id: "ai_vm_images", title: "AI App VM Images",
                    detail: "Virtual-machine images AI desktop apps download for sandboxed features (e.g. Claude Desktop). Re-downloaded the next time you use that feature. Skipped while the app is running.",
                    icon: "cpu", group: .apps, safety: .caution,
                    roots: ["\(appSupport)/Claude/vm_bundles"], mode: .root, skipRunningApps: true),
        CleanupRule(id: "abandoned_installs", title: "Interrupted Runtime Installs",
                    detail: "Half-finished runtime downloads left behind when an install was interrupted.",
                    icon: "arrow.down.circle.dotted", group: .apps, safety: .safe,
                    roots: ["~/.cache/codex-runtimes"], mode: .childrenNamed(prefix: "codex-runtime-install-"),
                    minAgeDays: 1),

        // Developer
        CleanupRule(id: "project_build", title: "Project Build Output",
                    detail: "Regenerable build folders in your projects (.next, .turbo, .nuxt, .svelte-kit, .parcel-cache, .angular, .expo). Rebuilt on the next build or dev run.",
                    icon: "hammer.fill", group: .developer, safety: .safe,
                    roots: ["~"], mode: .projectArtifacts(dependencies: false)),
        CleanupRule(id: "project_deps", title: "Project Dependencies",
                    detail: "node_modules, Python virtualenvs, CocoaPods, Rust target and Gradle folders. Reinstall with npm install / pip / pod install. Best for projects you aren't working on.",
                    icon: "shippingbox.and.arrow.backward", group: .developer, safety: .review,
                    roots: ["~"], mode: .projectArtifacts(dependencies: true)),
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
                    detail: "Download caches for npm/npx, Yarn, pnpm, Bun, pip, uv, Gradle, CocoaPods, Cargo, Go, Homebrew, SwiftPM and Prisma. Re-downloaded on demand.",
                    icon: "shippingbox", group: .developer, safety: .safe,
                    roots: ["~/Library/Caches/Homebrew", "~/.npm/_cacache", "~/.npm/_npx", "~/Library/Caches/Yarn",
                            "~/Library/Caches/pip", "~/.cache/uv", "~/.gradle/caches", "~/Library/Caches/CocoaPods",
                            "~/.cargo/registry/cache", "~/Library/Caches/go-build", "~/.bun/install/cache",
                            "~/Library/Caches/org.swift.swiftpm", "~/Library/Caches/pnpm", "~/.cache/prisma",
                            "~/Library/Caches/node-gyp", "~/Library/Caches/typescript"], mode: .root),

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
                    detail: "Disk images, installer packages and Android app bundles. Usually not needed after installing or uploading.",
                    icon: "externaldrive.badge.plus", group: .backups, safety: .review,
                    roots: ["~/Downloads"], mode: .extensions(["dmg", "pkg", "mpkg", "iso", "xip", "aab", "apk", "ipa"])),
        CleanupRule(id: "partial_downloads", title: "Interrupted Downloads",
                    detail: "Unfinished browser downloads (.crdownload, .part…) older than a day.",
                    icon: "arrow.down.to.line.compact", group: .backups, safety: .safe,
                    roots: ["~/Downloads"], mode: .extensions(["crdownload", "download", "part", "partial", "opdownload"]),
                    minAgeDays: 1),
        CleanupRule(id: "extracted_archives", title: "Already-Extracted Archives",
                    detail: "Zip/tar files sitting next to a folder with the same name — you've already unpacked them.",
                    icon: "doc.zipper", group: .backups, safety: .review,
                    roots: ["~/Downloads", "~/Desktop"], mode: .extractedArchives),
        CleanupRule(id: "old_screenshots", title: "Old Screenshots & Screen Recordings",
                    detail: "Screenshots and recordings older than 30 days on your Desktop and in Downloads.",
                    icon: "camera.viewfinder", group: .backups, safety: .review,
                    roots: ["~/Desktop", "~/Downloads", "~/Pictures/Screenshots"],
                    mode: .childrenWithPrefixes(["Screenshot ", "Screen Shot ", "Screen Recording ", "CleanShot "]),
                    minAgeDays: 30),
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

struct ScanContext {
    var installedBundleIDs: Set<String>
    var excluded: [String]
    /// Lower-cased names of running GUI apps (localized name + bundle file name).
    var runningAppNames: Set<String>

    @MainActor
    static func current() -> ScanContext {
        var names = Set<String>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let n = app.localizedName { names.insert(n.lowercased()) }
            if let u = app.bundleURL { names.insert(u.deletingPathExtension().lastPathComponent.lowercased()) }
        }
        return ScanContext(installedBundleIDs: AppCatalog.installedBundleIDs(),
                           excluded: SafetyGuard.excludedPaths, runningAppNames: names)
    }

    func isOwnerRunning(_ url: URL) -> Bool {
        let comps = url.pathComponents
        guard let i = comps.firstIndex(of: "Application Support"), i + 1 < comps.count else { return false }
        let owner = comps[i + 1].lowercased()
        return runningAppNames.contains { name in
            name == owner || name.hasPrefix(owner + " ") || name.hasSuffix(" " + owner) || owner.hasPrefix(name)
        }
    }
}

enum RuleEvaluator {
    static func evaluate(_ rule: CleanupRule, context: ScanContext) -> CategoryResult? {
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
                urls += Orphans.find(in: root, installed: context.installedBundleIDs)
            case .nestedNamed(let names, let depth):
                urls += DeepFinder.nested(in: root, names: names, maxDepth: depth)
            case .projectArtifacts(let deps):
                urls += DeepFinder.projectArtifacts(in: root, dependencies: deps)
            case .obsoleteEditorExtensions:
                urls += DeepFinder.obsoleteExtensions(in: root)
            case .childrenWithPrefixes(let prefixes):
                urls += Paths.children(of: root).filter { u in prefixes.contains { u.lastPathComponent.hasPrefix($0) } }
            case .extractedArchives:
                urls += DeepFinder.extractedArchives(in: root)
            case .orphanedWorkspaceStorage:
                urls += DeepFinder.orphanedWorkspaces(in: root)
            }
            if Task.isCancelled { return nil }
        }

        let cutoff = rule.minAgeDays > 0 ? Date().addingTimeInterval(-Double(rule.minAgeDays) * 86_400) : nil
        var held: [ScanItem] = []
        let items: [ScanItem] = urls.compactMap { url in
            if rule.skipApplePrefixed, url.lastPathComponent.hasPrefix("com.apple.") { return nil }
            if rule.skipRunningApps, context.isOwnerRunning(url) {
                let size = FileSizer.size(of: url)
                if size > 0 { held.append(ScanItem(url: url, size: size, modified: nil)) }
                return nil
            }
            guard !SafetyGuard.isExcluded(url, list: context.excluded), SafetyGuard.blockReason(for: url) == nil else { return nil }
            let modified = Paths.modified(url)
            if let cutoff, let modified, modified > cutoff { return nil }
            let size = FileSizer.size(of: url)
            guard size > 0 else { return nil }
            return ScanItem(url: url, size: size, modified: modified)
        }
        .sorted { $0.size > $1.size }

        let result = CategoryResult(rule: rule, items: items, heldByRunningApps: held.sorted { $0.size > $1.size })
        return result.isEmpty ? nil : result
    }
}

/// Recursive finders for junk that hides deeper than one level.
enum DeepFinder {
    /// Never look inside these (sync engines can hold not-yet-uploaded files in folders named "Cache").
    static let protectedComponents: Set<String> = [
        "DriveFS", "Dropbox", "OneDrive", "Box", "CloudDocs", "MobileSync", "Google Drive", "pCloud",
        ".tmp.driveupload", ".tmp.drivedownload",
    ]

    static func nested(in root: URL, names: Set<String>, maxDepth: Int) -> [URL] {
        var out: [URL] = []
        DirWalker.walk(root, keys: [.isPackageKey]) { u, level, v in
            let name = u.lastPathComponent
            guard v.isDirectory == true, v.isPackage != true else { return .skip }
            if protectedComponents.contains(name) || name.hasPrefix("com.apple.") { return .skip }
            if names.contains(name) { out.append(u); return .skip }
            return level >= maxDepth ? .skip : .descend
        }
        return out
    }

    private static let buildOutput: Set<String> = [
        ".next", ".turbo", ".parcel-cache", ".nuxt", ".svelte-kit", ".angular", ".expo", ".docusaurus",
    ]

    /// Folder name → files that must exist next to it (or inside it, for virtualenvs) to confirm what it is.
    private static let dependencyMarkers: [String: (siblings: [String], inside: [String])] = [
        "node_modules": (["package.json"], []),
        ".venv": ([], ["pyvenv.cfg"]),
        "venv": ([], ["pyvenv.cfg"]),
        "Pods": (["Podfile"], []),
        "target": (["Cargo.toml", "pom.xml"], []),
        ".gradle": (["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], []),
    ]

    private static let skippedTopLevel: Set<String> = ["Library", "Applications", "Pictures", "Music", "Movies", "Public"]

    static func projectArtifacts(in root: URL, dependencies: Bool) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        DirWalker.walk(root, keys: [.isPackageKey]) { u, level, v in
            guard v.isDirectory == true, v.isPackage != true else { return .skip }
            let name = u.lastPathComponent
            // Hidden folders directly in home are tool installs (~/.claude, ~/.vscode…), not projects.
            if level == 1, name.hasPrefix(".") || skippedTopLevel.contains(name) { return .skip }
            if level > 8 || protectedComponents.contains(name) { return .skip }

            if buildOutput.contains(name) {
                if !dependencies { out.append(u) }
                return .skip
            }
            if let marker = dependencyMarkers[name] {
                let parent = u.deletingLastPathComponent()
                let confirmed = marker.siblings.contains { fm.fileExists(atPath: parent.appendingPathComponent($0).path) }
                    || marker.inside.contains { fm.fileExists(atPath: u.appendingPathComponent($0).path) }
                if confirmed {
                    if dependencies { out.append(u) }
                    return .skip
                }
            }
            // Don't wander into VCS metadata or other hidden folders inside projects.
            return name.hasPrefix(".") ? .skip : .descend
        }
        return out
    }

    static func obsoleteExtensions(in root: URL) -> [URL] {
        let dirs = Paths.children(of: root).filter { !$0.lastPathComponent.hasPrefix(".") && Paths.isDirectory($0) }
        let registry = root.appendingPathComponent("extensions.json")
        if let data = try? Data(contentsOf: registry),
           let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !list.isEmpty {
            let active = Set(list.compactMap { entry -> String? in
                if let rel = entry["relativeLocation"] as? String { return rel }
                if let loc = entry["location"] as? [String: Any], let p = loc["path"] as? String {
                    return URL(fileURLWithPath: p).lastPathComponent
                }
                return nil
            })
            guard !active.isEmpty else { return [] }
            return dirs.filter { !active.contains($0.lastPathComponent) }
        }
        // Fallback: the editor's own list of folders it has marked obsolete.
        let obsoleteFile = root.appendingPathComponent(".obsolete")
        guard let data = try? Data(contentsOf: obsoleteFile),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return dirs.filter { map[$0.lastPathComponent] != nil }
    }
}

extension DeepFinder {
    static func extractedArchives(in root: URL) -> [URL] {
        let fm = FileManager.default
        let suffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".zip", ".rar", ".7z", ".tar"]
        return Paths.children(of: root).compactMap { u in
            let name = u.lastPathComponent
            guard let suf = suffixes.first(where: { name.lowercased().hasSuffix($0) }) else { return nil }
            let base = String(name.dropLast(suf.count))
            guard !base.isEmpty else { return nil }
            var isDir: ObjCBool = false
            let sibling = root.appendingPathComponent(base).path
            return fm.fileExists(atPath: sibling, isDirectory: &isDir) && isDir.boolValue ? u : nil
        }
    }

    static func orphanedWorkspaces(in root: URL) -> [URL] {
        Paths.children(of: root).filter { dir in
            let meta = dir.appendingPathComponent("workspace.json")
            guard let data = try? Data(contentsOf: meta),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let uri = (json["folder"] ?? json["workspace"]) as? String,
                  uri.hasPrefix("file://"), let url = URL(string: uri) else { return false }
            return !FileManager.default.fileExists(atPath: url.path)
        }
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
