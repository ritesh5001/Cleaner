import SwiftUI
import AppKit

struct DuplicatesView: View {
    @ObservedObject var finder: DuplicateFinder
    @Local private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Duplicates", subtitle: subtitle) {
                if finder.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { finder.stop() }
                } else {
                    Button { finder.scan() } label: { Label("Scan", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                        .disabled(finder.roots.isEmpty)
                }
            }
            .padding(20)

            controls.padding(.horizontal, 20).padding(.bottom, 12)
            Divider()

            if finder.groups.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: finder.isScanning ? "hourglass" : "doc.on.doc")
                        .font(.system(size: 44)).foregroundStyle(.secondary)
                    Text(finder.isScanning ? finder.status : "Finds identical files (byte-for-byte, SHA-256) in the folders above.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(finder.groups) { g in
                        Section {
                            ForEach(g.files) { f in row(f, group: g) }
                        } header: {
                            HStack {
                                Text("\(g.files.count) copies · \(Fmt.bytes(g.size)) each")
                                Spacer()
                                Text("\(Fmt.bytes(g.wasted)) wasted").foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            footer.padding(14)
        }
        .confirmationDialog("Move \(finder.selected.count) duplicate(s) to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) { finder.trashSelected() }
        } message: {
            Text("At least one copy of every file is always kept.")
        }
    }

    private var subtitle: String {
        if finder.isScanning { return finder.status }
        if finder.groups.isEmpty { return "Find identical files wasting space." }
        return "\(finder.groups.count) groups · \(Fmt.bytes(finder.wastedTotal)) can be reclaimed"
    }

    private var controls: some View {
        HStack(spacing: 8) {
            ForEach(finder.roots, id: \.self) { r in
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(r.displayPath).lineLimit(1)
                    Button { finder.removeRoot(r) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            Button("Add Folder…") { addFolder() }
            Spacer()
            Picker("Min size", selection: $finder.minSizeKB) {
                Text("10 KB").tag(10)
                Text("100 KB").tag(100)
                Text("1 MB").tag(1000)
                Text("10 MB").tag(10_000)
            }
            .frame(width: 160)
        }
        .disabled(finder.isScanning)
    }

    private func row(_ f: DupFile, group: DuplicateGroup) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { finder.selected.contains(f.url) },
                set: { if $0 { finder.selected.insert(f.url) } else { finder.selected.remove(f.url) } }
            ))
            .toggleStyle(.checkbox).labelsHidden()
            FileIcon(url: f.url, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.url.lastPathComponent).lineLimit(1)
                Text(f.url.deletingLastPathComponent().displayPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !finder.selected.contains(f.url) {
                Text("Keep").font(.caption2.weight(.semibold)).foregroundStyle(.green)
            }
            Text("Created \(Fmt.date(f.created))").font(.caption).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Reveal in Finder") { f.url.revealInFinder() }
            Button("Open") { NSWorkspace.shared.open(f.url) }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let report = finder.lastReport { CleanReportBanner(report: report) }
            HStack {
                Text("\(finder.selected.count) selected · \(Fmt.bytes(finder.selectedSize))").foregroundStyle(.secondary)
                Spacer()
                Button("Auto-select (keep one)") { finder.autoSelect() }.disabled(finder.groups.isEmpty)
                Button("Move to Trash") { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(finder.selected.isEmpty)
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(finder.addRoot) }
    }
}
