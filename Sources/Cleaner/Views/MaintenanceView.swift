import SwiftUI

struct MaintenanceView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AISettings
    @ObservedObject var model: MaintenanceModel
    @Local private var query: AIQuery?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Memory & Maintenance",
                           subtitle: "Tasks marked with a lock ask for your administrator password through macOS.") {
                    Button {
                        query = AIQuery(title: "Why is my Mac slow or full?", prompt: memoryAndSystemPrompt)
                    } label: { Label("Ask AI", systemImage: "sparkles") }
                }

                InsightsList(model: model)

                HStack(alignment: .top, spacing: 16) {
                    Card { memoryCard }
                    Card { systemDataCard }
                }

                HStack(alignment: .top, spacing: 16) {
                    Card { snapshotsCard }
                    Card { imagesCard }
                }

                Text("Maintenance tasks").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(MaintenanceModel.tasks) { t in taskTile(t) }
                }

                if !model.output.isEmpty {
                    Card {
                        Text("Activity").font(.headline)
                        ForEach(Array(model.output.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(24)
        }
        .sheet(item: $query) { q in AIResponseSheet(query: q, ai: ai) }
        .onAppear {
            model.loadSnapshots()
            model.loadSystemData()
            model.checkHealth(memory: state.memory)
        }
    }

    // MARK: Memory

    @ViewBuilder
    private var memoryCard: some View {
        let m = state.memory
        HStack {
            Label("Memory", systemImage: "memorychip").font(.headline)
            Spacer()
            Text(m.pressureLabel)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .foregroundStyle(pressureColor(m))
                .background(pressureColor(m).opacity(0.15), in: Capsule())
            Button { model.loadProcesses() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
        }
        Text("\(Fmt.bytes(m.used)) of \(Fmt.bytes(m.total)) in use").font(.title3.weight(.semibold)).monospacedDigit()
        UsageBar(segments: [
            .init(fraction: m.fraction(m.app), color: .yellow),
            .init(fraction: m.fraction(m.wired), color: .red),
            .init(fraction: m.fraction(m.compressed), color: .purple),
            .init(fraction: m.fraction(m.cached), color: .blue.opacity(0.35)),
        ])
        HStack(spacing: 12) {
            LegendItem(color: .yellow, label: "Apps", value: Fmt.bytes(m.app))
            LegendItem(color: .red, label: "Wired", value: Fmt.bytes(m.wired))
            LegendItem(color: .purple, label: "Compressed", value: Fmt.bytes(m.compressed))
        }
        HStack(spacing: 12) {
            LegendItem(color: .blue.opacity(0.35), label: "File cache", value: Fmt.bytes(m.cached))
            LegendItem(color: .gray, label: "Swap", value: "\(Fmt.bytes(m.swapUsed)) / \(Fmt.bytes(m.swapTotal))")
        }
        Text("The file cache is memory macOS lends to recently used files. It's handed back to apps instantly when needed, so it isn't “wasted” RAM. Compressed memory and swap are the real signs of pressure.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        Text("Apps using the most memory (including helpers)").font(.subheadline.weight(.medium)).padding(.top, 4)
        ForEach(model.appMemory) { a in
            HStack {
                Text(a.name).lineLimit(1)
                if a.processes > 1 {
                    Text("\(a.processes) processes").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.bytes(a.memory)).monospacedDigit().foregroundStyle(.secondary)
                if !a.runningApps.isEmpty {
                    Button("Quit") { model.quit(a) }.controlSize(.small)
                }
            }
            .font(.callout)
        }
    }

    private func pressureColor(_ m: MemoryInfo) -> Color {
        switch m.pressureLevel {
        case 4: .red
        case 2: .orange
        default: .green
        }
    }

    // MARK: System Data

    @ViewBuilder
    private var systemDataCard: some View {
        Label("What's inside “System Data”", systemImage: "externaldrive.badge.questionmark").font(.headline)
        Text("macOS files these under System Data in Storage settings.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(model.systemData) { item in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.title)
                    if item.managedByMacOS {
                        Text("macOS-managed").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    if let s = item.size {
                        Text(Fmt.bytes(s)).monospacedDigit()
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
        HStack {
            Text("Local Time Machine snapshots")
            Spacer()
            Text("\(model.snapshots.count)").monospacedDigit()
        }
        if !state.hasFullDiskAccess {
            Text("Some areas are only fully measurable with Full Disk Access.").font(.caption).foregroundStyle(.orange)
        }
    }

    // MARK: Snapshots

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

    // MARK: Disk images

    @ViewBuilder
    private var imagesCard: some View {
        HStack {
            Label("Mounted disk images", systemImage: "externaldrive.connected.to.line.below").font(.headline)
            Spacer()
            Button { model.loadImages() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
        }
        Text("Installers (.dmg) left mounted after installing an app keep their file locked and visible in Finder.")
            .font(.caption).foregroundStyle(.secondary)
        if model.images.isEmpty {
            Text("No disk images are mounted.").foregroundStyle(.secondary)
        } else {
            ForEach(model.images) { img in
                VStack(alignment: .leading, spacing: 4) {
                    Text(img.name).lineLimit(1).truncationMode(.middle)
                    Text(URL(fileURLWithPath: img.imagePath).deletingLastPathComponent().displayPath)
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Eject") { model.eject(img, moveToTrash: false) }
                        Button("Eject & Move to Trash") { model.eject(img, moveToTrash: true) }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Tasks

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
        .glassCard(cornerRadius: 12)
    }

    private var memoryAndSystemPrompt: String {
        let m = state.memory
        var s = "Diagnose my Mac's memory and System Data usage and tell me the 3 most effective actions.\n\n"
        s += "Memory: \(Fmt.bytes(m.total)) RAM, pressure \(m.pressureLabel), apps \(Fmt.bytes(m.app)), wired \(Fmt.bytes(m.wired)), compressed \(Fmt.bytes(m.compressed)), file cache \(Fmt.bytes(m.cached)), swap used \(Fmt.bytes(m.swapUsed)).\n"
        s += "Top apps by memory: " + model.appMemory.prefix(8).map { "\($0.name) \(Fmt.bytes($0.memory)) (\($0.processes) processes)" }.joined(separator: "; ") + "\n\n"
        s += "System Data breakdown:\n"
        for i in model.systemData { s += "- \(i.title) (`\(i.path)`): \(i.size.map(Fmt.bytes) ?? "unknown")\n" }
        s += "- Local snapshots: \(model.snapshots.count)\n"
        if !model.insights.isEmpty {
            s += "\nHealth checks:\n" + model.insights.map { "- \($0.title): \($0.detail)" }.joined(separator: "\n")
        }
        return s
    }
}

/// Health-check findings, shown on the Overview and Maintenance screens.
struct InsightsList: View {
    @ObservedObject var model: MaintenanceModel

    var body: some View {
        if model.isCheckingHealth && model.insights.isEmpty {
            HStack { ProgressView().controlSize(.small); Text("Running health checks…").foregroundStyle(.secondary) }
        } else if !model.insights.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.insights) { i in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: i.icon).font(.title3).foregroundStyle(i.severity.color).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.title).font(.callout.weight(.semibold))
                            Text(i.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(i.severity.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}
