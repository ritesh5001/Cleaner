import SwiftUI
import AppKit

struct ExplorerView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AISettings
    @ObservedObject var model: ExplorerModel
    @Local private var query: AIQuery?
    @Local private var pendingTrash: [URL] = []
    @Local private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Storage Explorer", subtitle: subtitle) {
                Button { model.open(URL(fileURLWithPath: "/")) } label: { Label("Macintosh HD", systemImage: "internaldrive") }
                Button { model.open(Paths.home) } label: { Label("Home", systemImage: "house") }
                Button { chooseFolder() } label: { Label("Choose…", systemImage: "folder") }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)

            if model.root?.url.path == "/" || model.root?.url == Paths.home {
                overview.padding(.horizontal, 20).padding(.bottom, 12)
            }

            toolbar.padding(.horizontal, 20).padding(.bottom, 8)
            Divider()
            tree
            Divider()
            actionBar.padding(12)
        }
        .onAppear {
            if model.root == nil { model.open(URL(fileURLWithPath: "/")) }
            if model.categories.isEmpty { model.loadCategories(diskUsed: state.disk.used) }
        }
        .sheet(item: $query) { q in AIResponseSheet(query: q, ai: ai) }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } })) {
            Button("Move to Trash", role: .destructive) { trash(pendingTrash) }
        } message: {
            Text("Items go to the Trash, so you can restore them until the Trash is emptied.")
        }
    }

    private var subtitle: String {
        guard let r = model.root else { return "See the size of every folder and file." }
        return "\(r.url.path == "/" ? "Macintosh HD" : r.url.displayPath) · \(r.size.map(Fmt.bytes) ?? "measuring…") · click ▸ to expand, double-click to focus"
    }

    /// Why a "256 GB" Mac shows ~245 GB.
    private var capacityNote: String {
        let marketed = [128, 256, 512, 1000, 2000, 4000, 8000].first { Double($0) * 1e9 >= Double(state.disk.total) } ?? 0
        return "Your Mac is sold as \(marketed >= 1000 ? "\(marketed / 1000) TB" : "\(marketed) GB"). macOS keeps a few GB for the Recovery system and firmware, and flash storage reserves some space for wear-levelling, so \(Fmt.bytes(state.disk.total)) is usable. Sizes here count 1 GB = 1,000,000,000 bytes, like Finder."
    }

    private var trashTitle: String {
        pendingTrash.count == 1 ? "Move “\(pendingTrash[0].lastPathComponent)” to the Trash?" : "Move \(pendingTrash.count) items to the Trash?"
    }

    // MARK: Overview (what is using the disk)

    private var overview: some View {
        let total = max(1, state.disk.total)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(model.categories) { c in
                        Rectangle().fill(c.color.opacity(c.size == nil ? 0.25 : 0.85))
                            .frame(width: max(0, geo.size.width * Double(c.size ?? 0) / Double(total)))
                            .help("\(c.title): \(c.size.map(Fmt.bytes) ?? "measuring…")")
                            .onTapGesture { model.open(ExplorerModel.folder(for: c)) }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 16)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(model.categories) { c in
                    Button { model.open(ExplorerModel.folder(for: c)) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(c.color).frame(width: 8, height: 8)
                            Image(systemName: c.icon).frame(width: 16)
                            Text(c.title).lineLimit(1)
                            Spacer(minLength: 4)
                            if let s = c.size { Text(Fmt.bytes(s)).monospacedDigit().foregroundStyle(.secondary) }
                            else { ProgressView().controlSize(.mini) }
                        }
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let r = model.root, r.url.path == "/", let measured = r.size, !(r.isLoading), state.disk.used > measured {
                Label("Storage Fusion can see \(Fmt.bytes(measured)) of the \(Fmt.bytes(state.disk.used)) in use. The other \(Fmt.bytes(state.disk.used - measured)) is in places macOS hides\(state.hasFullDiskAccess ? "" : " (grant Full Disk Access to see more)"): the Trash, swap, local snapshots, the Preboot/VM volumes and other users' files. Items you moved to the Trash still use space until you empty it.",
                      systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("\(Fmt.bytes(state.disk.used)) used · \(Fmt.bytes(state.disk.free)) free of \(Fmt.bytes(state.disk.total))")
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .help(capacityNote)
                Spacer()
                Button {
                    query = AIQuery(title: "How should I free up space?", prompt: overviewPrompt)
                } label: { Label("Ask AI what to remove", systemImage: "sparkles") }
                .controlSize(.small)
                .disabled(model.categoriesLoading)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .help("Up one level")
                .disabled(model.root?.url.path == "/" || model.root == nil)
            Picker("Sort", selection: $model.sort) {
                ForEach(ExplorerModel.Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 190)
            Toggle("Hidden items", isOn: $model.showHidden)
            Spacer()
            TextField("Filter shown items", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
        }
    }

    // MARK: Tree

    private var tree: some View {
        List(model.rows, selection: $model.selection) { row in
            ExplorerRowView(row: row) { model.toggle(row.id) }
                .tag(row.id)
                .contextMenu { menu(for: row) }
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if row.canExpand { model.focus(row.id) } else { NSWorkspace.shared.open(row.id) }
                })
        }
        .listStyle(.inset)
        .overlay {
            if model.rows.isEmpty { ProgressView() }
        }
    }

    @ViewBuilder
    private func menu(for row: ExplorerRow) -> some View {
        Button("Reveal in Finder") { row.id.revealInFinder() }
        Button("Open") { NSWorkspace.shared.open(row.id) }
        if row.canExpand {
            Button("Focus on This Folder") { model.focus(row.id) }
            Button("Organize This Folder…") { organize(row.id) }
        }
        Button("Ask AI What This Is") { ask(row) }
        Divider()
        Button("Move to Trash…", role: .destructive) { pendingTrash = [row.id] }
            .disabled(SafetyGuard.blockReason(for: row.id) != nil)
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let n = model.selectedNode {
                FileIcon(url: n.url, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(n.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text("\(n.url.displayPath) · \(n.size.map(Fmt.bytes) ?? "measuring…")\(n.modified.map { " · modified \(Fmt.date($0))" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let reason = SafetyGuard.blockReason(for: n.url) {
                    Label(reason, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                }
                Button("Reveal") { n.url.revealInFinder() }
                Button { ask(row(for: n)) } label: { Label("Ask AI", systemImage: "sparkles") }
                if n.canExpand { Button("Organize…") { organize(n.url) } }
                Button("Move to Trash", role: .destructive) { pendingTrash = [n.url] }
                    .disabled(SafetyGuard.blockReason(for: n.url) != nil)
            } else {
                Text(message ?? "Select a file or folder to see actions. Sizes are space actually used on disk.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .controlSize(.small)
    }

    private func row(for n: ExplorerNode) -> ExplorerRow {
        ExplorerRow(id: n.url, name: n.name, depth: 0, size: n.size, fraction: 0, canExpand: n.canExpand,
                    isExpanded: n.isExpanded, isLoading: n.isLoading, modified: n.modified, childCount: n.children?.count)
    }

    // MARK: Actions

    private func ask(_ row: ExplorerRow) {
        query = AIQuery(title: row.name, prompt: Prompts.explain(url: row.id, size: row.size, category: nil,
                                                                 includeListing: ai.shareFolderListings))
    }

    private func organize(_ url: URL) {
        state.organizer.source = url
        state.selection = .organizer
    }

    private func trash(_ urls: [URL]) {
        let targets = urls.map { CleanTarget(url: $0, size: model.selectedNode?.url == $0 ? (model.selectedNode?.size ?? 0) : 0) }
        Task {
            let report = await Task.detached { Cleaner.remove(targets) }.value
            model.removed(report.removed)
            message = report.removed.isEmpty
                ? "Couldn't remove: \(report.failures.first?.reason ?? "unknown error")"
                : "Moved \(report.removed.count) item(s) to the Trash."
            pendingTrash = []
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { model.open(url) }
    }

    private var overviewPrompt: String {
        var s = "Here is what uses the disk on my Mac (\(Fmt.bytes(state.disk.total)) total, \(Fmt.bytes(state.disk.free)) free). "
        s += "Tell me where the biggest realistic savings are and what to keep.\n\n"
        for c in model.categories { s += "- \(c.title): \(c.size.map(Fmt.bytes) ?? "unknown")\n" }
        if let root = model.root, let kids = root.children {
            s += "\nLargest items in `\(root.url.displayPath)`:\n"
            for k in kids.prefix(15) { s += "- `\(k.url.displayPath)` \(k.size.map(Fmt.bytes) ?? "…")\n" }
        }
        return s
    }
}

private struct ExplorerRowView: View {
    let row: ExplorerRow
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
            Button(action: onToggle) {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 14)
                    .opacity(row.canExpand ? 1 : 0)
            }
            .buttonStyle(.plain)
            .disabled(!row.canExpand)

            FileIcon(url: row.id, size: 18)
            Text(row.name).lineLimit(1).truncationMode(.middle)
            if let n = row.childCount, row.isExpanded {
                Text("\(n) items").font(.caption2).foregroundStyle(.tertiary)
            }
            if row.isLoading { ProgressView().controlSize(.mini) }
            Spacer(minLength: 8)

            Text(Fmt.date(row.modified)).font(.caption).foregroundStyle(.secondary).frame(width: 95, alignment: .trailing)
            if row.depth > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(barColor).frame(width: max(2, geo.size.width * min(1, row.fraction)))
                    }
                }
                .frame(width: 110, height: 7)
                Text(row.size == nil ? "" : String(format: "%.1f%%", row.fraction * 100))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            } else {
                Color.clear.frame(width: 162, height: 1)
            }
            Group {
                if let s = row.size { Text(Fmt.bytes(s)) } else { ProgressView().controlSize(.mini) }
            }
            .monospacedDigit()
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }

    private var barColor: Color {
        row.fraction > 0.4 ? .red : row.fraction > 0.15 ? .orange : .accentColor
    }
}
