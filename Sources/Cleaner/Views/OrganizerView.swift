import SwiftUI
import AppKit

struct OrganizerView: View {
    @EnvironmentObject var ai: AISettings
    @ObservedObject var model: OrganizerModel
    @Local private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Organizer",
                       subtitle: "Tidy a messy folder into subfolders. Files are only moved — never deleted — and you can undo.") {
                if model.canUndo {
                    Button { model.undo() } label: { Label("Undo Last Organize", systemImage: "arrow.uturn.backward") }
                        .disabled(model.isApplying)
                }
            }
            .padding(20)

            controls.padding(.horizontal, 20).padding(.bottom, 12)
            Divider()

            if model.plan.isEmpty {
                emptyState
            } else {
                preview
            }

            Divider()
            footer.padding(14)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Folder:").foregroundStyle(.secondary)
                ForEach(["Downloads", "Desktop", "Documents"], id: \.self) { name in
                    let url = Paths.home.appendingPathComponent(name)
                    Button(name) { model.source = url }
                        .glassButton()
                        .tint(model.source == url ? .accentColor : .secondary)
                }
                Button("Choose…") { choose() }
                Spacer()
                Label(model.source.displayPath, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Picker("Organize", selection: $model.mode) {
                    ForEach(OrganizerModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)
                Button {
                    model.makePlan()
                } label: {
                    Label(model.mode == .ai ? "Ask AI for a Plan" : "Preview", systemImage: model.mode == .ai ? "sparkles" : "eye")
                }
                .glassButton(prominent: true)
                .disabled(model.isPlanning || model.isApplying || (model.mode == .ai && !ai.isReady))
                if model.isPlanning { ProgressView().controlSize(.small) }
                Spacer()
            }
            if model.mode == .ai {
                Text(ai.isReady
                     ? "\(ai.activeProvider.shortName) sees file names, sizes and dates (not contents) and proposes folders by project or topic. You review everything before it moves."
                     : "Connect an AI provider in Settings to use AI suggestions.")
                    .font(.caption).foregroundStyle(ai.isReady ? Color.secondary : Color.orange)
            }
        }
        .disabled(model.isApplying)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder.badge.gearshape").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(model.message ?? "Choose a folder and a style, then press Preview.").foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 480)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var preview: some View {
        List {
            if let msg = model.message { Text(msg).font(.caption).foregroundStyle(.orange) }
            ForEach(model.folders, id: \.name) { group in
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(group.name) },
                    set: { if $0 { expanded.insert(group.name) } else { expanded.remove(group.name) } })) {
                    ForEach(group.moves) { m in
                        HStack(spacing: 8) {
                            FileIcon(url: m.source, size: 16)
                            Text(m.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.bytes(m.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contextMenu { Button("Reveal in Finder") { m.source.revealInFinder() } }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { !model.excludedFolders.contains(group.name) },
                            set: { if $0 { model.excludedFolders.remove(group.name) } else { model.excludedFolders.insert(group.name) } }))
                            .toggleStyle(.checkbox).labelsHidden()
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                        Text(group.name).font(.body.weight(.medium))
                        Spacer()
                        Text("\(group.moves.count) files · \(Fmt.bytes(group.moves.reduce(0) { $0 + $1.size }))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            if !model.plan.isEmpty {
                Text("\(model.activeMoves.count) files → \(Set(model.activeMoves.map(\.folder)).count) folders inside \(model.source.lastPathComponent)")
                    .foregroundStyle(.secondary)
            } else if let msg = model.message {
                Text(msg).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isApplying { ProgressView().controlSize(.small) }
            Button("Organize Now") { model.apply() }
                .glassButton(prominent: true)
                .disabled(model.activeMoves.isEmpty || model.isApplying)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = model.source
        if panel.runModal() == .OK, let url = panel.url { model.source = url }
    }
}
