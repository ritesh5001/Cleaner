import Foundation

struct ScanItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date?
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct CategoryResult: Identifiable {
    let rule: CleanupRule
    var items: [ScanItem]
    /// Items this rule would clean but skipped because their app is running.
    var heldByRunningApps: [ScanItem] = []
    var id: String { rule.id }
    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var heldTotal: Int64 { heldByRunningApps.reduce(0) { $0 + $1.size } }
    var isEmpty: Bool { items.isEmpty && heldByRunningApps.isEmpty }
    /// Names of the running apps holding `heldByRunningApps`.
    var holdingApps: [String] {
        Array(Set(heldByRunningApps.compactMap { item -> String? in
            let c = item.url.pathComponents
            guard let i = c.firstIndex(of: "Application Support"), i + 1 < c.count else { return nil }
            return c[i + 1]
        })).sorted()
    }
}

struct CleanTarget {
    let url: URL
    let size: Int64
    var permanent = false
}

struct CleanFailure: Identifiable {
    let id = UUID()
    let url: URL
    let reason: String
}

struct CleanReport {
    var freed: Int64 = 0
    var trashed: Int64 = 0
    var removed: [URL] = []
    var failures: [CleanFailure] = []
}

/// Performs every deletion in the app. Always re-checks SafetyGuard right before acting.
enum Cleaner {
    static var deletePermanently: Bool { UserDefaults.standard.bool(forKey: "deletePermanently") }

    static func remove(_ targets: [CleanTarget]) -> CleanReport {
        var report = CleanReport()
        let fm = FileManager.default
        let forcePermanent = deletePermanently
        for t in targets {
            if let reason = SafetyGuard.blockReason(for: t.url) {
                report.failures.append(CleanFailure(url: t.url, reason: reason))
                continue
            }
            do {
                if t.permanent || forcePermanent {
                    try fm.removeItem(at: t.url)
                    report.freed += t.size
                    CleanupLog.shared.record(t.url, size: t.size, action: "deleted")
                } else {
                    try fm.trashItem(at: t.url, resultingItemURL: nil)
                    report.trashed += t.size
                    CleanupLog.shared.record(t.url, size: t.size, action: "trashed")
                }
                report.removed.append(t.url)
            } catch {
                report.failures.append(CleanFailure(url: t.url, reason: friendly(error)))
            }
        }
        return report
    }

    static func emptyTrash() -> CleanReport {
        let trash = Paths.home.appendingPathComponent(".Trash")
        let targets = Paths.children(of: trash).map { CleanTarget(url: $0, size: FileSizer.size(of: $0), permanent: true) }
        return remove(targets)
    }

    private static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError || ns.code == 513 {
            return "Permission denied (owned by macOS or another user)"
        }
        return ns.localizedDescription
    }
}

/// Append-only history of everything Cleaner removed, in ~/Library/Application Support/Cleaner/history.log
final class CleanupLog: @unchecked Sendable {
    static let shared = CleanupLog()
    private let lock = NSLock()
    let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Storage Fusion", isDirectory: true)
        let old = support.appendingPathComponent("Cleaner", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dir)   // keep history from the old app name
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.log")
    }

    func record(_ url: URL, size: Int64, action: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(action)\t\(size)\t\(url.path)\n"
        if let h = try? FileHandle(forWritingTo: fileURL) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
        let d = UserDefaults.standard
        d.set(d.double(forKey: "lifetimeCleanedBytes") + Double(size), forKey: "lifetimeCleanedBytes")
    }

    static var lifetimeCleaned: Int64 { Int64(UserDefaults.standard.double(forKey: "lifetimeCleanedBytes")) }
}
