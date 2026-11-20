import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                Section("Overview") { row(.dashboard) }
                Section("Clean") {
                    row(.smartScan)
                    row(.explorer)
                    row(.appStorage)
                    row(.largeFiles)
                    row(.duplicates)
                    row(.uninstaller)
                }
                Section("Organize") { row(.organizer) }
                Section("Speed") { row(.maintenance) }
                Section("AI") {
                    row(.agent)
                    row(.assistant)
                }
                Section { row(.settings) }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .background(AppBackground())
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.icon).tag(item)
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selection ?? .dashboard {
        case .dashboard: DashboardView()
        case .smartScan: SmartScanView(scanner: state.junk)
        case .largeFiles: LargeFilesView(finder: state.largeFiles)
        case .duplicates: DuplicatesView(finder: state.duplicates)
        case .explorer: ExplorerView(model: state.explorer)
        case .appStorage: AppStorageView(model: state.appStorage)
        case .organizer: OrganizerView(model: state.organizer)
        case .uninstaller: UninstallerView(model: state.uninstaller)
        case .maintenance: MaintenanceView(model: state.maintenance)
        case .agent: AgentView(model: state.agent)
        case .assistant: AssistantView(model: state.assistant)
        case .settings: ScrollView { SettingsView().frame(maxWidth: 760).padding() }
        }
    }
}
