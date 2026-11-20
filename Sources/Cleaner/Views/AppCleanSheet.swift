import SwiftUI
import AppKit

/// What the sheet is cleaning: one app with a chosen option, or a bulk action across apps.
struct AppCleanRequest: Identifiable {
    enum Scope {
        case app(AppFootprint, AppCleanOption, custom: Set<URL>)
        case allSafeCaches
        case allLeftovers
    }
    let id = UUID()
    let scope: Scope
}

struct AppCleanSheet: View {
    let request: AppCleanRequest
    @ObservedObject var model: AppStorageModel
    var onUninstalled: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @Local private var option: AppCleanOption = .safe
    @Local private var method: DeleteMethod = .trash
    @Local private var running = false
    @Local private var progress = ""
    @Local private var result: String?
    @Local private var didSetup = false
    @Local private var tick = 0

    // MARK: Derived

    private var footprint: AppFootprint? {
        if case .app(let f, _, _) = request.scope { return model.footprints.first { $0.id == f.id } ?? f }
        return nil
    }

    private var custom: Set<URL> {
        if case .app(_, _, let c) = request.scope { return c }
        return []
    }

    private var groups: [(AppFootprint, [AppCleanTarget])] {
        switch request.scope {
        case .app: if let f = footprint { return [(f, option.targets(f, custom: custom))] } else { return [] }
        case .allSafeCaches: return model.allSafeCaches
        case .allLeftovers: return model.allLeftovers
        }
    }

    private var total: Int64 { groups.flatMap(\.1).reduce(0) { $0 + $1.size } }
    private var count: Int { groups.flatMap(\.1).count }

    private var runningApps: [NSRunningApplication] {
        _ = tick
        return footprint.map(AppCleaner.running) ?? []
    }

    private var title: String {
        switch request.scope {
        case .app(let f, _, _): "Clean Up \(f.owner.name)"
        case .allSafeCaches: "Clean Safe Caches of All Apps"
        case .allLeftovers: "Remove Leftovers of Uninstalled Apps"
        }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let result {
                resultView(result)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if case .app(let f, _, _) = request.scope { optionPicker(f) }
                        targetList
                        methodPicker
                        if !runningApps.isEmpty { runningWarning }
                    }
                    .padding(2)
                }
                footer
            }
        }
        .padding(24)
        .frame(width: 640, height: 620)
        .background(AppBackground())
        .onAppear {
            guard !didSetup else { return }
            didSetup = true
            if case .app(_, let o, _) = request.scope { option = o }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let f = footprint {
                OwnerIcon(owner: f.owner, size: 48)
            } else {
                SymbolTile(symbol: request.isLeftovers ? "puzzlepiece.extension" : "leaf", color: request.isLeftovers ? .orange : .green, size: 48)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.bold))
                Text("\(count) item(s) · \(Fmt.bytes(total))").foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
        }
    }

    private func optionPicker(_ f: AppFootprint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What to remove").font(.headline)
            ForEach(AppCleanOption.available(for: f)) { o in
                let size = o.targets(f, custom: custom).reduce(Int64(0)) { $0 + $1.size }
                Button {
                    option = o
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: option == o ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(option == o ? Color.accentColor : .secondary)
                            .font(.title3)
                        Image(systemName: o.symbol).frame(width: 22).foregroundStyle(o.safety.color)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(o.title).font(.body.weight(.semibold))
                                SafetyBadge(safety: o.safety)
                            }
                            Text(o.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(Fmt.bytes(size)).font(.callout.weight(.semibold)).monospacedDigit()
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                    .glassCard(cornerRadius: 14, tint: option == o ? .accentColor : nil, interactive: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(count == 0 ? "Nothing to remove for this option." : "Will be removed").font(.headline)
            ForEach(groups, id: \.0.id) { f, targets in
                if case .app = request.scope {} else {
                    HStack(spacing: 8) {
                        OwnerIcon(owner: f.owner, size: 18)
                        Text(f.owner.name).font(.callout.weight(.semibold))
                        Spacer()
                        Text(Fmt.bytes(targets.reduce(0) { $0 + $1.size })).font(.caption).monospacedDigit()
                    }
                    .padding(.top, 4)
                }
                ForEach(targets) { t in
                    HStack(spacing: 8) {
                        FileIcon(url: t.url, size: 16)
                        Text(t.kind).font(.caption.weight(.semibold)).frame(width: 120, alignment: .leading)
                        Text(t.url.displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Fmt.bytes(t.size)).font(.caption).monospacedDigit()
                    }
                }
            }
            if case .app(let f, _, _) = request.scope {
                let removed = Set(option.targets(f, custom: custom).map(\.url))
                let kept = (f.appBundle.map { [$0] } ?? []) + f.items.map(\.url)
                let keptList = kept.filter { !removed.contains($0) }
                if !keptList.isEmpty {
                    Text("Kept: \(keptList.count) location(s) — " + keptList.prefix(4).map(\.lastPathComponent).joined(separator: ", ") + (keptList.count > 4 ? "…" : ""))
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
    }

    private var methodPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to delete").font(.headline)
            Picker("", selection: $method) {
                ForEach(DeleteMethod.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(method.detail).font(.caption).foregroundStyle(method == .permanent ? .orange : .secondary)
        }
    }

    private var runningWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(footprint?.owner.name ?? "The app") is running. Quit it first so it doesn't recreate or lock files while they're removed.")
                .font(.callout)
            Spacer()
            Button("Quit App") {
                runningApps.forEach { $0.terminate() }
                Task { try? await Task.sleep(for: .seconds(2)); tick += 1 }
            }
            .glassButton()
        }
        .padding(12)
        .glassCard(cornerRadius: 14, tint: .orange)
    }

    private var footer: some View {
        HStack {
            if !progress.isEmpty {
                ProgressView().controlSize(.small)
                Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Cancel") { dismiss() }.glassButton().keyboardShortcut(.cancelAction)
            Button(confirmTitle, role: .destructive) { perform() }
                .glassButton(prominent: true)
                .disabled(count == 0 || !progress.isEmpty || (needsQuit && !runningApps.isEmpty))
        }
        .controlSize(.large)
    }

    /// Removing an app's data — or the caches inside it — while it runs can corrupt it.
    private var needsQuit: Bool {
        guard case .app(let f, _, _) = request.scope else { return false }
        if option != .safe { return true }
        return option.targets(f).contains { $0.kind == AppDataItem.nestedKind }
    }

    private var confirmTitle: String {
        switch method {
        case .trash: "Move \(Fmt.bytes(total)) to Trash"
        case .permanent: "Delete \(Fmt.bytes(total)) Permanently"
        case .archive: "Back Up & Delete \(Fmt.bytes(total))"
        }
    }

    private func resultView(_ text: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(.green)
            Text(text).multilineTextAlignment(.center).textSelection(.enabled)
            Button("Done") { dismiss() }.glassButton(prominent: true).keyboardShortcut(.defaultAction)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Run

    private func perform() {
        let work = groups
        let method = method
        let option = option
        progress = "Starting…"
        Task {
            var removedTotal = 0, freed: Int64 = 0, failures = 0
            var backups: [URL] = []
            var uninstalled = false
            for (f, targets) in work {
                let r = await Task.detached {
                    AppCleaner.run(targets, method: method, appName: f.owner.name) { msg in
                        Task { @MainActor in progress = msg }
                    }
                }.value
                model.applyRemoval(r.0.removed, from: f.id)
                removedTotal += r.0.removed.count
                freed += r.0.freed + r.0.trashed
                failures += r.0.failures.count + r.backupFailures.count
                if let b = r.backup { backups.append(b) }
                if let app = f.appBundle, r.0.removed.contains(app) { uninstalled = true }
            }
            if uninstalled { onUninstalled() }
            var text = "Removed \(removedTotal) item(s) — \(Fmt.bytes(freed))."
            if method == .trash { text += "\nThey're in the Trash; empty it to get the space back." }
            if let b = backups.first { text += "\nBackup saved in \(b.deletingLastPathComponent().displayPath)." }
            if failures > 0 { text += "\n\(failures) item(s) were skipped (in use, protected, or backup failed)." }
            if option == .appOnly { text += "\nYour settings were kept for a future reinstall." }
            progress = ""
            result = text
            if let b = backups.first { NSWorkspace.shared.activateFileViewerSelecting([b]) }
        }
    }
}

private extension AppCleanRequest {
    var isLeftovers: Bool { if case .allLeftovers = scope { return true }; return false }
}
