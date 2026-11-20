import Foundation
import AppKit

// MARK: - Formatting

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, b), countStyle: .file)
    }

    static func relative(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Paths

enum Paths {
    static let home: URL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

    static func expand(_ p: String) -> URL {
        URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// Path with the home folder replaced by `~` (also hides the username from AI prompts).
    static func display(_ url: URL) -> String {
        let p = url.path, h = home.path
        if p == h { return "~" }
        if p.hasPrefix(h + "/") { return "~" + String(p.dropFirst(h.count)) }
        return p
    }

    static func children(of url: URL) -> [URL] {
        let ignore: Set<String> = [".DS_Store", ".localized"]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
            options: []
        )) ?? []
        return items.filter { !ignore.contains($0.lastPathComponent) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isSymbolicLink != true
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

extension URL {
    var displayPath: String { Paths.display(self) }
    func revealInFinder() { NSWorkspace.shared.activateFileViewerSelecting([self]) }
}

// MARK: - Disk usage

enum FileSizer {
    /// Never descend into these while sizing (other volumes, firmlink mirrors, device files).
    static let skipPaths: Set<String> = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home"]

    private static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]
    private static let keySet = Set(keys)

    /// Allocated size on disk of a file or a whole folder tree. Honors task cancellation.
    static func size(of url: URL) -> Int64 {
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isDirectory != true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        if skipPaths.contains(url.path) { return 0 }

        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        var n = 0
        while let item = e.nextObject() as? URL {
            n += 1
            if n % 1024 == 0, Task.isCancelled { break }
            if skipPaths.contains(item.path) { e.skipDescendants(); continue }
            guard let rv = try? item.resourceValues(forKeys: keySet) else { continue }
            if rv.isRegularFile == true {
                total += Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - Shell

enum Shell {
    struct Result {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
    }

    static func run(_ path: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch {
            return Result(status: -1, out: "", err: error.localizedDescription)
        }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(
            status: p.terminationStatus,
            out: String(decoding: od, as: UTF8.self),
            err: String(decoding: ed, as: UTF8.self)
        )
    }

    static func sh(_ command: String) -> Result { run("/bin/sh", ["-c", command]) }

    /// Runs a fixed command with the standard macOS administrator password prompt.
    static func runAdmin(_ command: String) -> Result {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }
}
