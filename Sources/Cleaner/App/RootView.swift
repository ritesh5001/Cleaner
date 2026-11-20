import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                Section("Overview") { row(.dashboard) }
                Section("Clean") {
                    row(.smartScan)
                    row(.largeFiles)
                    row(.spaceLens)
                    row(.uninstaller)
                }
                Section("Speed") { row(.maintenance) }
                Section("AI") { row(.assistant) }
                Section { row(.settings) }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        case .spaceLens: SpaceLensView(model: state.spaceLens)
        case .uninstaller: UninstallerView(model: state.uninstaller)
        case .maintenance: MaintenanceView(model: state.maintenance)
        case .assistant: AssistantView(model: state.assistant)
        case .settings: ScrollView { SettingsView().frame(maxWidth: 760).padding() }
        }
    }
}
