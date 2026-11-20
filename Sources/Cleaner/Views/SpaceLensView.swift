import SwiftUI
import AppKit

struct SpaceLensView: View {
    @EnvironmentObject var ai: AISettings
    @ObservedObject var model: SpaceLensModel
    @Local private var query: AIQuery?
    @Local private var pendingTrash: LensEntry?
    @Local private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Space Lens", subtitle: subtitle) {
                if model.isLoading { ProgressView().controlSize(.small) }
                if model.current != nil {
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Recalculate")
                    Button("Start Over") { model.reset() }
                }
            }
            .padding(20)

            if model.current == nil {
                startView
            } else {
                breadcrumb.padding(.horizontal, 20).padding(.bottom, 8)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 6)
                }
                Divider()
                list
            }
        }
        .sheet(item: $query) { q in AIResponseSheet(query: q, ai: ai) }
        .confirmationDialog("Move “\(pendingTrash?.name ?? "")” to the Trash?",
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("Move to Trash", role: .destructive) { if let e = pendingTrash { trash(e) } }
        } message: {
            Text(pendingTrash?.size.map { "\(Fmt.bytes($0)) will be moved to the Trash." } ?? "")
        }
    }

    private var subtitle: String {
        guard model.current != nil else { return "Explore which folders take up your disk, then drill down." }
        return model.isLoading ? "Measuring… \(Fmt.bytes(model.total)) so far" : "\(Fmt.bytes(model.total)) in \(model.entries.count) items"
    }

    private var startView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "chart.pie").font(.system(size: 52)).foregroundStyle(.secondary)
            Text("Where should we look?").font(.title3)
            HStack(spacing: 12) {
                Button { model.start(at: Paths.home) } label: { Label("Home Folder", systemImage: "house") }
                Button { model.start(at: URL(fileURLWithPath: "/")) } label: { Label("Macintosh HD", systemImage: "internaldrive") }
                Button { chooseFolder() } label: { Label("Choose Folder…", systemImage: "folder") }
            }
            .controlSize(.large)
            Text("Scanning the whole disk is most accurate with Full Disk Access.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.stack.enumerated()), id: \.offset) { i, url in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                    Button(i == 0 ? url.displayPath : url.lastPathComponent) { model.goTo(index: i) }
                        .buttonStyle(.link)
                        .disabled(i == model.stack.count - 1)
                }
            }
        }
    }

    private var list: some View {
        List(model.entries) { e in
            HStack(spacing: 10) {
                FileIcon(url: e.url, size: 20)
                Text(e.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let s = e.size {
                    GeometryReader { geo in
                        Capsule().fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(2, geo.size.width * (model.largest > 0 ? Double(s) / Double(model.largest) : 0)))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(width: 160, height: 8)
                    Text(Fmt.bytes(s)).monospacedDigit().frame(width: 80, alignment: .trailing)
                } else {
                    ProgressView().controlSize(.small).frame(width: 248, alignment: .trailing)
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(e.isDirectory ? Color.secondary : Color.clear)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { if e.isDirectory { model.open(e.url) } }
            .contextMenu {
                Button("Reveal in Finder") { e.url.revealInFinder() }
                Button("Ask AI what this is") {
                    query = AIQuery(title: e.name, prompt: Prompts.explain(url: e.url, size: e.size, category: nil,
                                                                           includeListing: ai.shareFolderListings))
                }
                Divider()
                Button("Move to Trash…", role: .destructive) { pendingTrash = e }
                    .disabled(SafetyGuard.blockReason(for: e.url) != nil)
            }
        }
        .listStyle(.inset)
    }

    private func trash(_ e: LensEntry) {
        Task {
            let target = CleanTarget(url: e.url, size: e.size ?? 0)
            let report = await Task.detached { Cleaner.remove([target]) }.value
            if report.removed.contains(e.url) {
                model.removeEntries([e.url])
                message = "Moved \(e.name) to the Trash."
            } else {
                message = "Couldn't remove \(e.name): \(report.failures.first?.reason ?? "unknown error")"
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { model.start(at: url) }
    }
}
