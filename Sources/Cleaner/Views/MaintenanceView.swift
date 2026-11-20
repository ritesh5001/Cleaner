import SwiftUI

struct MaintenanceView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: MaintenanceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Memory & Maintenance",
                           subtitle: "Tasks marked with a lock ask for your administrator password through macOS.")

                HStack(alignment: .top, spacing: 16) {
                    Card { memoryCard }
                    Card { snapshotsCard }
                }

                Text("Maintenance tasks").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(MaintenanceModel.tasks) { t in taskTile(t) }
                }

                if !model.output.isEmpty {
                    Card {
                        Text("Activity").font(.headline)
                        ForEach(model.output, id: \.self) { line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            model.loadProcesses()
            model.loadSnapshots()
        }
    }

    @ViewBuilder
    private var memoryCard: some View {
        let m = state.memory
        HStack {
            Label("Memory", systemImage: "memorychip").font(.headline)
            Spacer()
            Button { model.loadProcesses() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
        }
        Text("\(Fmt.bytes(m.used)) of \(Fmt.bytes(m.total)) in use").font(.title3.weight(.semibold)).monospacedDigit()
        UsageBar(segments: [
            .init(fraction: m.fraction(m.app), color: .yellow),
            .init(fraction: m.fraction(m.wired), color: .red),
            .init(fraction: m.fraction(m.compressed), color: .purple),
        ])
        Text("Top memory users").font(.subheadline.weight(.medium)).padding(.top, 4)
        ForEach(model.processes) { p in
            HStack {
                Text(p.name).lineLimit(1)
                Spacer()
                Text(Fmt.bytes(p.memory)).monospacedDigit().foregroundStyle(.secondary)
                if p.app != nil {
                    Button("Quit") { model.quit(p) }.controlSize(.small)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var snapshotsCard: some View {
        Label("Time Machine local snapshots", systemImage: "clock.arrow.circlepath").font(.headline)
        Text("Snapshots keep deleted files' space reserved. macOS frees them when space runs low, but they often inflate “System Data”.")
            .font(.caption).foregroundStyle(.secondary)
        if model.snapshots.isEmpty {
            Text("No local snapshots on this disk.").foregroundStyle(.secondary)
        } else {
            ForEach(model.snapshots, id: \.self) { s in
                HStack {
                    Text(s.replacingOccurrences(of: "com.apple.TimeMachine.", with: "").replacingOccurrences(of: ".local", with: ""))
                        .font(.callout.monospaced())
                    Spacer()
                    Button("Delete") { model.deleteSnapshot(s) }.controlSize(.small)
                        .disabled(model.runningTask != nil)
                }
            }
        }
    }

    private func taskTile(_ t: MaintenanceTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: t.icon).font(.title2).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(t.title).font(.headline)
                    if t.admin { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                }
                Text(t.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.runningTask == t.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Run") { model.run(t) }.disabled(model.runningTask != nil)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}
