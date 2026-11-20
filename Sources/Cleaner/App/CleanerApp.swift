import SwiftUI
import AppKit

@main
enum Entry {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--scan") { CLI.dryRunScan(); exit(0) }
        if args.contains("--dupes") { CLI.dupes(); exit(0) }
        if args.contains("--health") { CLI.health(); exit(0) }
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
