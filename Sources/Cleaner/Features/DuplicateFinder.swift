import Foundation
import CryptoKit

struct DupFile: Identifiable, Hashable {
    let url: URL
    let created: Date?
    let modified: Date?
    var id: URL { url }
}

struct DuplicateGroup: Identifiable {
    let id: String
    let size: Int64
    var files: [DupFile]
    var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
}

@MainActor
final class DuplicateFinder: ObservableObject {
    @Published var roots: [URL] = ["Downloads", "Desktop", "Documents", "Pictures"]
        .map { Paths.home.appendingPathComponent($0) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published var selected: Set<URL> = []
    @Published private(set) var isScanning = false
    @Published private(set) var status = ""
    @Published var minSizeKB = 100
    @Published var lastReport: CleanReport?

    private var worker: Task<[DuplicateGroup], Never>?

    var wastedTotal: Int64 { groups.reduce(0) { $0 + $1.wasted } }
    var selectedSize: Int64 {
        groups.reduce(0) { sum, g in sum + Int64(g.files.filter { selected.contains($0.url) }.count) * g.size }
    }

    func scan() {
        worker?.cancel()
        groups = []
        selected = []
        lastReport = nil
        isScanning = true
        status = "Listing files…"
        let roots = roots, minBytes = Int64(minSizeKB) * 1000, excluded = SafetyGuard.excludedPaths
        let t = Task.detached(priority: .userInitiated) { [weak self] in
            DuplicateSearch.find(roots: roots, minBytes: minBytes, excluded: excluded) { msg in
                Task { @MainActor in self?.status = msg }
            }
        }
        worker = t
        Task {
            let found = await t.value
            guard !t.isCancelled else { return }
            groups = found
            autoSelect()
            status = found.isEmpty ? "No duplicates found" : "\(found.count) groups of duplicates"
            isScanning = false
        }
    }

    func stop() {
        worker?.cancel()
        isScanning = false
        status = "Stopped"
    }

    /// Selects every copy except the best one to keep in each group.
    func autoSelect() {
        selected = Set(groups.flatMap { g in g.files.sorted(by: Self.keepFirst).dropFirst().map(\.url) })
    }

    /// Prefer keeping files outside Downloads, then the oldest (the "original").
    nonisolated static func keepFirst(_ a: DupFile, _ b: DupFile) -> Bool {
        let downloads = Paths.home.appendingPathComponent("Downloads").path + "/"
        let ad = a.url.path.hasPrefix(downloads), bd = b.url.path.hasPrefix(downloads)
        if ad != bd { return !ad }
        return (a.created ?? .distantFuture) < (b.created ?? .distantFuture)
    }

    func addRoot(_ url: URL) {
        if !roots.contains(url) { roots.append(url) }
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0 == url }
    }

    func trashSelected() {
        // Never delete every copy: if a whole group is selected, keep the preferred one.
        var targets: [CleanTarget] = []
        for g in groups {
            var chosen = g.files.filter { selected.contains($0.url) }
            if chosen.count == g.files.count, let keep = g.files.sorted(by: Self.keepFirst).first {
                chosen.removeAll { $0.url == keep.url }
            }
            targets += chosen.map { CleanTarget(url: $0.url, size: g.size) }
        }
        guard !targets.isEmpty else { return }
        Task {
            let report = await Task.detached { Cleaner.remove(targets) }.value
            let removed = Set(report.removed)
            groups = groups
                .map { var g = $0; g.files.removeAll { removed.contains($0.url) }; return g }
                .filter { $0.files.count > 1 }
            selected.subtract(removed)
            lastReport = report
        }
    }
}

enum DuplicateSearch {
    static func find(roots: [URL], minBytes: Int64, excluded: [String],
                     status: @escaping @Sendable (String) -> Void) -> [DuplicateGroup] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                      .creationDateKey, .contentModificationDateKey]
        var bySize: [Int64: [DupFile]] = [:]
        var seen = Set<String>()
        var count = 0

        // 1. Group by exact size.
        for root in roots {
            DirWalker.walk(root, keys: keys) { u, _, v in
                let name = u.lastPathComponent
                if name.hasPrefix(".") || v.isPackage == true || SafetyGuard.isExcluded(u, list: excluded) { return .skip }
                if v.isDirectory == true {
                    return DeepFinder.protectedComponents.contains(name) || name == "node_modules" ? .skip : .descend
                }
                guard v.isRegularFile == true, let s = v.fileSize, Int64(s) >= minBytes else { return .skip }
                // iCloud/Drive placeholders have no local data — reading them would trigger a download.
                if (v.totalFileAllocatedSize ?? 1) == 0 { return .skip }
                guard seen.insert(u.path).inserted else { return .skip }
                bySize[Int64(s), default: []].append(DupFile(url: u, created: v.creationDate, modified: v.contentModificationDate))
                count += 1
                if count % 2000 == 0 { status("Listed \(count.formatted()) files…") }
                return .skip
            }
        }

        let candidates = bySize.filter { $0.value.count > 1 }
        let total = candidates.values.reduce(0) { $0 + $1.count }
        status("Comparing \(total.formatted()) files with matching sizes…")

        // 2. Quick hash of the first 64 KB, then 3. full SHA-256 for files that still match.
        var groups: [DuplicateGroup] = []
        var done = 0
        for (size, files) in candidates {
            if Task.isCancelled { break }
            let partial = Dictionary(grouping: files) { hash($0.url, limit: 65_536) ?? UUID().uuidString }
            for (pKey, same) in partial where same.count > 1 {
                let full = size <= 65_536 ? [pKey: same] : Dictionary(grouping: same) { hash($0.url, limit: nil) ?? UUID().uuidString }
                for (h, dupes) in full where dupes.count > 1 {
                    groups.append(DuplicateGroup(id: "\(size)-\(h)", size: size, files: dupes.sorted(by: DuplicateFinder.keepFirst)))
                }
            }
            done += files.count
            if done % 200 < files.count { status("Compared \(done.formatted()) of \(total.formatted())…") }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    static func hash(_ url: URL, limit: Int?) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        var read = 0
        while true {
            guard let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            read += chunk.count
            if let limit, read >= limit { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
