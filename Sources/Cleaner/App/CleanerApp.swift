import SwiftUI
import AppKit

@main
enum Entry {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--scan") { CLI.dryRunScan(); exit(0) }
        if args.contains("--dupes") { CLI.dupes(); exit(0) }
        if args.contains("--health") { CLI.health(); exit(0) }
        if args.contains("--apps") { CLI.apps(); exit(0) }
        if let i = args.firstIndex(of: "--agent"), i + 1 < args.count {
            // Dry run: shows the plan the Cleanup Agent proposes. Never executes it.
            let request = args[i + 1]
            Task { @MainActor in
                let state = AppState()
                state.agent.input = request
                state.agent.send(state: state)
                while state.agent.isWorking { try? await Task.sleep(for: .milliseconds(500)) }
                for t in state.agent.turns {
                    print("\(t.role == .user ? "YOU" : "AGENT"): \(t.text)")
                    if let p = t.plan {
                        for a in p.actions {
                            print("  [\(a.selected ? "x" : " ")] \(Fmt.bytes(a.candidate.size).padding(toLength: 9, withPad: " ", startingAt: 0)) \(a.risk.label.padding(toLength: 8, withPad: " ", startingAt: 0)) \(a.candidate.url.displayPath) — \(a.reason)")
                        }
                        if !p.tasks.isEmpty { print("  tasks: \(p.tasks.joined(separator: ", "))") }
                        print("  → would clean \(Fmt.bytes(p.selectedSize)) (DRY RUN — nothing executed)")
                    }
                }
                exit(0)
            }
            dispatchMain()
        }
        if args.contains("--explain-test") {
            Task { @MainActor in
                AppOwnerResolver.shared.reload()
                let paths = ["~/Library/Application Support/Code", "~/.vscode", "~/Library/HTTPStorages/com.microsoft.VSCode",
                             "~/Library/Application Support/Claude/vm_bundles"]
                let items = paths.map(Paths.expand).map { u -> (url: URL, kind: String, size: Int64?, owner: AppOwner?) in
                    (u, u.path.contains("/.vscode") ? "Tool folder" : u.path.contains("HTTPStorages") ? "Web storage" : "App data",
                     SizeIndex.shared.measure(u), AppOwnerResolver.shared.owner(for: u))
                }
                do {
                    let n = try await DataExplainer.explainWithAI(items)
                    print("AI explained \(n):")
                    for i in items {
                        let e = DataExplainer.explanation(for: i.url, kind: i.kind, owner: i.owner)
                        print("\n\(i.url.displayPath) [\(e.verdictLabel)\(e.fromAI ? ", AI" : "")]\n  What: \(e.what)\n  Used for: \(e.usedFor)\n  If deleted: \(e.ifDeleted)")
                    }
                } catch { print("ERROR:", error.localizedDescription) }
                exit(0)
            }
            dispatchMain()
        }
        if args.contains("--identify") {
            // Live test of "Identify with AI" on cache/tool folders Cleaner couldn't attribute.
            Task { @MainActor in
                let r = AppOwnerResolver.shared
                r.reload()
                let candidates = Paths.children(of: Paths.expand("~/Library/Caches"))
                    + Paths.children(of: Paths.home).filter { $0.lastPathComponent.hasPrefix(".") && Paths.isDirectory($0) }
                let unknown = candidates.filter { let o = r.owner(for: $0); return o == nil || o?.source == .name }
                print("Asking \(AISettings.shared.activeProvider.shortName) about \(unknown.count) unidentified items…")
                do {
                    let n = try await r.identifyWithAI(unknown.map { ($0, nil) })
                    print("AI identified \(n):")
                    for u in unknown {
                        let o = r.owner(for: u)
                        print("  \(u.lastPathComponent.padding(toLength: 26, withPad: " ", startingAt: 0)) → \(o?.name ?? "?")\(o?.note.map { " — \($0)" } ?? "")")
                    }
                } catch { print("ERROR:", error.localizedDescription) }
                exit(0)
            }
            dispatchMain()
        }
        if let i = args.firstIndex(of: "--organize-selftest"), i + 1 < args.count {
            CLI.organizerSelfTest(URL(fileURLWithPath: args[i + 1])); exit(0)
        }
        if let i = args.firstIndex(of: "--organize-preview"), i + 1 < args.count {
            CLI.organizePreview(URL(fileURLWithPath: args[i + 1])); exit(0)
        }
        if let i = args.firstIndex(of: "--explore"), i + 1 < args.count {
            CLI.explore(URL(fileURLWithPath: args[i + 1])); exit(0)
        }
        if let i = args.firstIndex(of: "--ask"), i + 1 < args.count {
            // `Cleaner --ask "question"` — tests the Claude-subscription bridge (Claude Code CLI).
            let question = args[i + 1]
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                guard let path = CLILocator.detect("claude") else { print("claude CLI not found"); sem.signal(); return }
                print("Using Claude Code at \(path)…")
                do {
                    let answer = try await ClaudeCodeClient(binary: path).complete(
                        system: Prompts.system, messages: [ChatMessage(role: .user, text: question)], model: "sonnet", maxTokens: 1000)
                    print(answer)
                } catch { print("ERROR:", error.localizedDescription) }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        CleanerApp.main()
    }
}

/// `Cleaner --scan` prints what Smart Scan would find. Read-only: never deletes anything.
enum CLI {
    @MainActor
    static func dryRunScan() {
        let start = Date()
        let context = ScanContext.current()
        var results = CleanupRules.all.compactMap { RuleEvaluator.evaluate($0, context: context) }
        let claimed = Set(results.filter { !$0.rule.catchAll }.flatMap { $0.items.map(\.url) })
        results = results.map { r in
            guard r.rule.catchAll else { return r }
            var c = r
            c.items.removeAll { claimed.contains($0.url) }
            return c
        }.filter { !$0.isEmpty }

        print("Cleaner dry-run scan — Full Disk Access: \(FullDiskAccess.isGranted ? "yes" : "no")")
        print("Disk: \(Fmt.bytes(DiskInfo.current().used)) used / \(Fmt.bytes(DiskInfo.current().total))\n")
        var total: Int64 = 0
        for r in results {
            total += r.total
            let title = r.rule.title.padding(toLength: 34, withPad: " ", startingAt: 0)
            print("\(title) \(Fmt.bytes(r.total).padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.items.count) items  [\(r.rule.safety.label)]")
            for i in r.items.prefix(3) { print("    \(Fmt.bytes(i.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(i.url.displayPath)") }
            if r.heldTotal > 0 { print("    + \(Fmt.bytes(r.heldTotal)) held by running apps: \(r.holdingApps.joined(separator: ", "))") }
        }
        print("\nTotal found: \(Fmt.bytes(total)) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    }

    /// `Cleaner --apps`: who owns each cache folder, and the biggest apps by total footprint (read-only).
    static func apps() {
        let r = AppOwnerResolver.shared
        r.reload()
        print("Owners of ~/Library/Caches folders:")
        for u in Paths.children(of: Paths.expand("~/Library/Caches")).prefix(40) {
            let o = r.owner(for: u)
            print("  \(u.lastPathComponent.padding(toLength: 44, withPad: " ", startingAt: 0)) → \(o.map { "\($0.name) [\($0.source.rawValue)]" } ?? "?")")
        }
        let start = Date()
        var groups = AppStorageModel.collect().0
        for i in groups.indices {
            groups[i].appSize = groups[i].appBundle.map { SizeIndex.shared.measure($0) }
            for j in groups[i].items.indices {
                let u = groups[i].items[j].url
                groups[i].items[j].size = Paths.isDirectory(u) ? SizeIndex.shared.measure(u) : FileSizer.size(of: u)
            }
        }
        groups.sort { $0.total > $1.total }
        let unknown = groups.filter { $0.kind == .unknown }
        print("\nTop apps & tools by total storage (\(String(format: "%.0f", Date().timeIntervalSince(start)))s):")
        for g in groups.prefix(20) {
            print("  \(Fmt.bytes(g.total).padding(toLength: 10, withPad: " ", startingAt: 0)) \(g.owner.name.padding(toLength: 34, withPad: " ", startingAt: 0)) app \(Fmt.bytes(g.appSize ?? 0)), data \(Fmt.bytes(g.dataSize)) in \(g.items.count) places [\(g.kind.rawValue)]")
        }
        print("\nUnidentified: \(unknown.count) items, \(Fmt.bytes(unknown.reduce(0) { $0 + $1.total })) — e.g. \(unknown.sorted { $0.total > $1.total }.prefix(6).map { "\($0.owner.name) \(Fmt.bytes($0.total))" }.joined(separator: ", "))")
    }

    /// `Cleaner --organize-preview <dir>`: read-only "by type" plan.
    static func organizePreview(_ dir: URL) {
        let files = OrganizerModel.candidates(in: dir)
        let groups = Dictionary(grouping: files) { OrganizerModel.typeFolder(for: $0.url) }
        print("\(files.count) loose files in \(dir.displayPath) would go into \(groups.count) folders:")
        for (k, v) in groups.sorted(by: { $0.value.count > $1.value.count }) {
            print("  \(k.padding(toLength: 14, withPad: " ", startingAt: 0)) \(v.count) files, \(Fmt.bytes(v.reduce(0) { $0 + $1.size }))")
        }
    }

    /// `Cleaner --organize-selftest <empty dir>`: creates dummy files, organizes them, undoes, verifies.
    static func organizerSelfTest(_ dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ["photo.jpg", "invoice.pdf", "notes.md", "setup.dmg", "clip.mov", "data.csv", "photo (2).jpg", "noext"]
        for n in names { fm.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data(n.utf8), attributes: [.modificationDate: Date().addingTimeInterval(-3600)]) }
        try? fm.createDirectory(at: dir.appendingPathComponent("ExistingFolder"), withIntermediateDirectories: true)
        // A pre-existing Images/photo.jpg forces a name conflict.
        try? fm.createDirectory(at: dir.appendingPathComponent("Images"), withIntermediateDirectories: true)
        fm.createFile(atPath: dir.appendingPathComponent("Images/photo.jpg").path, contents: Data("old".utf8))

        let before = Set(try! fm.contentsOfDirectory(atPath: dir.path))
        let moves = OrganizerModel.candidates(in: dir).map { PlannedMove(source: $0.url, folder: OrganizerModel.typeFolder(for: $0.url), size: $0.size) }
        let (done, failed) = OrganizerModel.perform(moves, base: dir)
        print("Moved \(done.count), failed \(failed.count)")
        for r in done { print("  \(URL(fileURLWithPath: r.from).lastPathComponent) → \(r.to.replacingOccurrences(of: dir.path + "/", with: ""))") }
        let restored = OrganizerModel.restore(done)
        let after = Set(try! fm.contentsOfDirectory(atPath: dir.path))
        let oldPhotoIntact = (try? String(contentsOfFile: dir.appendingPathComponent("Images/photo.jpg").path, encoding: .utf8)) == "old"
        print("Restored \(restored). Folder identical to before: \(before == after). Pre-existing Images/photo.jpg untouched: \(oldPhotoIntact)")
        print(before == after && oldPhotoIntact && failed.isEmpty ? "SELFTEST PASS" : "SELFTEST FAIL  before=\(before.sorted()) after=\(after.sorted())")
    }

    /// `Cleaner --explore <dir>`: measures a folder like the Storage Explorer and prints its biggest children.
    static func explore(_ dir: URL) {
        let start = Date()
        let kids = Paths.children(of: dir).sorted { !$0.lastPathComponent.hasPrefix(".") && $1.lastPathComponent.hasPrefix(".") }.map { ($0, Paths.isDirectory($0) ? SizeIndex.shared.measure($0) : FileSizer.size(of: $0)) }
            .sorted { $0.1 > $1.1 }
        let total = kids.reduce(Int64(0)) { $0 + $1.1 }
        print("\(dir.displayPath): \(Fmt.bytes(total)) (\(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
        for (u, s) in kids.prefix(10) {
            print("  \(Fmt.bytes(s).padding(toLength: 10, withPad: " ", startingAt: 0)) \(String(format: "%5.1f%%", total > 0 ? Double(s) * 100 / Double(total) : 0))  \(u.lastPathComponent)")
        }
        // Drilling into the biggest child should now be instant thanks to the size index.
        if let big = kids.first?.0, Paths.isDirectory(big) {
            let t = Date()
            let sub = Paths.children(of: big).map { ($0, SizeIndex.shared.measure($0)) }.sorted { $0.1 > $1.1 }
            print("Drill into \(big.lastPathComponent): \(String(format: "%.2f", Date().timeIntervalSince(t)))s (cached) — top: \(sub.prefix(3).map { "\($0.0.lastPathComponent) \(Fmt.bytes($0.1))" }.joined(separator: ", "))")
        }
    }

    /// `Cleaner --dupes`: read-only duplicate report for Downloads/Desktop/Documents/Pictures.
    static func dupes() {
        let start = Date()
        let roots = ["Downloads", "Desktop", "Documents", "Pictures"].map { Paths.home.appendingPathComponent($0) }
        let groups = DuplicateSearch.find(roots: roots, minBytes: 100_000, excluded: SafetyGuard.excludedPaths) { _ in }
        print("Duplicate groups: \(groups.count), reclaimable: \(Fmt.bytes(groups.reduce(0) { $0 + $1.wasted }))")
        for g in groups.prefix(8) {
            print("  \(g.files.count) × \(Fmt.bytes(g.size))")
            for f in g.files { print("     \(f.url.displayPath)") }
        }
        print(String(format: "Done in %.1fs", Date().timeIntervalSince(start)))
    }

    /// `Cleaner --health`: memory by app, memory pressure, sync backlog, mounted images, System Data sizes.
    static func health() {
        let m = MemoryInfo.current()
        print("Memory: \(Fmt.bytes(m.used)) used of \(Fmt.bytes(m.total)) · pressure \(m.pressureLabel) · compressed \(Fmt.bytes(m.compressed)) · file cache \(Fmt.bytes(m.cached)) · swap \(Fmt.bytes(m.swapUsed))")
        let ps = Shell.run("/bin/ps", ["-axo", "pid=,rss=,comm="])
        for a in MaintenanceModel.groupByApp(ps.out).prefix(8) {
            print("  \(Fmt.bytes(a.memory).padding(toLength: 10, withPad: " ", startingAt: 0)) \(a.name) (\(a.processes) processes)")
        }
        print("\nCloud-sync upload backlogs:")
        for b in MaintenanceModel.syncUploadBacklog() { print("  \(b.files) files waiting in \(Paths.display(URL(fileURLWithPath: b.folder)))") }
        print("\nMounted disk images:")
        print(Shell.run("/usr/bin/hdiutil", ["info"]).out.split(separator: "\n").filter { $0.hasPrefix("image-path") }.joined(separator: "\n"))
        print("\nSystem Data areas:")
        for p in ["/private/var/vm", "/private/var/db/diagnostics", "/private/var/db/uuidtext", "/private/var/folders", "/Library/Developer"] {
            print("  \(Fmt.bytes(FileSizer.size(of: URL(fileURLWithPath: p))).padding(toLength: 10, withPad: " ", startingAt: 0)) \(p)")
        }
    }
}

struct CleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var ai = AISettings.shared

    var body: some Scene {
        Window("Cleaner", id: "main") {
            RootView()
                .environmentObject(state)
                .environmentObject(ai)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Clean") {
                Button("Smart Scan") {
                    state.selection = .smartScan
                    state.junk.scan()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(ai)
                .frame(width: 680, height: 640)
        }

        MenuBarExtra("Cleaner", systemImage: "sparkles") {
            MenuBarView()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run); harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
