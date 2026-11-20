import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, smartScan, explorer, largeFiles, duplicates, organizer, uninstaller, maintenance, assistant, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Overview"
        case .smartScan: "Smart Scan"
        case .largeFiles: "Large & Old Files"
        case .duplicates: "Duplicates"
        case .explorer: "Storage Explorer"
        case .organizer: "Organizer"
        case .uninstaller: "Uninstaller"
        case .maintenance: "Memory & Maintenance"
        case .assistant: "AI Assistant"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .smartScan: "sparkles"
        case .largeFiles: "doc.badge.ellipsis"
        case .duplicates: "doc.on.doc"
        case .explorer: "chart.bar.doc.horizontal"
        case .organizer: "folder.badge.gearshape"
        case .uninstaller: "xmark.app"
        case .maintenance: "memorychip"
        case .assistant: "bubble.left.and.text.bubble.right"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var selection: SidebarItem? = .dashboard
    @Published private(set) var disk = DiskInfo.current()
    @Published private(set) var memory = MemoryInfo.current()
    @Published private(set) var hasFullDiskAccess = FullDiskAccess.isGranted

    let junk = JunkScanner()
    let largeFiles = LargeFileFinder()
    let duplicates = DuplicateFinder()
    let explorer = ExplorerModel()
    let organizer = OrganizerModel()
    let uninstaller = UninstallerModel()
    let maintenance = MaintenanceModel()
    let assistant = AssistantModel()

    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
        maintenance.loadSnapshots()
    }

    func refreshStats() {
        disk = .current()
        memory = .current()
        hasFullDiskAccess = FullDiskAccess.isGranted
    }
}
