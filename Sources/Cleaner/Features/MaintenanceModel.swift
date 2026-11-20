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

/// Memory of one app including all of its helper processes (renderers, GPU, plugins…).
struct AppMemory: Identifiable {
    let id: String
    let name: String
    let memory: Int64
    let processes: Int
    let bundlePath: String?

    var runningApps: [NSRunningApplication] {
        guard let bundlePath else { return [] }
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.path == bundlePath && $0.activationPolicy == .regular
        }
    }
}

struct MountedImage: Identifiable {
    let imagePath: String
    let mountPoints: [String]
    var id: String { imagePath }
    var name: String { URL(fileURLWithPath: imagePath).lastPathComponent }
}

struct SystemDataItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let path: String
    /// True when macOS manages it and Cleaner should not delete it.
    let managedByMacOS: Bool
    var size: Int64?
}

struct Insight: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let severity: Safety
}

@MainActor
final class MaintenanceModel: ObservableObject {
    @Published private(set) var runningTask: String?
    @Published private(set) var output: [String] = []
    @Published private(set) var snapshots: [String] = []
    @Published private(set) var appMemory: [AppMemory] = []
    @Published private(set) var images: [MountedImage] = []
    @Published private(set) var systemData: [SystemDataItem] = []
    @Published private(set) var insights: [Insight] = []
    @Published private(set) var isCheckingHealth = false

    static let tasks: [MaintenanceTask] = [
        MaintenanceTask(id: "purge", title: "Flush File Cache (RAM)",
                        detail: "Runs macOS's `purge` to drop cached files from memory. Gives temporary relief only — macOS refills the cache because it makes your Mac faster. Quitting heavy apps helps far more.",
                        icon: "memorychip", command: "/usr/sbin/purge", admin: true),
        MaintenanceTask(id: "thin", title: "Thin Time Machine Snapshots",
                        detail: "Reclaims purgeable space held by local APFS snapshots — often a big part of “System Data”.",
                        icon: "clock.arrow.circlepath", command: "/usr/bin/tmutil thinlocalsnapshots / 999999999999 4", admin: true),
        MaintenanceTask(id: "dns", title: "Flush DNS Cache",
                        detail: "Fixes websites that fail to load after network or DNS changes.",
                        icon: "network", command: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder", admin: true),
        MaintenanceTask(id: "spotlight", title: "Rebuild Spotlight Index",
                        detail: "Fixes broken search results or a runaway Spotlight index. Re-indexing runs in the background and can take an hour.",
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

    private static let systemDataSpecs: [SystemDataItem] = [
        SystemDataItem(id: "vm", title: "Swap & sleep image",
                       detail: "Virtual memory written to disk plus the hibernation image. Managed by macOS — it shrinks when memory pressure drops or after a restart.",
                       path: "/private/var/vm", managedByMacOS: true),
        SystemDataItem(id: "logs", title: "Unified system logs",
                       detail: "macOS's own diagnostic log store. Rotated automatically; deleting it needs root and breaks troubleshooting.",
                       path: "/private/var/db/diagnostics", managedByMacOS: true),
        SystemDataItem(id: "uuidtext", title: "Log symbol data",
                       detail: "Supporting data for the system logs. Rotated with them.",
                       path: "/private/var/db/uuidtext", managedByMacOS: true),
        SystemDataItem(id: "folders", title: "Temporary & cache folders",
                       detail: "Per-user caches and temp files in /var/folders. Your part is cleaned by Smart Scan (Hidden macOS App Caches).",
                       path: "/private/var/folders", managedByMacOS: false),
        SystemDataItem(id: "appsupport", title: "App data (Application Support)",
                       detail: "Data apps keep for you. Smart Scan cleans the caches inside it; explore the rest with Space Lens.",
                       path: "~/Library/Application Support", managedByMacOS: false),
        SystemDataItem(id: "caches", title: "App caches",
                       detail: "Cleaned by Smart Scan.",
                       path: "~/Library/Caches", managedByMacOS: false),
        SystemDataItem(id: "devtools", title: "Developer tools",
                       detail: "Command Line Tools / SDKs. Needed for coding.",
                       path: "/Library/Developer", managedByMacOS: true),
    ]

    // MARK: Tasks

    func run(_ t: MaintenanceTask) {
        guard runningTask == nil else { return }
        runningTask = t.id
        Task {
            let r = await Task.detached { t.admin ? Shell.runAdmin(t.command) : Shell.sh(t.command) }.value
            log(r.ok ? "✓ \(t.title) finished." : "✗ \(t.title) failed: \(Self.errorText(r))")
            runningTask = nil
            if t.id == "thin" { loadSnapshots() }
            if t.id == "purge" { loadProcesses() }
        }
    }

    private func log(_ line: String) {
        output.insert("[\(Date().formatted(date: .omitted, time: .shortened))] \(line)", at: 0)
    }

    private static func errorText(_ r: Shell.Result) -> String {
        let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        if err.contains("-128") { return "cancelled" }
        return err.isEmpty ? "exit \(r.status)" : err
    }

    // MARK: Snapshots

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

    // MARK: Memory by app

    func loadProcesses() {
        Task {
            let r = await Task.detached { Shell.run("/bin/ps", ["-axo", "pid=,rss=,comm="]) }.value
            appMemory = Self.groupByApp(r.out)
        }
    }

    nonisolated static func groupByApp(_ psOutput: String) -> [AppMemory] {
        var totals: [String: (name: String, mem: Int64, count: Int, bundle: String?)] = [:]
        for line in psOutput.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let rss = Int64(parts[1]) else { continue }
            let comm = String(parts[2])
            let key: String, name: String, bundle: String?
            if let r = comm.range(of: ".app/") {
                bundle = String(comm[..<r.lowerBound]) + ".app"
                key = bundle!
                name = URL(fileURLWithPath: bundle!).deletingPathExtension().lastPathComponent
            } else {
                bundle = nil
                name = URL(fileURLWithPath: comm).lastPathComponent
                key = name
            }
            var e = totals[key] ?? (name, 0, 0, bundle)
            e.mem += rss * 1024
            e.count += 1
            totals[key] = e
        }
        return totals.map { AppMemory(id: $0.key, name: $0.value.name, memory: $0.value.mem,
                                      processes: $0.value.count, bundlePath: $0.value.bundle) }
            .sorted { $0.memory > $1.memory }
            .prefix(12)
            .map { $0 }
    }

    func quit(_ app: AppMemory) {
        app.runningApps.forEach { $0.terminate() }
        Task {
            try? await Task.sleep(for: .seconds(2))
            loadProcesses()
        }
    }

    // MARK: Mounted disk images

    func loadImages() {
        Task {
            let r = await Task.detached { Shell.run("/usr/bin/hdiutil", ["info", "-plist"]) }.value
            guard let plist = try? PropertyListSerialization.propertyList(from: Data(r.out.utf8), format: nil) as? [String: Any],
                  let list = plist["images"] as? [[String: Any]] else { images = []; return }
            images = list.compactMap { img in
                guard let path = img["image-path"] as? String else { return nil }
                let mounts = (img["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
                return mounts.isEmpty ? nil : MountedImage(imagePath: path, mountPoints: mounts)
            }
        }
    }

    func eject(_ image: MountedImage, moveToTrash: Bool) {
        Task {
            var ok = true
            for mp in image.mountPoints {
                let r = await Task.detached { Shell.run("/usr/bin/hdiutil", ["detach", mp]) }.value
                if !r.ok { ok = false; log("✗ Couldn't eject \(mp): \(Self.errorText(r))") }
            }
            if ok {
                log("✓ Ejected \(image.name).")
                if moveToTrash {
                    let url = URL(fileURLWithPath: image.imagePath)
                    let target = CleanTarget(url: url, size: FileSizer.size(of: url))
                    let report = await Task.detached { Cleaner.remove([target]) }.value
                    log(report.removed.isEmpty ? "✗ Couldn't trash \(image.name): \(report.failures.first?.reason ?? "")"
                                               : "✓ Moved \(image.name) to the Trash.")
                }
            }
            loadImages()
        }
    }

    // MARK: System Data breakdown

    func loadSystemData() {
        guard systemData.isEmpty || systemData.allSatisfy({ $0.size != nil }) else { return }
        systemData = Self.systemDataSpecs
        Task {
            for item in Self.systemDataSpecs {
                let url = Paths.expand(item.path)
                let size = await Task.detached(priority: .utility) { FileSizer.size(of: url) }.value
                if let i = systemData.firstIndex(where: { $0.id == item.id }) { systemData[i].size = size }
            }
        }
    }

    // MARK: Health checks

    func checkHealth(memory: MemoryInfo) {
        guard !isCheckingHealth else { return }
        isCheckingHealth = true
        Task {
            async let ps = Task.detached { Shell.run("/bin/ps", ["-axo", "pid=,rss=,comm="]) }.value
            async let backlog = Task.detached { Self.syncUploadBacklog() }.value
            let apps = Self.groupByApp(await ps.out)
            appMemory = apps
            loadImages()
            var found: [Insight] = []

            if memory.pressureLevel >= 2 {
                let top = apps.prefix(3).map { "\($0.name) \(Fmt.bytes($0.memory))" }.joined(separator: ", ")
                found.append(Insight(id: "pressure", icon: "gauge.with.dots.needle.67percent",
                                     title: "Memory pressure is \(memory.pressureLabel.lowercased())",
                                     detail: "\(Fmt.bytes(memory.compressed)) is compressed and \(Fmt.bytes(memory.swapUsed)) swapped to disk. Biggest users: \(top). Quitting one of them helps more than any “RAM cleaner”.",
                                     severity: memory.pressureLevel >= 4 ? .caution : .review))
            } else if memory.swapUsed > 2_000_000_000 {
                found.append(Insight(id: "swap", icon: "arrow.left.arrow.right",
                                     title: "\(Fmt.bytes(memory.swapUsed)) of memory is swapped to disk",
                                     detail: "Swap stays allocated after a busy period. It's harmless, and a restart clears it.",
                                     severity: .review))
            }

            let browserNames: Set<String> = ["Google Chrome", "Brave Browser", "Safari", "Microsoft Edge", "Firefox", "Arc", "Opera", "Vivaldi"]
            let browsers = apps.filter { browserNames.contains($0.name) }
            if browsers.count >= 2 {
                let total = browsers.reduce(0) { $0 + $1.memory }
                found.append(Insight(id: "browsers", icon: "safari",
                                     title: "\(browsers.count) browsers are open (\(Fmt.bytes(total)))",
                                     detail: "\(browsers.map(\.name).joined(separator: " and ")) each run their own engine. Using one browser at a time frees that memory.",
                                     severity: .review))
            }

            for b in await backlog where b.files > 5000 {
                found.append(Insight(id: "sync-\(b.folder)", icon: "icloud.and.arrow.up",
                                     title: "Cloud sync is uploading \(b.files.formatted()) files from \(Paths.display(URL(fileURLWithPath: b.folder)))",
                                     detail: "Google Drive is backing up this folder, including developer folders like node_modules and .next. That costs CPU, battery, bandwidth and Drive storage. Exclude the folder in Google Drive's settings or move your projects out of it.",
                                     severity: .review))
            }

            insights = found
            isCheckingHealth = false
        }
    }

    /// Finds Google Drive upload staging folders (`.tmp.driveupload`) up to two levels below home.
    nonisolated static func syncUploadBacklog() -> [(folder: String, files: Int)] {
        var out: [(String, Int)] = []
        var candidates = [Paths.home]
        candidates += Paths.children(of: Paths.home).filter { Paths.isDirectory($0) && !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "Library" }
        for dir in candidates {
            let staging = dir.appendingPathComponent(".tmp.driveupload")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: staging.path) else { continue }
            out.append((dir.path, names.count))
        }
        return out
    }
}
