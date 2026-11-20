import SwiftUI
import AppKit

struct LargeFilesView: View {
    @EnvironmentObject var ai: AISettings
    @ObservedObject var finder: LargeFileFinder
    @Local private var sortOrder = [KeyPathComparator(\LargeFile.size, order: .reverse)]
    @Local private var query: AIQuery?
    @Local private var confirmTrash = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Large & Old Files", subtitle: subtitle) {
                if finder.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { finder.stop() }
                } else {
                    if !finder.files.isEmpty {
                        Button {
                            query = AIQuery(title: "AI review of your largest files", prompt: Prompts.reviewLargeFiles(finder.files))
                        } label: { Label("AI Review", systemImage: "sparkles") }
                    }
                    Button { finder.scan() } label: { Label("Scan", systemImage: "magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)

            controls.padding(.horizontal, 20).padding(.bottom, 12)
            Divider()

            Table(finder.files, selection: $finder.selected, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { f in
                    HStack(spacing: 6) {
                        FileIcon(url: f.url, size: 16)
                        Text(f.name).lineLimit(1)
                        if SafetyGuard.blockReason(for: f.url) != nil {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                .help(SafetyGuard.blockReason(for: f.url) ?? "")
                        }
                    }
                }
                TableColumn("Location") { f in
                    Text(f.url.deletingLastPathComponent().displayPath)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                TableColumn("Kind", value: \.kind) { f in Text(f.kind).foregroundStyle(.secondary) }
                    .width(60)
                TableColumn("Modified", value: \.modifiedSort) { f in Text(Fmt.date(f.modified)).foregroundStyle(.secondary) }
                    .width(110)
                TableColumn("Size", value: \.size) { f in Text(Fmt.bytes(f.size)).monospacedDigit() }
                    .width(90)
            }
            .onChange(of: sortOrder) { _, order in finder.files.sort(using: order) }
            .contextMenu(forSelectionType: URL.self) { urls in
                if let url = urls.first {
                    Button("Reveal in Finder") { url.revealInFinder() }
                    Button("Quick Look / Open") { NSWorkspace.shared.open(url) }
                    Button("Ask AI what this is") {
                        let size = finder.files.first { $0.url == url }?.size
                        query = AIQuery(title: url.lastPathComponent,
                                        prompt: Prompts.explain(url: url, size: size, category: "Large file",
                                                                includeListing: ai.shareFolderListings))
                    }
                    Divider()
                }
                Button("Move to Trash", role: .destructive) { finder.trash(urls) }
                    .disabled(urls.isEmpty)
            } primaryAction: { urls in
                urls.first?.revealInFinder()
            }
            .overlay {
                if finder.files.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: finder.isScanning ? "hourglass" : "doc.badge.ellipsis")
                            .font(.system(size: 42)).foregroundStyle(.secondary)
                        Text(finder.isScanning ? "Looking through \(finder.scannedCount.formatted()) files…" : "Choose a folder and minimum size, then Scan.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            footer.padding(14)
        }
        .sheet(item: $query) { q in AIResponseSheet(query: q, ai: ai) }
        .confirmationDialog("Move \(finder.selected.count) file(s) to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { finder.trash(finder.selected) }
        } message: {
            Text("\(Fmt.bytes(finder.selectedSize)) will be moved to the Trash. You can restore them from the Trash until it is emptied.")
        }
    }

    private var subtitle: String {
        if finder.isScanning { return "Scanned \(finder.scannedCount.formatted()) files…" }
        if finder.files.isEmpty { return "Find big files you forgot about. Bundles like apps are measured as a whole." }
        return "\(finder.files.count) files · \(Fmt.bytes(finder.files.reduce(0) { $0 + $1.size })) total"
    }

    private var controls: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(finder.root.displayPath).lineLimit(1).truncationMode(.middle)
                Button("Change…") { chooseFolder() }
            }
            Picker("Larger than", selection: $finder.minSizeMB) {
                Text("50 MB").tag(50)
                Text("100 MB").tag(100)
                Text("500 MB").tag(500)
                Text("1 GB").tag(1000)
                Text("5 GB").tag(5000)
            }
            .frame(width: 180)
            Picker("Not modified for", selection: $finder.olderThanDays) {
                Text("Any time").tag(0)
                Text("1 month").tag(30)
                Text("3 months").tag(90)
                Text("6 months").tag(180)
                Text("1 year").tag(365)
            }
            .frame(width: 230)
            Toggle("Include ~/Library", isOn: $finder.includeLibrary)
            Spacer()
        }
        .disabled(finder.isScanning)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let report = finder.lastReport { CleanReportBanner(report: report) }
            HStack {
                Text("\(finder.selected.count) selected · \(Fmt.bytes(finder.selectedSize))").foregroundStyle(.secondary)
                Spacer()
                Button("Move to Trash") { confirmTrash = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(finder.selected.isEmpty)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = finder.root
        if panel.runModal() == .OK, let url = panel.url { finder.root = url }
    }
}
