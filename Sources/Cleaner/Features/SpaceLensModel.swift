import Foundation

struct LensEntry: Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var size: Int64?
    var id: URL { url }
}

/// Drill-down folder size explorer (like DaisyDisk / Space Lens).
@MainActor
final class SpaceLensModel: ObservableObject {
    @Published private(set) var stack: [URL] = []
    @Published private(set) var entries: [LensEntry] = []
    @Published private(set) var isLoading = false

    private var cache: [URL: Int64] = [:]
    private var task: Task<Void, Never>?

    var current: URL? { stack.last }
    var total: Int64 { entries.reduce(0) { $0 + ($1.size ?? 0) } }
    var largest: Int64 { entries.compactMap(\.size).max() ?? 0 }

    func start(at url: URL) {
        stack = [url]
        load(url)
    }

    func open(_ url: URL) {
        stack.append(url)
        load(url)
    }

    func goTo(index: Int) {
        guard stack.indices.contains(index) else { return }
        stack = Array(stack.prefix(index + 1))
        load(stack[index])
    }

    func reset() {
        task?.cancel()
        stack = []
        entries = []
        isLoading = false
    }

    func refresh() {
        guard let current else { return }
        for e in entries { cache[e.url] = nil }
        load(current)
    }

    func removeEntries(_ urls: Set<URL>) {
        entries.removeAll { urls.contains($0.url) }
        for u in urls { cache[u] = nil }
        // Parent sizes are now stale.
        for parent in stack { cache[parent] = nil }
    }

    private func load(_ url: URL) {
        task?.cancel()
        entries = Paths.children(of: url).map { u in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            let isDir = v?.isDirectory == true && v?.isSymbolicLink != true && v?.isPackage != true
            return LensEntry(url: u, name: u.lastPathComponent, isDirectory: isDir, size: cache[u])
        }
        .sorted { ($0.size ?? -1) > ($1.size ?? -1) }

        let pending = entries.filter { $0.size == nil }.map(\.url)
        guard !pending.isEmpty else { isLoading = false; return }
        isLoading = true

        task = Task {
            await withTaskGroup(of: (URL, Int64).self) { group in
                for u in pending {
                    group.addTask { (u, FileSizer.size(of: u)) }
                }
                var since = 0
                for await (u, size) in group {
                    if Task.isCancelled { break }
                    cache[u] = size
                    if let i = entries.firstIndex(where: { $0.url == u }) { entries[i].size = size }
                    since += 1
                    if since >= 8 { since = 0; sortEntries() }
                }
            }
            guard !Task.isCancelled else { return }
            sortEntries()
            isLoading = false
        }
    }

    private func sortEntries() {
        entries.sort { ($0.size ?? -1) > ($1.size ?? -1) }
    }
}
