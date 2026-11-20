import SwiftUI
import AppKit

struct AppStorageView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AISettings
    @ObservedObject var model: AppStorageModel
    @Local private var expanded: Set<String> = []
    @Local private var query: AIQuery?
    @Local private var pendingClean: AppFootprint?
    @Local private var pendingTrash: AppDataItem?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Storage by App", subtitle: model.isScanning ? model.status : summary) {
                if model.isScanning { ProgressView().controlSize(.small) }
                Button {
                    model.identifyUnknownWithAI()
                } label: { Label(model.isIdentifying ? "Identifying…" : "Identify Unknown with AI", systemImage: "sparkles") }
                .disabled(model.isIdentifying || model.footprints.isEmpty || !ai.isReady)
                Button { model.scan() } label: { Label(model.footprints.isEmpty ? "Scan" : "Rescan", systemImage: "arrow.clockwise") }
                    .glassButton(prominent: true)
                    .disabled(model.isScanning)
            }
            .padding(20)

            if !model.footprints.isEmpty {
                topStrip.padding(.horizontal, 20).padding(.bottom, 12)
                controls.padding(.horizontal, 20).padding(.bottom, 8)
            }
            if let msg = model.message {
                Text(msg).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 6)
            }
            Divider()

            if model.footprints.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "square.grid.3x3.square").font(.system(size: 46)).foregroundStyle(.secondary)
                    Text(model.isScanning ? model.status : "See every app with its icon and how much space its program, data and caches use.")
                        .foregroundStyle(.secondary)
                    if !model.isScanning { Button("Scan Apps") { model.scan() }.glassButton(prominent: true) }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                list
            }
        }
        .onAppear { if model.footprints.isEmpty && !model.isScanning { model.scan() } }
        .sheet(item: $query) { q in AIResponseSheet(query: q, ai: ai) }
        .confirmationDialog("Clean \(pendingClean?.owner.name ?? "")'s caches?",
                            isPresented: Binding(get: { pendingClean != nil }, set: { if !$0 { pendingClean = nil } })) {
            Button("Move \(Fmt.bytes(pendingClean?.cleanableSize ?? 0)) to Trash", role: .destructive) {
                if let f = pendingClean { clean(f) }
            }
        } message: {
            Text("Only caches, logs and web data are removed — the app and your documents/settings stay. Quit the app first for best results.")
        }
        .confirmationDialog("Move “\(pendingTrash?.url.lastPathComponent ?? "")” to the Trash?",
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("Move to Trash", role: .destructive) { if let i = pendingTrash { trash([i]) } }
        } message: {
            Text(pendingTrash?.cleanable == true ? "This is cache-type data; the app will rebuild it."
                 : "This is app data (settings, accounts, offline content). The app may lose it.")
        }
    }

    private var summary: String {
        model.footprints.isEmpty ? "Which apps use your storage?" : model.status
    }

    // MARK: Top strip

    private var topStrip: some View {
        let top = model.footprints.filter { $0.kind != .macos }.prefix(8)
        let maxTotal = max(1, top.first?.total ?? 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(top)) { f in
                    Button {
                        expanded.insert(f.id)
                    } label: {
                        VStack(spacing: 6) {
                            OwnerIcon(owner: f.owner, size: 40)
                            Text(f.owner.name).font(.caption).lineLimit(1).frame(width: 92)
                            Text(Fmt.bytes(f.total)).font(.caption.weight(.semibold)).monospacedDigit()
                            Capsule().fill(Color.accentColor)
                                .frame(width: max(4, 80 * Double(f.total) / Double(maxTotal)), height: 4)
                                .frame(width: 80, alignment: .leading)
                        }
                        .padding(10)
                        .glassCard(cornerRadius: 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var controls: some View {
        HStack {
            Picker("Show", selection: $model.filter) {
                ForEach(AppFootprint.Kind.allCases) { k in
                    Text("\(k.rawValue) (\(k == .all ? model.footprints.count : model.footprints.filter { $0.kind == k }.count))").tag(k)
                }
            }
            .frame(width: 260)
            Spacer()
            TextField("Search apps", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 220)
        }
    }

    // MARK: List

    private var list: some View {
        let maxTotal = max(1, model.visible.first?.total ?? 1)
        return List {
            ForEach(model.visible) { f in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(f.id) },
                                                    set: { if $0 { expanded.insert(f.id) } else { expanded.remove(f.id) } })) {
                    breakdown(f)
                } label: {
                    row(f, maxTotal: maxTotal)
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ f: AppFootprint, maxTotal: Int64) -> some View {
        HStack(spacing: 12) {
            OwnerIcon(owner: f.owner, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(f.owner.name).font(.body.weight(.medium)).lineLimit(1)
                    badge(for: f)
                }
                HStack(spacing: 10) {
                    if f.appBundle != nil { Text("App \(f.appSize.map(Fmt.bytes) ?? "…")") }
                    Text("Data \(Fmt.bytes(f.dataSize))")
                    if f.cleanableSize > 0 { Text("Caches \(Fmt.bytes(f.cleanableSize))").foregroundStyle(.green) }
                    Text("\(f.items.count) location\(f.items.count == 1 ? "" : "s")")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Stacked bar: app bundle | data | caches
            GeometryReader { geo in
                let w = geo.size.width * Double(f.total) / Double(maxTotal)
                let appW = f.total > 0 ? w * Double(f.appSize ?? 0) / Double(f.total) : 0
                let cacheW = f.total > 0 ? w * Double(f.cleanableSize) / Double(f.total) : 0
                HStack(spacing: 0) {
                    Rectangle().fill(Color.blue).frame(width: appW)
                    Rectangle().fill(Color.purple).frame(width: max(0, w - appW - cacheW))
                    Rectangle().fill(Color.green).frame(width: cacheW)
                }
                .clipShape(Capsule())
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 160, height: 8)
            if f.isMeasuring { ProgressView().controlSize(.mini) }
            Text(Fmt.bytes(f.total)).font(.body.weight(.semibold)).monospacedDigit().frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .contextMenu { actions(f) }
    }

    @ViewBuilder
    private func badge(for f: AppFootprint) -> some View {
        let (text, color): (String?, Color) = {
            switch f.kind {
            case .gone: return ("Not installed", .orange)
            case .tools: return ("Developer tool", .teal)
            case .macos: return ("macOS", .gray)
            case .unknown: return ("Unidentified", .secondary)
            default: return (f.owner.source == .name ? "likely" : f.owner.source == .ai ? "AI" : nil, .purple)
            }
        }()
        if let text {
            Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 1).background(color.opacity(0.14), in: Capsule())
        }
        if let note = f.owner.note {
            Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder
    private func breakdown(_ f: AppFootprint) -> some View {
        if let b = f.appBundle {
            itemRow(url: b, kind: "Application", size: f.appSize, cleanable: false, isApp: true, footprint: f)
        }
        ForEach(f.items) { i in
            itemRow(url: i.url, kind: i.kind, size: i.size, cleanable: i.cleanable, isApp: false, footprint: f)
        }
        HStack(spacing: 8) {
            if f.cleanableSize > 0 {
                Button("Clean Caches (\(Fmt.bytes(f.cleanableSize)))") { pendingClean = f }
            }
            if f.appBundle != nil {
                Button("Uninstall…") { uninstall(f) }
            }
            Button { ask(f) } label: { Label("Ask AI", systemImage: "sparkles") }
            Spacer()
        }
        .controlSize(.small)
        .padding(.vertical, 4)
    }

    private func itemRow(url: URL, kind: String, size: Int64?, cleanable: Bool, isApp: Bool, footprint: AppFootprint) -> some View {
        HStack(spacing: 8) {
            FileIcon(url: url, size: 16)
            Text(kind).font(.caption.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background((cleanable ? Color.green : Color.secondary).opacity(0.14), in: Capsule())
                .frame(width: 130, alignment: .leading)
            Text(url.displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(size.map(Fmt.bytes) ?? "…").font(.caption).monospacedDigit()
            Button { url.revealInFinder() } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Reveal in Finder")
            if !isApp {
                Button { pendingTrash = footprint.items.first { $0.url == url } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Move to Trash")
                    .disabled(SafetyGuard.blockReason(for: url) != nil)
            }
        }
    }

    @ViewBuilder
    private func actions(_ f: AppFootprint) -> some View {
        if f.cleanableSize > 0 { Button("Clean Caches…") { pendingClean = f } }
        if f.appBundle != nil {
            Button("Show App in Finder") { f.appBundle?.revealInFinder() }
            Button("Uninstall…") { uninstall(f) }
        }
        Button("Ask AI About This") { ask(f) }
    }

    // MARK: Actions

    private func ask(_ f: AppFootprint) {
        var p = "Explain what \(f.owner.name) is and why it uses this much space on my Mac, and what I can safely clean.\n\n"
        if let s = f.appSize { p += "- App bundle: \(Fmt.bytes(s))\n" }
        for i in f.items.prefix(15) { p += "- \(i.kind): `\(i.url.displayPath)` \(i.size.map(Fmt.bytes) ?? "?")\n" }
        if !f.owner.installed { p += "\nThe app appears to be no longer installed.\n" }
        query = AIQuery(title: f.owner.name, prompt: p)
    }

    private func uninstall(_ f: AppFootprint) {
        guard let b = f.appBundle else { return }
        state.uninstaller.load()
        state.uninstaller.selectedID = b
        state.selection = .uninstaller
    }

    private func clean(_ f: AppFootprint) {
        trash(f.items.filter(\.cleanable))
    }

    private func trash(_ items: [AppDataItem]) {
        let targets = items.map { CleanTarget(url: $0.url, size: $0.size ?? 0) }
        Task {
            let report = await Task.detached { Cleaner.remove(targets) }.value
            for u in report.removed {
                model.removeItem(u)
                SizeIndex.shared.invalidate(u)
            }
            model.message = report.removed.isEmpty
                ? "Nothing removed: \(report.failures.first?.reason ?? "unknown error")"
                : "Moved \(report.removed.count) item(s), \(Fmt.bytes(report.trashed + report.freed)), to the Trash."
                  + (report.failures.isEmpty ? "" : " \(report.failures.count) skipped (in use or protected).")
            pendingClean = nil
            pendingTrash = nil
        }
    }
}
