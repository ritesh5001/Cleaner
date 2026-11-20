import Foundation
import SwiftUI

/// Caches folder sizes. Measuring a folder records every sub-folder it passes through,
/// so expanding deeper in the explorer is instant instead of re-scanning.
final class SizeIndex: @unchecked Sendable {
    static let shared = SizeIndex()
    private var sizes: [String: Int64] = [:]
    /// Hard-linked files already counted somewhere (shared across folders, like `du`).
    private var seenLinks = Set<NSObject>()
    private let lock = NSLock()

    private func claimLink(_ id: NSObject) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seenLinks.insert(id).inserted
    }
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .linkCountKey, .fileResourceIdentifierKey,
    ]

    func cached(_ path: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return sizes[path]
    }

    private func store(_ path: String, _ size: Int64) {
        lock.lock(); sizes[path] = size; lock.unlock()
    }

    /// Forget a removed item and every folder above it.
    func invalidate(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        let p = url.path
        sizes = sizes.filter { !($0.key == p || $0.key.hasPrefix(p + "/")) }
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" && !parent.path.isEmpty {
            sizes[parent.path] = nil
            parent = parent.deletingLastPathComponent()
        }
        sizes["/"] = nil
    }

    func measure(_ url: URL) -> Int64 {
        if let s = cached(url.path) { return s }
        return measureDir(url, depth: 0)
    }

    private func measureDir(_ dir: URL, depth: Int) -> Int64 {
        if Task.isCancelled { return 0 }
        if FileSizer.isSkipped(dir.path) { return 0 }
        if let s = cached(dir.path) { return s }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Self.keys, options: []) else { return 0 }
        var total: Int64 = 0
        for c in children {
            guard let v = try? c.resourceValues(forKeys: Set(Self.keys)), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true {
                total += measureDir(c, depth: depth + 1)
            } else if v.isRegularFile == true {
                // Hard links share data: count it once (like `du`).
                if (v.linkCount ?? 1) > 1, let id = v.fileResourceIdentifier as? NSObject {
                    guard claimLink(id) else { continue }
                }
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
        // Don't cache partial results, and skip tiny deep folders to keep memory bounded.
        if !Task.isCancelled, depth <= 4 || total >= 1_000_000 { store(dir.path, total) }
        return total
    }
}

final class ExplorerNode {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let modified: Date?
    var size: Int64?
    var children: [ExplorerNode]?
    var isExpanded = false
    var isLoading = false
    weak var parent: ExplorerNode?

    init(url: URL, isDirectory: Bool, isPackage: Bool, modified: Date?, size: Int64?, parent: ExplorerNode?) {
        self.url = url
        self.name = url.path == "/" ? "Macintosh HD" : url.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.modified = modified
        self.size = size
        self.parent = parent
    }

    var canExpand: Bool { isDirectory && !isPackage }
}

/// A flattened, render-ready snapshot of one visible tree row.
struct ExplorerRow: Identifiable, Equatable {
    let id: URL
    let name: String
    let depth: Int
    let size: Int64?
    let fraction: Double
    let canExpand: Bool
    let isExpanded: Bool
    let isLoading: Bool
    let modified: Date?
    let childCount: Int?
}

struct StorageCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let color: Color
    let paths: [String]
    var size: Int64?
}

@MainActor
final class ExplorerModel: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size", name = "Name", date = "Date Modified"
        var id: String { rawValue }
    }

    @Published private(set) var rows: [ExplorerRow] = []
    @Published private(set) var root: ExplorerNode?
    @Published var selection: URL?
    @Published var sort: Sort = .size { didSet { resortAll(); rebuild() } }
    @Published var filter = "" { didSet { rebuild() } }
    @Published var showHidden = true { didSet { reloadRoot() } }
    @Published private(set) var categories: [StorageCategory] = []
    @Published private(set) var categoriesLoading = false

    private var nodes: [URL: ExplorerNode] = [:]
    private var measureTasks: [URL: Task<Void, Never>] = [:]
    private var pendingRebuild = false

    var selectedNode: ExplorerNode? { selection.flatMap { nodes[$0] } }

    // MARK: Opening

    func open(_ url: URL) {
        measureTasks.values.forEach { $0.cancel() }
        measureTasks = [:]
        nodes = [:]
        let n = makeNode(url, parent: nil)
        root = n
        selection = nil
        expand(n)
    }

    func openIfNeeded(_ url: URL) {
        if root?.url != url { open(url) }
    }

    func goUp() {
        guard let r = root, r.url.path != "/" else { return }
        open(r.url.deletingLastPathComponent())
    }

    func focus(_ url: URL) { open(url) }

    private func reloadRoot() {
        if let r = root { open(r.url) }
    }

    private func makeNode(_ url: URL, parent: ExplorerNode?) -> ExplorerNode {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                                                  .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        let isDir = v?.isDirectory == true && v?.isSymbolicLink != true
        let size: Int64? = isDir
            ? SizeIndex.shared.cached(url.path)
            : Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        let n = ExplorerNode(url: url, isDirectory: isDir, isPackage: v?.isPackage == true,
                             modified: v?.contentModificationDate, size: size, parent: parent)
        nodes[url] = n
        return n
    }

    // MARK: Expanding

    func toggle(_ url: URL) {
        guard let n = nodes[url], n.canExpand else { return }
        if n.isExpanded {
            n.isExpanded = false
            rebuild()
        } else {
            expand(n)
        }
    }

    func expand(_ n: ExplorerNode) {
        n.isExpanded = true
        if n.children == nil { loadChildren(n) }
        rebuild()
    }

    private func loadChildren(_ n: ExplorerNode) {
        // Virtual mirrors and other volumes aren't storage on this disk — don't list them.
        var urls = Paths.children(of: n.url).filter { !FileSizer.isSkipped($0.path) }
        if !showHidden { urls = urls.filter { !$0.lastPathComponent.hasPrefix(".") } }
        n.children = urls.map { makeNode($0, parent: n) }
        sortChildren(n)
        let dirs = n.children!.filter { $0.isDirectory && $0.size == nil }.map(\.url)
        updateParentTotal(n)
        guard !dirs.isEmpty else { return }
        n.isLoading = true
        // Visible folders first, hidden ones after: hard-linked data (e.g. a sync engine's
        // staging copies) is then credited to the real folder, not the hidden copy.
        let phases = [dirs.filter { !$0.lastPathComponent.hasPrefix(".") }, dirs.filter { $0.lastPathComponent.hasPrefix(".") }]

        measureTasks[n.url] = Task {
            for pending in phases where !pending.isEmpty {
                await withTaskGroup(of: (URL, Int64).self) { group in
                    var it = pending.makeIterator()
                    for _ in 0..<4 {
                        if let u = it.next() { group.addTask { (u, SizeIndex.shared.measure(u)) } }
                    }
                    while let (u, size) = await group.next() {
                        if Task.isCancelled { break }
                        nodes[u]?.size = size
                        if let next = it.next() { group.addTask { (next, SizeIndex.shared.measure(next)) } }
                        scheduleRebuild(resortChildrenOf: n)
                    }
                }
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled else { return }
            n.isLoading = false
            sortChildren(n)
            updateParentTotal(n)
            rebuild()
        }
    }

    /// A folder's size is the sum of its children once they're all known.
    private func updateParentTotal(_ n: ExplorerNode) {
        guard let kids = n.children, kids.allSatisfy({ $0.size != nil }) else { return }
        n.size = kids.reduce(0) { $0 + ($1.size ?? 0) }
    }

    // MARK: Sorting & flattening

    private func sortChildren(_ n: ExplorerNode) {
        guard n.children != nil else { return }
        switch sort {
        case .size: n.children!.sort { ($0.size ?? -1) > ($1.size ?? -1) }
        case .name: n.children!.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date: n.children!.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
    }

    private func resortAll() {
        for n in nodes.values where n.children != nil { sortChildren(n) }
    }

    private func scheduleRebuild(resortChildrenOf n: ExplorerNode) {
        guard !pendingRebuild else { return }
        pendingRebuild = true
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            pendingRebuild = false
            sortChildren(n)
            updateParentTotal(n)
            rebuild()
        }
    }

    func rebuild() {
        guard let root else { rows = []; return }
        var out: [ExplorerRow] = []
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        func add(_ n: ExplorerNode, depth: Int) {
            let parentSize = n.parent?.size ?? n.size ?? 0
            let matches = q.isEmpty || n.name.lowercased().contains(q)
            if matches || depth == 0 {
                out.append(ExplorerRow(
                    id: n.url, name: n.name, depth: depth, size: n.size,
                    fraction: parentSize > 0 ? Double(n.size ?? 0) / Double(parentSize) : 0,
                    canExpand: n.canExpand, isExpanded: n.isExpanded, isLoading: n.isLoading,
                    modified: n.modified, childCount: n.children?.count))
            }
            if n.isExpanded, let kids = n.children {
                for k in kids { add(k, depth: depth + 1) }
            }
        }
        add(root, depth: 0)
        rows = out
    }

    // MARK: Changes

    /// Removes trashed items from the tree and fixes sizes above them.
    func removed(_ urls: [URL]) {
        for u in urls {
            guard let n = nodes[u] else { continue }
            let size = n.size ?? 0
            SizeIndex.shared.invalidate(u)
            n.parent?.children?.removeAll { $0.url == u }
            var p = n.parent
            while let node = p {
                if let s = node.size { node.size = max(0, s - size) }
                p = node.parent
            }
            nodes[u] = nil
        }
        if let s = selection, !nodes.keys.contains(s) { selection = nil }
        rebuild()
    }

    // MARK: Disk overview

    static let categorySpecs: [StorageCategory] = [
        StorageCategory(id: "apps", title: "Applications", icon: "app.badge", color: .blue,
                        paths: ["/Applications", "~/Applications"]),
        StorageCategory(id: "docs", title: "Documents & Desktop", icon: "doc.text", color: .orange,
                        paths: ["~/Documents", "~/Desktop"]),
        StorageCategory(id: "downloads", title: "Downloads", icon: "arrow.down.circle", color: .green,
                        paths: ["~/Downloads"]),
        StorageCategory(id: "media", title: "Photos, Music & Movies", icon: "photo.on.rectangle", color: .pink,
                        paths: ["~/Pictures", "~/Movies", "~/Music"]),
        StorageCategory(id: "library", title: "App Data & Caches (~/Library)", icon: "books.vertical", color: .purple,
                        paths: ["~/Library"]),
        StorageCategory(id: "dev", title: "Developer & Tool Folders (~/.*)", icon: "terminal", color: .teal,
                        paths: ["~/.*"]),
        StorageCategory(id: "otherhome", title: "Other Files in Home", icon: "folder", color: .yellow,
                        paths: ["~/*"]),
    ]

    func loadCategories(diskUsed: Int64) {
        guard !categoriesLoading else { return }
        categoriesLoading = true
        categories = Self.categorySpecs
        Task {
            let named: Set<String> = ["Applications", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library"]
            for spec in Self.categorySpecs {
                let urls: [URL]
                switch spec.paths.first {
                case "~/.*":
                    urls = Paths.children(of: Paths.home).filter { $0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != ".Trash" }
                case "~/*":
                    urls = Paths.children(of: Paths.home).filter { !$0.lastPathComponent.hasPrefix(".") && !named.contains($0.lastPathComponent) }
                default:
                    urls = spec.paths.map(Paths.expand)
                }
                let size = await Task.detached(priority: .utility) {
                    urls.reduce(Int64(0)) { $0 + (Paths.isDirectory($1) ? SizeIndex.shared.measure($1) : FileSizer.size(of: $1)) }
                }.value
                if let i = categories.firstIndex(where: { $0.id == spec.id }) { categories[i].size = size }
            }
            let known = categories.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            // Re-read the disk now: free space changes while we measure.
            let usedNow = DiskInfo.current().used
            categories.append(StorageCategory(id: "system", title: "macOS & System Data", icon: "gearshape.2", color: .gray,
                                              paths: ["/"], size: max(0, usedNow - known)))
            categoriesLoading = false
            rebuild()
        }
    }

    /// Where clicking a category should take the explorer.
    static func folder(for category: StorageCategory) -> URL {
        switch category.id {
        case "dev", "otherhome": return Paths.home
        case "system": return URL(fileURLWithPath: "/")
        default: return Paths.expand(category.paths.first ?? "~")
        }
    }
}
