import SwiftUI

struct SmartScanView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AISettings
    @ObservedObject var scanner: JunkScanner
    @Local private var expanded: Set<String> = []
    @Local private var query: AIQuery?
    @Local private var confirmClean = false
    @Local private var identifying = false
    @Local private var identifyMessage: String?
    /// Bumped after AI identification so rows re-resolve their owners.
    @Local private var ownerRevision = 0

    private var unidentified: [ScanItem] {
        _ = ownerRevision
        return scanner.results.flatMap(\.items).filter {
            let o = AppOwnerResolver.shared.owner(for: $0.url)
            return o == nil || o?.source == .name || o?.source == .unknown
        }
    }

    private func identifyWithAI() {
        let items = unidentified.sorted { $0.size > $1.size }.prefix(60).map { ($0.url, Optional($0.size)) }
        identifying = true
        identifyMessage = nil
        Task {
            do {
                let n = try await AppOwnerResolver.shared.identifyWithAI(items)
                identifyMessage = "\(ai.activeProvider.shortName) identified \(n) item(s)."
            } catch {
                identifyMessage = error.localizedDescription
            }
            ownerRevision += 1
            identifying = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Smart Scan", subtitle: subtitle) {
                if scanner.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { scanner.stop() }
                } else {
                    if !scanner.results.isEmpty, !unidentified.isEmpty {
                        Button { identifyWithAI() } label: {
                            Label(identifying ? "Identifying…" : "Identify Apps with AI (\(unidentified.count))", systemImage: "questionmark.app")
                        }
                        .disabled(identifying || !ai.isReady)
                        .help(ai.isReady ? "Ask \(ai.activeProvider.shortName) which app created the folders Cleaner couldn't match"
                                         : "Connect an AI provider in Settings first")
                    }
                    if !scanner.results.isEmpty {
                        Button {
                            query = AIQuery(title: "AI review of your scan",
                                            prompt: Prompts.reviewScan(scanner.results, selected: scanner.selected))
                        } label: { Label("AI Review", systemImage: "sparkles") }
                    }
                    Button { scanner.scan() } label: {
                        Label(scanner.results.isEmpty ? "Scan" : "Rescan", systemImage: "magnifyingglass")
                    }
                    .glassButton(prominent: true)
                }
            }
            .padding(20)

            if !state.hasFullDiskAccess { FDABanner().padding(.horizontal, 20).padding(.bottom, 12) }
            if let identifyMessage {
                Label(identifyMessage, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }

            Divider()

            if scanner.results.isEmpty {
                emptyState
            } else {
                resultsList
            }

            Divider()
            footer.padding(14)
        }
        .sheet(item: $query) { q in AIResponseSheet(query: q, ai: ai) }
        .confirmationDialog("Clean \(Fmt.bytes(scanner.selectedSize))?", isPresented: $confirmClean) {
            Button("Clean \(scanner.selected.count) items", role: .destructive) { scanner.clean() }
        } message: {
            Text(Cleaner.deletePermanently
                 ? "Selected items will be deleted permanently."
                 : "Selected items will be moved to the Trash (Trash items are deleted permanently).")
        }
    }

    private var subtitle: String {
        if scanner.isScanning { return scanner.status }
        if let last = scanner.lastScan {
            return "\(Fmt.bytes(scanner.totalFound)) of junk found · scanned \(Fmt.relative(last))"
        }
        return "Finds caches, logs, developer junk, old installers, backups and app leftovers."
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: scanner.isScanning ? "hourglass" : "sparkles")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text(scanner.isScanning ? "Scanning your Mac…" : (scanner.lastScan == nil ? "Run a scan to see what can be cleaned" : "Your Mac is clean"))
                .font(.title3)
            if !scanner.isScanning, scanner.lastScan == nil {
                Text("Nothing is removed until you review and confirm.").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var resultsList: some View {
        List {
            ForEach(RuleGroup.allCases) { group in
                let cats = scanner.results.filter { $0.rule.group == group }
                if !cats.isEmpty {
                    Section(group.rawValue) {
                        ForEach(cats) { cat in
                            DisclosureGroup(isExpanded: expandedBinding(cat.id)) {
                                ForEach(cat.items) { item in itemRow(item, in: cat) }
                            } label: {
                                categoryRow(cat)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func categoryRow(_ cat: CategoryResult) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: categoryBinding(cat)).toggleStyle(.checkbox).labelsHidden()
            Image(systemName: cat.rule.icon).frame(width: 20).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cat.rule.title).font(.body.weight(.medium))
                    SafetyBadge(safety: cat.rule.safety)
                }
                Text(cat.rule.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if cat.heldTotal > 0 {
                    Label("+ \(Fmt.bytes(cat.heldTotal)) more in running apps (\(cat.holdingApps.joined(separator: ", "))). Quit them and rescan to include.",
                          systemImage: "lock.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text("\(cat.items.count) items").font(.caption).foregroundStyle(.secondary)
            Text(Fmt.bytes(cat.total)).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func itemRow(_ item: ScanItem, in cat: CategoryResult) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: itemBinding(item.url)).toggleStyle(.checkbox).labelsHidden()
            OwnerIcon(owner: owner(item.url), fallback: item.url, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1)
                    OwnerTag(owner: owner(item.url))
                }
                Text(item.url.deletingLastPathComponent().displayPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(Fmt.relative(item.modified)).font(.caption).foregroundStyle(.secondary)
            Button {
                query = AIQuery(title: item.name, prompt: Prompts.explain(url: item.url, size: item.size,
                                                                          category: cat.rule.title,
                                                                          includeListing: ai.shareFolderListings))
            } label: { Image(systemName: "sparkles") }
            .buttonStyle(.borderless)
            .help("Ask AI what this is")
            Text(Fmt.bytes(item.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .contextMenu {
            Button("Reveal in Finder") { item.url.revealInFinder() }
            Button("Ask AI what this is") {
                query = AIQuery(title: item.name, prompt: Prompts.explain(url: item.url, size: item.size,
                                                                          category: cat.rule.title,
                                                                          includeListing: ai.shareFolderListings))
            }
            Button("Always skip this item") {
                SafetyGuard.excludedPaths.append(item.url.path)
                scanner.selected.remove(item.url)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let report = scanner.lastReport {
                CleanReportBanner(report: report) { scanner.emptyTrash() }
            }
            HStack {
                Text("\(scanner.selected.count) items selected · \(Fmt.bytes(scanner.selectedSize))")
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if scanner.isCleaning { ProgressView().controlSize(.small) }
                Button("Clean") { confirmClean = true }
                    .glassButton(prominent: true)
                    .controlSize(.large)
                    .disabled(scanner.selected.isEmpty || scanner.isCleaning || scanner.isScanning)
            }
        }
    }

    private func owner(_ url: URL) -> AppOwner? {
        _ = ownerRevision
        return AppOwnerResolver.shared.owner(for: url)
    }

    // MARK: Bindings

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func itemBinding(_ url: URL) -> Binding<Bool> {
        Binding(get: { scanner.selected.contains(url) },
                set: { if $0 { scanner.selected.insert(url) } else { scanner.selected.remove(url) } })
    }

    private func categoryBinding(_ cat: CategoryResult) -> Binding<Bool> {
        let urls = Set(cat.items.map(\.url))
        return Binding(get: { !urls.isEmpty && urls.isSubset(of: scanner.selected) },
                       set: { if $0 { scanner.selected.formUnion(urls) } else { scanner.selected.subtract(urls) } })
    }
}
