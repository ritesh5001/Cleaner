import Foundation

struct LargeFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date?
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var modifiedSort: Date { modified ?? .distantPast }
    var kind: String { url.pathExtension.isEmpty ? "—" : url.pathExtension.lowercased() }
}

@MainActor
final class LargeFileFinder: ObservableObject {
    @Published var files: [LargeFile] = []
    @Published var selected: Set<URL> = []
    @Published private(set) var isScanning = false
    @Published private(set) var scannedCount = 0
    @Published var root: URL = Paths.home
    @Published var minSizeMB = 100
    @Published var olderThanDays = 0
    @Published var includeLibrary = false
    @Published var lastReport: CleanReport?

    private var worker: Task<[LargeFile], Never>?

    var selectedSize: Int64 { files.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func scan() {
        worker?.cancel()
        files = []
        selected = []
        lastReport = nil
        scannedCount = 0
        isScanning = true

        let root = root, minBytes = Int64(minSizeMB) * 1_000_000
        let days = olderThanDays, includeLibrary = includeLibrary
        let excluded = SafetyGuard.excludedPaths

        let t = Task.detached(priority: .userInitiated) { [weak self] in
            LargeFileSearch.find(root: root, minBytes: minBytes, olderThanDays: days,
                                 includeLibrary: includeLibrary, excluded: excluded) { n in
                Task { @MainActor in self?.scannedCount = n }
            }
        }
        worker = t
        Task {
            let found = await t.value
            guard !t.isCancelled else { return }
            files = found
            isScanning = false
        }
    }

    func stop() {
        worker?.cancel()
        isScanning = false
    }

    func trash(_ urls: Set<URL>) {
        let targets = files.filter { urls.contains($0.url) }.map { CleanTarget(url: $0.url, size: $0.size) }
        Task {
            let report = await Task.detached { Cleaner.remove(targets) }.value
            let removed = Set(report.removed)
            files.removeAll { removed.contains($0.url) }
            selected.subtract(removed)
            lastReport = report
        }
    }
}

enum LargeFileSearch {
    static func find(root: URL, minBytes: Int64, olderThanDays: Int, includeLibrary: Bool,
                     excluded: [String], progress: @escaping @Sendable (Int) -> Void) -> [LargeFile] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey, .contentModificationDateKey,
        ]
        let library = Paths.home.appendingPathComponent("Library").path
        let trash = Paths.home.appendingPathComponent(".Trash").path
        let cutoff = olderThanDays > 0 ? Date().addingTimeInterval(-Double(olderThanDays) * 86_400) : nil

        var out: [LargeFile] = []
        var n = 0
        DirWalker.walk(root, keys: keys) { url, _, v in
            n += 1
            if n % 4000 == 0 { progress(n) }
            let p = url.path
            if (!includeLibrary && p == library) || p == trash || FileSizer.skipPaths.contains(p)
                || SafetyGuard.isExcluded(url, list: excluded) || v.isSymbolicLink == true {
                return .skip
            }

            let size: Int64
            if v.isPackage == true {
                // Treat bundles (.app, .photoslibrary, …) as one item.
                size = FileSizer.size(of: url)
            } else if v.isDirectory == true {
                return .descend
            } else if v.isRegularFile == true {
                size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            } else {
                return .skip
            }
            if size >= minBytes, cutoff == nil || (v.contentModificationDate ?? .distantPast) <= cutoff! {
                out.append(LargeFile(url: url, size: size, modified: v.contentModificationDate))
            }
            return .skip
        }
        progress(n)
        return Array(out.sorted { $0.size > $1.size }.prefix(1000))
    }
}
