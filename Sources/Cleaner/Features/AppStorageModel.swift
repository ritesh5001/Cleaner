import Foundation

struct AppDataItem: Identifiable, Hashable {
    let url: URL
    let kind: String
    let cleanable: Bool
    var size: Int64?
    var id: URL { url }
}

struct AppFootprint: Identifiable {
    var owner: AppOwner
    var appBundle: URL?
    var appSize: Int64?
    var items: [AppDataItem]
    var id: String { owner.key }

    var dataSize: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    var cleanableSize: Int64 { items.filter(\.cleanable).reduce(0) { $0 + ($1.size ?? 0) } }
    var total: Int64 { (appSize ?? 0) + dataSize }
    var isMeasuring: Bool { (appBundle != nil && appSize == nil) || items.contains { $0.size == nil } }

    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", apps = "Apps", tools = "Developer Tools", gone = "Not Installed", macos = "macOS", unknown = "Unidentified"
        var id: String { rawValue }
    }

    var kind: Kind {
        switch owner.source {
        case .apple: .macos
        case .known: owner.bundleURL == nil ? .tools : .apps
        case .unknown: owner.installed ? .unknown : .gone
        case .ai: owner.bundleURL != nil ? .apps : (owner.symbol == "terminal" ? .tools : .unknown)
        case .bundleID, .name: .apps
        }
    }
}

/// "Which app is using my storage?" — every app with its bundle plus all the data it keeps in Library.
@MainActor
final class AppStorageModel: ObservableObject {
    @Published private(set) var footprints: [AppFootprint] = []
    @Published private(set) var isScanning = false
    @Published private(set) var status = ""
    @Published var filter: AppFootprint.Kind = .all
    @Published var search = ""
    @Published var isIdentifying = false
    @Published var message: String?

    private var task: Task<Void, Never>?

    nonisolated static let locations: [(kind: String, path: String, cleanable: Bool)] = [
        ("App data", "~/Library/Application Support", false),
        ("Cache", "~/Library/Caches", true),
        ("Sandbox container", "~/Library/Containers", false),
        ("Shared container", "~/Library/Group Containers", false),
        ("Logs", "~/Library/Logs", true),
        ("Web storage", "~/Library/HTTPStorages", true),
        ("Web data", "~/Library/WebKit", true),
        ("Saved window state", "~/Library/Saved Application State", true),
        ("Preferences", "~/Library/Preferences", false),
        ("Hidden cache", "$DARWIN_CACHE", true),
        ("Cookies", "~/Library/Cookies", false),
    ]

    var visible: [AppFootprint] {
        footprints.filter { f in
            (filter == .all || f.kind == filter)
                && (search.isEmpty || f.owner.name.localizedCaseInsensitiveContains(search))
        }
    }

    var grandTotal: Int64 { footprints.reduce(0) { $0 + $1.total } }

    func scan() {
        task?.cancel()
        isScanning = true
        message = nil
        status = "Finding app data…"
        task = Task {
            let groups = await Task.detached { Self.collect().0 }.value
            footprints = groups
            status = "Measuring \(groups.count) apps and tools…"

            // Measure everything (4 at a time), updating the list as sizes arrive.
            var jobs: [(String, URL, Bool)] = []   // (owner key, url, isAppBundle)
            for f in groups {
                if let b = f.appBundle { jobs.append((f.id, b, true)) }
                for i in f.items { jobs.append((f.id, i.url, false)) }
            }
            var lastSort = Date()
            await withTaskGroup(of: (String, URL, Bool, Int64).self) { group in
                var it = jobs.makeIterator()
                func next() {
                    if let (k, u, isApp) = it.next() {
                        group.addTask { (k, u, isApp, Paths.isDirectory(u) ? SizeIndex.shared.measure(u) : FileSizer.size(of: u)) }
                    }
                }
                for _ in 0..<4 { next() }
                while let (key, url, isApp, size) = await group.next() {
                    if Task.isCancelled { break }
                    if let fi = footprints.firstIndex(where: { $0.id == key }) {
                        if isApp { footprints[fi].appSize = size }
                        else if let ii = footprints[fi].items.firstIndex(where: { $0.url == url }) { footprints[fi].items[ii].size = size }
                    }
                    if Date().timeIntervalSince(lastSort) > 0.6 { sortFootprints(); lastSort = Date() }
                    next()
                }
            }
            guard !Task.isCancelled else { return }
            sortFootprints()
            footprints.removeAll { $0.total == 0 && $0.appBundle == nil }
            status = "\(footprints.count) apps and tools · \(Fmt.bytes(grandTotal))"
            isScanning = false
        }
    }

    private func sortFootprints() {
        footprints.sort { $0.total > $1.total }
        for i in footprints.indices { footprints[i].items.sort { ($0.size ?? -1) > ($1.size ?? -1) } }
    }

    /// Groups every data item (and app bundle) by owner. Runs off the main thread.
    nonisolated static func collect() -> ([AppFootprint], [InstalledApp]) {
        let resolver = AppOwnerResolver.shared
        resolver.reload()
        var groups: [String: AppFootprint] = [:]

        func add(_ item: AppDataItem) {
            let owner = resolver.owner(for: item.url)
                ?? AppOwner(key: "unknown:\(item.url.lastPathComponent.lowercased())", name: item.url.lastPathComponent,
                            bundleURL: nil, symbol: "questionmark.folder", source: .unknown)
            groups[owner.key, default: AppFootprint(owner: owner, appBundle: nil, appSize: nil, items: [])].items.append(item)
        }

        for loc in locations {
            for child in Paths.children(of: Paths.expand(loc.path)) {
                add(AppDataItem(url: child, kind: loc.kind, cleanable: loc.cleanable && SafetyGuard.blockReason(for: child) == nil))
            }
        }
        // Tool folders in home (~/.npm, ~/.vscode, ~/.claude…)
        for child in Paths.children(of: Paths.home) where child.lastPathComponent.hasPrefix(".")
            && Paths.isDirectory(child) && ![".Trash", ".ssh", ".config"].contains(child.lastPathComponent) {
            add(AppDataItem(url: child, kind: "Tool folder", cleanable: false))
        }

        // App bundles
        let apps = AppCatalog.installedApps()
        for app in apps {
            let key = app.bundleID?.lowercased() ?? app.url.path
            if groups[key] == nil {
                groups[key] = AppFootprint(owner: AppOwner(key: key, name: app.name, bundleURL: app.url, symbol: nil, source: .bundleID),
                                           appBundle: app.url, appSize: nil, items: [])
            } else {
                // The app bundle is proof of ownership — show it as certain, not "likely".
                groups[key]!.appBundle = app.url
                groups[key]!.owner = AppOwner(key: key, name: app.name, bundleURL: app.url, symbol: nil, source: .bundleID)
            }
        }
        return (Array(groups.values), apps)
    }

    func identifyUnknownWithAI() {
        let unknown = footprints.filter { $0.kind == .unknown || $0.owner.source == .name }
            .sorted { $0.total > $1.total }
            .prefix(60)
            .flatMap { $0.items.prefix(2).map { ($0.url, $0.size) } }
        guard !unknown.isEmpty else { message = "Everything is already identified."; return }
        isIdentifying = true
        Task {
            do {
                let n = try await AppOwnerResolver.shared.identifyWithAI(unknown)
                message = "AI identified \(n) item(s)."
                regroup()
            } catch {
                message = error.localizedDescription
            }
            isIdentifying = false
        }
    }

    /// Re-attributes already-measured items after new identifications (no re-measuring).
    private func regroup() {
        let all = footprints
        var groups: [String: AppFootprint] = [:]
        for f in all {
            if let b = f.appBundle {
                groups[f.id, default: AppFootprint(owner: f.owner, appBundle: b, appSize: f.appSize, items: [])].appBundle = b
                groups[f.id]?.appSize = f.appSize
            }
            for item in f.items {
                let owner = AppOwnerResolver.shared.owner(for: item.url) ?? f.owner
                groups[owner.key, default: AppFootprint(owner: owner, appBundle: nil, appSize: nil, items: [])].items.append(item)
            }
        }
        footprints = Array(groups.values)
        sortFootprints()
    }

    func removeItem(_ url: URL) {
        for i in footprints.indices { footprints[i].items.removeAll { $0.url == url } }
    }
}
