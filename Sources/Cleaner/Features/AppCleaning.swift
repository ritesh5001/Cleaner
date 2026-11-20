import Foundation
import AppKit

/// The different ways to clean up one app.
enum AppCleanOption: String, CaseIterable, Identifiable {
    case safe, resetApp, uninstall, appOnly, leftovers, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .safe: "Safe Clean"
        case .resetApp: "Reset App"
        case .uninstall: "Uninstall Completely"
        case .appOnly: "Remove App, Keep Data"
        case .leftovers: "Remove Leftovers"
        case .custom: "Choose Items"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "leaf"
        case .resetApp: "arrow.counterclockwise"
        case .uninstall: "trash"
        case .appOnly: "app.dashed"
        case .leftovers: "puzzlepiece.extension"
        case .custom: "checklist"
        }
    }

    var detail: String {
        switch self {
        case .safe: "Only caches, logs and temporary web data. The app keeps working and rebuilds them. Settings, logins and documents stay."
        case .resetApp: "Erases all of the app's data and settings but keeps the app — like a fresh install. You'll need to sign in and set it up again."
        case .uninstall: "Removes the app and everything it stored: data, settings, caches and containers."
        case .appOnly: "Removes just the application. Settings and data stay, so reinstalling later picks up where you left off."
        case .leftovers: "The app isn't installed anymore — removes everything it left behind."
        case .custom: "Pick exactly which locations to remove."
        }
    }

    var safety: Safety {
        switch self {
        case .safe, .leftovers: .safe
        case .appOnly, .custom: .review
        case .resetApp, .uninstall: .caution
        }
    }

    /// Options that make sense for this app.
    static func available(for f: AppFootprint) -> [AppCleanOption] {
        var out: [AppCleanOption] = []
        if f.cleanableSize > 0 { out.append(.safe) }
        if f.appBundle != nil {
            if !f.items.isEmpty { out += [.resetApp, .uninstall] }
            out.append(.appOnly)
        } else if !f.owner.installed || f.kind == .gone {
            out.append(.leftovers)
        } else if !f.items.isEmpty {
            out.append(.resetApp)
        }
        if f.items.count > 1 { out.append(.custom) }
        return out
    }

    /// What this option removes (app bundle first).
    func targets(_ f: AppFootprint, custom: Set<URL> = []) -> [AppCleanTarget] {
        let data = f.items.filter { !$0.isNested && SafetyGuard.blockReason(for: $0.url) == nil }
            .map { AppCleanTarget(url: $0.url, kind: $0.kind, size: $0.size ?? 0) }
        let app = f.appBundle.map { [AppCleanTarget(url: $0, kind: "Application", size: f.appSize ?? 0)] } ?? []
        switch self {
        case .safe: return f.items.filter(\.cleanable).map { AppCleanTarget(url: $0.url, kind: $0.kind, size: $0.size ?? 0) }
        case .resetApp, .leftovers: return data
        case .uninstall: return app + data
        case .appOnly: return app
        case .custom: return (app + data).filter { custom.contains($0.url) }
        }
    }
}

struct AppCleanTarget: Identifiable, Hashable {
    let url: URL
    let kind: String
    let size: Int64
    var id: URL { url }
}

/// How items are removed.
enum DeleteMethod: String, CaseIterable, Identifiable {
    case trash, permanent, archive
    var id: String { rawValue }

    var title: String {
        switch self {
        case .trash: "Move to Trash"
        case .permanent: "Delete Permanently"
        case .archive: "Back Up to ZIP, Then Delete"
        }
    }

    var detail: String {
        switch self {
        case .trash: "Recoverable until you empty the Trash. Space is freed after emptying it."
        case .permanent: "Frees space immediately. Can't be undone."
        case .archive: "Compresses everything into ~/Documents/Cleaner Backups first, then deletes the originals."
        }
    }

    var symbol: String {
        switch self {
        case .trash: "trash"
        case .permanent: "xmark.bin"
        case .archive: "archivebox"
        }
    }
}

enum AppCleaner {
    static var backupRoot: URL {
        if let override = ProcessInfo.processInfo.environment["CLEANER_BACKUP_ROOT"] { return URL(fileURLWithPath: override) }
        return Paths.home.appendingPathComponent("Documents/Cleaner Backups", isDirectory: true)
    }

    /// Running instances of an app (by bundle location).
    static func running(_ f: AppFootprint) -> [NSRunningApplication] {
        guard let path = (f.appBundle ?? f.owner.bundleURL)?.path else { return [] }
        return NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }
    }

    /// Backs up (optionally), then removes. Runs off the main thread.
    static func run(_ targets: [AppCleanTarget], method: DeleteMethod, appName: String,
                    progress: @escaping @Sendable (String) -> Void) -> (CleanReport, backup: URL?, backupFailures: [String]) {
        var backupDir: URL?
        var backupFailures: [String] = []
        // Protected items are never touched — not even backed up.
        let blocked = targets.filter { SafetyGuard.blockReason(for: $0.url) != nil }
        let targets = targets.filter { SafetyGuard.blockReason(for: $0.url) == nil }
        var toDelete = targets

        if method == .archive {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd HH.mm"
            let safeName = appName.replacingOccurrences(of: "/", with: "-")
            let dir = backupRoot.appendingPathComponent("\(safeName) \(stamp.string(from: Date()))", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            backupDir = dir
            for (i, t) in targets.enumerated() {
                progress("Backing up \(i + 1) of \(targets.count): \(t.url.lastPathComponent)…")
                var dest = dir.appendingPathComponent("\(t.kind) - \(t.url.lastPathComponent).zip")
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = dir.appendingPathComponent("\(t.kind) - \(t.url.lastPathComponent) \(n).zip"); n += 1
                }
                let r = Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", t.url.path, dest.path])
                if !r.ok {
                    // Never delete something whose backup failed.
                    backupFailures.append(t.url.lastPathComponent)
                    toDelete.removeAll { $0.url == t.url }
                }
            }
        }

        progress("Removing \(toDelete.count) item(s)…")
        var report = Cleaner.remove(toDelete.map {
            CleanTarget(url: $0.url, size: $0.size, permanent: method != .trash)
        })
        report.failures += blocked.map { CleanFailure(url: $0.url, reason: SafetyGuard.blockReason(for: $0.url) ?? "Protected") }
        return (report, backupDir, backupFailures)
    }
}

extension AppStorageModel {
    /// Updates the list after items were removed.
    func applyRemoval(_ removed: [URL], from footprintID: String) {
        let set = Set(removed)
        for u in removed { SizeIndex.shared.invalidate(u) }
        guard let i = footprints.firstIndex(where: { $0.id == footprintID }) else { return }
        footprints[i].items.removeAll { set.contains($0.url) }
        if let b = footprints[i].appBundle, set.contains(b) {
            footprints[i].appBundle = nil
            footprints[i].appSize = nil
        }
        if footprints[i].items.isEmpty && footprints[i].appBundle == nil { footprints.remove(at: i) }
    }

    /// Cache-type data across all apps that aren't running.
    var allSafeCaches: [(AppFootprint, [AppCleanTarget])] {
        footprints.compactMap { f in
            guard f.kind != .macos, AppCleaner.running(f).isEmpty else { return nil }
            let t = AppCleanOption.safe.targets(f).filter { $0.size > 0 }
            return t.isEmpty ? nil : (f, t)
        }
    }

    /// Everything left behind by apps that are no longer installed.
    var allLeftovers: [(AppFootprint, [AppCleanTarget])] {
        footprints.compactMap { f in
            guard f.kind == .gone else { return nil }
            let t = AppCleanOption.leftovers.targets(f).filter { $0.size > 0 }
            return t.isEmpty ? nil : (f, t)
        }
    }
}
