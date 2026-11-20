import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Storage Fusion").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Disk", systemImage: "internaldrive")
                    Spacer()
                    Text("\(Fmt.bytes(state.disk.availableIncludingPurgeable)) free").monospacedDigit()
                }
                UsageBar(segments: [.init(fraction: state.disk.fraction(state.disk.used), color: .accentColor)], height: 6)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Memory", systemImage: "memorychip")
                    Spacer()
                    Text("\(Fmt.bytes(state.memory.used)) used").monospacedDigit()
                }
                UsageBar(segments: [.init(fraction: state.memory.fraction(state.memory.used), color: .purple)], height: 6)
            }

            Divider()
            Button("Open Storage Fusion") { show(.dashboard) }
            Button("Run Smart Scan") {
                show(.smartScan)
                state.junk.scan()
            }
            Button("Ask AI") { show(.assistant) }
            Divider()
            Button("Quit Storage Fusion") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(14)
        .frame(width: 270)
        .onAppear { state.refreshStats() }
    }

    private func show(_ item: SidebarItem) {
        MainWindowController.shared.show()
        state.selection = item
    }
}
