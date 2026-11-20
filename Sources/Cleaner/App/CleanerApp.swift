import SwiftUI
import AppKit

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--scan") {
            CLI.dryRunScan()
            exit(0)
        }
        CleanerApp.main()
    }
}

/// `Cleaner --scan` prints what Smart Scan would find. Read-only: never deletes anything.
enum CLI {
    static func dryRunScan() {
        let start = Date()
        let installed = AppCatalog.installedBundleIDs()
        let excluded = SafetyGuard.excludedPaths
        var results = CleanupRules.all.compactMap {
            RuleEvaluator.evaluate($0, installedBundleIDs: installed, excluded: excluded)
        }
        let claimed = Set(results.filter { !$0.rule.catchAll }.flatMap { $0.items.map(\.url) })
        results = results.map { r in
            guard r.rule.catchAll else { return r }
            var c = r
            c.items.removeAll { claimed.contains($0.url) }
            return c
        }.filter { !$0.items.isEmpty }

        print("Cleaner dry-run scan — Full Disk Access: \(FullDiskAccess.isGranted ? "yes" : "no")")
        print("Disk: \(Fmt.bytes(DiskInfo.current().used)) used / \(Fmt.bytes(DiskInfo.current().total))\n")
        var total: Int64 = 0
        for r in results {
            total += r.total
            let title = r.rule.title.padding(toLength: 34, withPad: " ", startingAt: 0)
            print("\(title) \(Fmt.bytes(r.total).padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.items.count) items  [\(r.rule.safety.label)]")
            for i in r.items.prefix(3) { print("    \(Fmt.bytes(i.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(i.url.displayPath)") }
        }
        print("\nTotal found: \(Fmt.bytes(total)) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
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
