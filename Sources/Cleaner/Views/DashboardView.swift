import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AISettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Overview", subtitle: "\(MacInfo.chip.isEmpty ? MacInfo.model : MacInfo.chip) · macOS \(MacInfo.osVersion)")

                if !state.hasFullDiskAccess { FDABanner() }

                HStack(alignment: .top, spacing: 16) {
                    Button {
                        state.explorer.openIfNeeded(URL(fileURLWithPath: "/"))
                        state.selection = .explorer
                    } label: {
                        Card { storage }
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .help("Open Storage Explorer to see the size of every folder and file")
                    Card { memory }
                }

                InsightsList(model: state.maintenance)

                Text("What do you want to do?").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ActionTile(item: .smartScan, text: "Find caches, logs, developer junk, old installers and leftovers.")
                    ActionTile(item: .largeFiles, text: "Find big and forgotten files across your home folder.")
                    ActionTile(item: .duplicates, text: "Find identical files and keep just one copy.")
                    ActionTile(item: .explorer, text: "Browse every folder and file with its size, then clean or organize.")
                    ActionTile(item: .appStorage, text: "See each app with its icon and how much space it and its data use.")
                    ActionTile(item: .organizer, text: "Sort Downloads or Desktop into folders by type, date or AI suggestion.")
                    ActionTile(item: .uninstaller, text: "Remove apps completely, including their hidden files.")
                    ActionTile(item: .maintenance, text: "Free memory, thin snapshots, flush DNS, rebuild indexes.")
                    ActionTile(item: .assistant, text: "Ask your Claude subscription (or Gemini) what is safe to delete.")
                }

                HStack(alignment: .top, spacing: 16) {
                    Card {
                        Label("Cleaned with Cleaner", systemImage: "leaf").font(.headline)
                        Text(Fmt.bytes(CleanupLog.lifetimeCleaned)).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                        Text("Total moved to Trash or deleted, all time.").font(.caption).foregroundStyle(.secondary)
                    }
                    Card {
                        Label("AI assistant", systemImage: "sparkles").font(.headline)
                        if ai.isReady {
                            Text("\(ai.activeProvider.displayName)").font(.title3.weight(.semibold))
                            Text("Model: \(ai.model(for: ai.activeProvider))").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Not connected").font(.title3.weight(.semibold))
                            Button("Connect your Claude subscription or an API key") { state.selection = .settings }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear { state.maintenance.checkHealth(memory: state.memory) }
    }

    @ViewBuilder
    private var storage: some View {
        let d = state.disk
        HStack {
            Label("Macintosh HD", systemImage: "internaldrive").font(.headline)
            Spacer()
            Text("Explore").font(.caption).foregroundStyle(Color.accentColor)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
        }
        Text("\(Fmt.bytes(d.availableIncludingPurgeable)) available of \(Fmt.bytes(d.total))")
            .font(.title3.weight(.semibold)).monospacedDigit()
        UsageBar(segments: [
            .init(fraction: d.fraction(d.used), color: .accentColor),
            .init(fraction: d.fraction(d.purgeable), color: .accentColor.opacity(0.4)),
        ])
        HStack(spacing: 14) {
            LegendItem(color: .accentColor, label: "Used", value: Fmt.bytes(d.used))
            LegendItem(color: .accentColor.opacity(0.4), label: "Purgeable", value: Fmt.bytes(d.purgeable))
            LegendItem(color: .secondary.opacity(0.3), label: "Free", value: Fmt.bytes(d.free))
        }
    }

    @ViewBuilder
    private var memory: some View {
        let m = state.memory
        Label("Memory", systemImage: "memorychip").font(.headline)
        Text("\(Fmt.bytes(m.used)) used of \(Fmt.bytes(m.total))")
            .font(.title3.weight(.semibold)).monospacedDigit()
        UsageBar(segments: [
            .init(fraction: m.fraction(m.app), color: .yellow),
            .init(fraction: m.fraction(m.wired), color: .red),
            .init(fraction: m.fraction(m.compressed), color: .purple),
            .init(fraction: m.fraction(m.cached), color: .blue.opacity(0.35)),
        ])
        HStack(spacing: 14) {
            LegendItem(color: .yellow, label: "App", value: Fmt.bytes(m.app))
            LegendItem(color: .red, label: "Wired", value: Fmt.bytes(m.wired))
            LegendItem(color: .purple, label: "Compressed", value: Fmt.bytes(m.compressed))
        }
    }
}

private struct ActionTile: View {
    @EnvironmentObject var state: AppState
    let item: SidebarItem
    let text: String

    var body: some View {
        Button {
            state.selection = item
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: item.icon).font(.title2).foregroundStyle(Color.accentColor)
                Text(item.title).font(.headline)
                Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .glassCard(cornerRadius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
