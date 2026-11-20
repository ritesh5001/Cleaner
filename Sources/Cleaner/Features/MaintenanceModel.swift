import Foundation
import AppKit

struct MaintenanceTask: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let command: String
    let admin: Bool
}

struct ProcInfo: Identifiable {
    let pid: Int32
    let name: String
    let memory: Int64
    var id: Int32 { pid }
    var app: NSRunningApplication? {
        let a = NSRunningApplication(processIdentifier: pid)
        return a?.activationPolicy == .regular ? a : nil
    }
}

@MainActor
final class MaintenanceModel: ObservableObject {
    @Published private(set) var runningTask: String?
    @Published private(set) var output: [String] = []
    @Published private(set) var snapshots: [String] = []
    @Published private(set) var processes: [ProcInfo] = []

    static let tasks: [MaintenanceTask] = [
        MaintenanceTask(id: "purge", title: "Free Up Memory",
                        detail: "Flushes inactive memory and disk caches with macOS's `purge` tool.",
                        icon: "memorychip", command: "/usr/sbin/purge", admin: true),
        MaintenanceTask(id: "thin", title: "Thin Time Machine Snapshots",
                        detail: "Reclaims purgeable space held by local APFS snapshots — often a big part of “System Data”.",
                        icon: "clock.arrow.circlepath", command: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4", admin: true),
        MaintenanceTask(id: "dns", title: "Flush DNS Cache",
                        detail: "Fixes websites that fail to load after network or DNS changes.",
                        icon: "network", command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder", admin: true),
        MaintenanceTask(id: "spotlight", title: "Rebuild Spotlight Index",
                        detail: "Fixes broken search results. Re-indexing runs in the background and can take an hour.",
                        icon: "magnifyingglass", command: "/usr/bin/mdutil -E /", admin: true),
        MaintenanceTask(id: "launchservices", title: "Rebuild Launch Services",
                        detail: "Fixes duplicate “Open With” entries and wrong app icons.",
                        icon: "square.stack.3d.up",
                        command: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -r -domain local -domain system -domain user",
                        admin: false),
        MaintenanceTask(id: "quicklook", title: "Reset Quick Look",
                        detail: "Clears the Quick Look thumbnail cache when previews look wrong.",
                        icon: "eye", command: "/usr/bin/qlmanage -r; /usr/bin/qlmanage -r cache", admin: false),
    ]

    func run(_ t: MaintenanceTask) {
        guard runningTask == nil else { return }
        runningTask = t.id
        Task {
            let r = await Task.detached { t.admin ? Shell.runAdmin(t.command) : Shell.sh(t.command) }.value
            let time = Date().formatted(date: .omitted, time: .shortened)
            if r.ok {
                output.insert("[\(time)] ✓ \(t.title) finished.", at: 0)
            } else {
                let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                output.insert("[\(time)] ✗ \(t.title) failed: \(err.isEmpty ? "exit \(r.status)" : err)", at: 0)
            }
            runningTask = nil
            if t.id == "thin" { loadSnapshots() }
            if t.id == "purge" { loadProcesses() }
        }
    }

    func loadSnapshots() {
        Task {
            let r = await Task.detached { Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) }.value
            snapshots = r.out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("com.apple.") }
        }
    }

    func deleteSnapshot(_ name: String) {
        // com.apple.TimeMachine.2026-11-20-101010.local -> 2026-11-20-101010
        let parts = name.split(separator: ".")
        guard parts.count >= 4 else { return }
        let date = String(parts[3])
        guard !date.isEmpty, date.allSatisfy({ $0.isNumber || $0 == "-" }) else { return }
        run(MaintenanceTask(id: "thin", title: "Delete snapshot \(date)", detail: "", icon: "",
                            command: "/usr/bin/tmutil deletelocalsnapshots \(date)", admin: true))
    }

    func loadProcesses() {
        Task {
            let r = await Task.detached { Shell.run("/bin/ps", ["-axm", "-o", "pid=,rss=,comm="]) }.value
            processes = r.out.split(separator: "\n").prefix(15).compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3, let pid = Int32(parts[0]), let rss = Int64(parts[1]) else { return nil }
                let name = URL(fileURLWithPath: String(parts[2])).lastPathComponent
                return ProcInfo(pid: pid, name: name, memory: rss * 1024)
            }
        }
    }

    func quit(_ p: ProcInfo) {
        p.app?.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            loadProcesses()
        }
    }
}
