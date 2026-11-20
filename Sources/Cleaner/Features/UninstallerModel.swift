import Foundation
import AppKit

@MainActor
final class UninstallerModel: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isLoading = false
    @Published var selectedID: URL? {
        didSet { if selectedID != oldValue { findLeftovers() } }
    }
    @Published private(set) var leftovers: [ScanItem] = []
    @Published var leftoverSelection: Set<URL> = []
    @Published private(set) var isFindingLeftovers = false
    @Published var search = ""
    @Published var message: String?

    private var leftoverTask: Task<Void, Never>?

    var selectedApp: InstalledApp? { apps.first { $0.url == selectedID } }
    var filteredApps: [InstalledApp] {
        search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    var leftoverSize: Int64 { leftovers.filter { leftoverSelection.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func load() {
        guard !isLoading, apps.isEmpty else { return }
        reload()
    }

    func reload() {
        isLoading = true
        Task {
            let list = await Task.detached { AppCatalog.installedApps() }.value
            apps = list
            isLoading = false
            for app in list {
                let u = app.url
                let size = await Task.detached(priority: .utility) { FileSizer.size(of: u) }.value
                if let i = apps.firstIndex(where: { $0.url == u }) { apps[i].size = size }
            }
        }
    }

    private func findLeftovers() {
        leftoverTask?.cancel()
        leftovers = []
        leftoverSelection = []
        message = nil
        guard let app = selectedApp else { return }
        isFindingLeftovers = true
        leftoverTask = Task {
            let found = await Task.detached { LeftoverFinder.find(for: app) }.value
            guard !Task.isCancelled, selectedID == app.url else { return }
            leftovers = found
            leftoverSelection = Set(found.map(\.url))
            isFindingLeftovers = false
        }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        guard let bid = app.bundleID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
    }

    func quit(_ app: InstalledApp) {
        guard let bid = app.bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bid).forEach { $0.terminate() }
    }

    func uninstall() {
        guard let app = selectedApp else { return }
        if isRunning(app) {
            message = "\(app.name) is running. Quit it first."
            return
        }
        var targets = [CleanTarget(url: app.url, size: app.size ?? 0)]
        targets += leftovers.filter { leftoverSelection.contains($0.url) }.map { CleanTarget(url: $0.url, size: $0.size) }

        Task {
            let report = await Task.detached { Cleaner.remove(targets) }.value
            if report.removed.contains(app.url) {
                apps.removeAll { $0.url == app.url }
                selectedID = nil
                var msg = "Removed \(app.name) and \(report.removed.count - 1) leftover item(s) — \(Fmt.bytes(report.freed + report.trashed))."
                if !report.failures.isEmpty { msg += " \(report.failures.count) item(s) couldn't be removed." }
                message = msg
            } else {
                let reason = report.failures.first { $0.url == app.url }?.reason ?? "unknown error"
                message = "Couldn't remove \(app.name): \(reason). Apps installed by an administrator may need to be dragged to the Trash in Finder."
            }
        }
    }
}
