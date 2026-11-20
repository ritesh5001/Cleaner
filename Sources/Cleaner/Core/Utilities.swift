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

    /// This user's private macOS cache/temp folders inside /var/folders (no trailing slash).
    static let darwinCacheDir = confstrPath(_CS_DARWIN_USER_CACHE_DIR)
    static let darwinTempDir = confstrPath(_CS_DARWIN_USER_TEMP_DIR)

    private static func confstrPath(_ name: Int32) -> String {
        let len = confstr(name, nil, 0)
        guard len > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: len)
        confstr(name, &buf, len)
        var s = String(cString: buf)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Expands `~`, `$DARWIN_CACHE` and `$DARWIN_TEMP`.
    static func expand(_ p: String) -> URL {
        var s = p
        if s.hasPrefix("$DARWIN_CACHE") { s = darwinCacheDir + s.dropFirst("$DARWIN_CACHE".count) }
        if s.hasPrefix("$DARWIN_TEMP") { s = darwinTempDir + s.dropFirst("$DARWIN_TEMP".count) }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath).standardizedFileURL
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

// MARK: - Directory walking

/// Robust recursive directory walker.
///
/// `FileManager.DirectoryEnumerator` was observed to silently end an *entire* walk when it reached one
/// pathological folder (Google Drive's `.tmp.driveupload` with 180k entries) — no error callback.
/// This walker lists every directory independently, so a bad folder only affects itself.
enum DirWalker {
    enum Action { case descend, skip }

    private static let baseKeys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]

    /// Calls `visit(url, level, values)` for everything below `root` (level 1 = direct children).
    /// Return `.descend` to enter a directory, `.skip` to ignore its contents. Symlinks are never followed.
    static func walk(_ root: URL, keys: [URLResourceKey] = [],
                     visit: (URL, Int, URLResourceValues) -> Action) {
        let allKeys = Array(Set(baseKeys + keys))
        let keySet = Set(allKeys)
        let fm = FileManager.default
        var stack: [(URL, Int)] = [(root, 0)]
        var listed = 0
        while let (dir, level) = stack.popLast() {
            listed += 1
            if listed % 64 == 0, Task.isCancelled { return }
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: allKeys, options: []) else { continue }
            for child in children {
                guard let v = try? child.resourceValues(forKeys: keySet) else { continue }
                let action = visit(child, level + 1, v)
                if action == .descend, v.isDirectory == true, v.isSymbolicLink != true {
                    stack.append((child, level + 1))
                }
            }
        }
    }
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

        var total: Int64 = 0
        DirWalker.walk(url, keys: keys) { item, _, rv in
            if rv.isDirectory == true { return skipPaths.contains(item.path) ? .skip : .descend }
            if rv.isRegularFile == true {
                total += Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
            }
            return .skip
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
