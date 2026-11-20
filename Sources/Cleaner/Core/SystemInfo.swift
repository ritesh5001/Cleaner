import Foundation
import AppKit
import Darwin

struct DiskInfo {
    var total: Int64 = 0
    /// Truly free right now.
    var free: Int64 = 0
    /// What Finder reports as "available" (free + purgeable that macOS can reclaim).
    var availableIncludingPurgeable: Int64 = 0

    var used: Int64 { max(0, total - availableIncludingPurgeable) }
    var purgeable: Int64 { max(0, availableIncludingPurgeable - free) }

    static func current() -> DiskInfo {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return DiskInfo() }
        var d = DiskInfo()
        d.total = Int64(v.volumeTotalCapacity ?? 0)
        d.free = Int64(v.volumeAvailableCapacity ?? 0)
        d.availableIncludingPurgeable = max(d.free, v.volumeAvailableCapacityForImportantUsage ?? d.free)
        return d
    }

    func fraction(_ v: Int64) -> Double { total > 0 ? Double(v) / Double(total) : 0 }
}

struct MemoryInfo {
    var total = Int64(ProcessInfo.processInfo.physicalMemory)
    var app: Int64 = 0
    var wired: Int64 = 0
    var compressed: Int64 = 0
    var cached: Int64 = 0
    var free: Int64 = 0

    var used: Int64 { app + wired + compressed }
    func fraction(_ v: Int64) -> Double { total > 0 ? min(1, Double(v) / Double(total)) : 0 }

    static func current() -> MemoryInfo {
        var info = MemoryInfo()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return info }
        let page = Int64(getpagesize())
        info.app = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * page
        info.wired = Int64(stats.wire_count) * page
        info.compressed = Int64(stats.compressor_page_count) * page
        info.cached = (Int64(stats.external_page_count) + Int64(stats.purgeable_count)) * page
        info.free = Int64(stats.free_count) * page
        return info
    }
}

enum MacInfo {
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

enum FullDiskAccess {
    /// The TCC database is only readable by processes that have Full Disk Access.
    static var isGranted: Bool {
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let h = FileHandle(forReadingAtPath: probe) else { return false }
        try? h.close()
        return true
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
