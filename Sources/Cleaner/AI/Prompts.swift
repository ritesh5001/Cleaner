import Foundation

/// Everything sent to an AI provider is built here so it's easy to audit.
/// Only metadata is shared (paths with ~ for home, sizes, dates) — never file contents.
enum Prompts {
    static let system = """
    You are the built-in assistant of "Cleaner", a macOS storage and performance utility. \
    The user wants to free disk space and keep their Mac fast without breaking anything.

    Rules:
    - Explain what files and folders are, which app or macOS component created them, and what happens if they are deleted.
    - When judging an item, give a verdict using exactly one of: **SAFE TO DELETE**, **REVIEW FIRST**, **KEEP**.
    - Never advise deleting anything in /System, /usr, /bin, /sbin, /private/var/db, or disabling System Integrity Protection.
    - Prefer official methods when they exist (app settings, `tmutil`, Xcode, `brew cleanup`, `npm cache clean`, etc.).
    - Paths starting with ~ are inside the user's home folder. You only see metadata (paths, sizes, dates), never file contents — don't claim otherwise.
    - Cleaner moves items to the Trash by default, so mistakes are recoverable until the Trash is emptied.
    - Be concise and practical. Use short paragraphs, bullet points and Markdown bold for key facts.
    """

    static func explain(url: URL, size: Int64?, category: String?, includeListing: Bool) -> String {
        let isDir = Paths.isDirectory(url)
        let ext = url.pathExtension
        var s = "Explain this item on my Mac and tell me whether I can delete it.\n\n"
        s += "- Path: `\(url.displayPath)`\n"
        if let size { s += "- Size on disk: \(Fmt.bytes(size))\n" }
        s += "- Type: \(isDir ? (ext.isEmpty ? "folder" : "package/bundle (.\(ext))") : (ext.isEmpty ? "file" : "file (.\(ext))"))\n"
        if let m = Paths.modified(url) { s += "- Last modified: \(Fmt.date(m))\n" }
        if let category { s += "- Cleaner category: \(category)\n" }
        if includeListing, isDir {
            let names = Paths.children(of: url).prefix(20).map(\.lastPathComponent)
            if !names.isEmpty { s += "- Contains (first \(names.count) names): \(names.joined(separator: ", "))\n" }
        }
        s += "\nAnswer with: what it is, what created it, what happens if it's deleted, and your verdict."
        return s
    }

    static func reviewScan(_ results: [CategoryResult], selected: Set<URL>) -> String {
        var s = """
        Here are the results of a cleanup scan on my Mac. Review them: what is safe to clean, \
        what I should look at first, and anything I should keep. Point out the biggest wins.\n\n
        """
        for r in results {
            s += "### \(r.rule.title) — \(Fmt.bytes(r.total)), \(r.items.count) items (rule rating: \(r.rule.safety.label))\n"
            for i in r.items.prefix(8) {
                s += "- `\(i.url.displayPath)` \(Fmt.bytes(i.size))\(selected.contains(i.url) ? " [selected]" : "")\n"
            }
            if r.items.count > 8 { s += "- …and \(r.items.count - 8) more\n" }
        }
        return s
    }

    static func reviewLargeFiles(_ files: [LargeFile]) -> String {
        var s = "These are the largest files on my Mac. Group them (videos, disk images, VMs, archives, app data…), say which are usually safe to remove or move to external storage, and which I should keep.\n\n"
        for f in files.prefix(40) {
            s += "- `\(f.url.displayPath)` — \(Fmt.bytes(f.size)), modified \(Fmt.date(f.modified))\n"
        }
        return s
    }

    static func app(_ app: InstalledApp, leftovers: [ScanItem]) -> String {
        var s = "Tell me about this Mac app: what it is, whether it's commonly needed, and anything to know before uninstalling it (licenses, data to export, background helpers).\n\n"
        s += "- App: \(app.name)\(app.version.map { " \($0)" } ?? "")\n"
        if let b = app.bundleID { s += "- Bundle ID: \(b)\n" }
        if let size = app.size { s += "- Size: \(Fmt.bytes(size))\n" }
        s += "- Last opened: \(Fmt.date(app.lastUsed))\n"
        if !leftovers.isEmpty {
            s += "- Related files found:\n"
            for l in leftovers.prefix(15) { s += "  - `\(l.url.displayPath)` \(Fmt.bytes(l.size))\n" }
        }
        return s
    }
}

@MainActor
enum ContextBuilder {
    /// Snapshot of the Mac's state for the AI assistant (shared only if the user leaves "Include Mac context" on).
    static func summary(_ state: AppState) -> String {
        let d = state.disk, m = state.memory
        var s = "## Current state of the user's Mac (live data from Cleaner)\n"
        s += "- Model: \(MacInfo.model) \(MacInfo.chip), macOS \(MacInfo.osVersion)\n"
        s += "- Disk: \(Fmt.bytes(d.total)) total, \(Fmt.bytes(d.used)) used, \(Fmt.bytes(d.free)) free, \(Fmt.bytes(d.purgeable)) purgeable\n"
        s += "- Memory: \(Fmt.bytes(m.total)) RAM, \(Fmt.bytes(m.used)) used (app \(Fmt.bytes(m.app)), wired \(Fmt.bytes(m.wired)), compressed \(Fmt.bytes(m.compressed))), \(Fmt.bytes(m.cached)) cached files\n"
        s += "- Memory pressure: \(m.pressureLabel), swap used \(Fmt.bytes(m.swapUsed))\n"
        let apps = state.maintenance.appMemory
        if !apps.isEmpty {
            s += "- Top apps by memory: " + apps.prefix(6).map { "\($0.name) \(Fmt.bytes($0.memory))" }.joined(separator: ", ") + "\n"
        }
        for i in state.maintenance.insights { s += "- Health check: \(i.title)\n" }
        s += "- Full Disk Access granted to Cleaner: \(state.hasFullDiskAccess ? "yes" : "no")\n"
        let snaps = state.maintenance.snapshots.count
        if snaps > 0 { s += "- Local Time Machine snapshots: \(snaps)\n" }

        let junk = state.junk.results
        if !junk.isEmpty {
            s += "\n### Last Smart Scan (\(Fmt.bytes(state.junk.totalFound)) found)\n"
            for r in junk {
                s += "- \(r.rule.title): \(Fmt.bytes(r.total)) in \(r.items.count) items (\(r.rule.safety.label))"
                let top = r.items.prefix(3).map { "`\($0.url.displayPath)` \(Fmt.bytes($0.size))" }
                s += top.isEmpty ? "\n" : " — e.g. \(top.joined(separator: ", "))\n"
            }
        }

        let files = state.largeFiles.files
        if !files.isEmpty {
            s += "\n### Largest files found\n"
            for f in files.prefix(15) { s += "- `\(f.url.displayPath)` \(Fmt.bytes(f.size)), modified \(Fmt.date(f.modified))\n" }
        }

        let cats = state.explorer.categories.filter { $0.size != nil }
        if !cats.isEmpty {
            s += "\n### Disk usage by category\n"
            for c in cats { s += "- \(c.title): \(Fmt.bytes(c.size ?? 0))\n" }
        }
        if let root = state.explorer.root, let kids = root.children, !kids.isEmpty {
            s += "\n### Storage Explorer: biggest items in `\(root.url.displayPath)`\n"
            for k in kids.prefix(12) { s += "- `\(k.url.displayPath)` \(k.size.map(Fmt.bytes) ?? "…")\n" }
        }
        return s
    }
}
