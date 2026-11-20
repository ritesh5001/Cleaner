import Foundation

/// Plain-language answers to "what is this, what is it for, what happens if I delete it?"
struct DataExplanation: Codable, Hashable {
    var what: String
    var usedFor: String
    var ifDeleted: String
    /// "safe", "review" or "keep"
    var verdict: String
    var fromAI = false

    var safety: Safety {
        switch verdict.lowercased() {
        case "safe": .safe
        case "keep": .caution
        default: .review
        }
    }

    var verdictLabel: String {
        switch verdict.lowercased() {
        case "safe": "Safe to delete"
        case "keep": "Keep"
        default: "Review first"
        }
    }
}

enum DataExplainer {
    private static let defaultsKey = "explain.ai"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var aiCache: [String: DataExplanation] = {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let map = try? JSONDecoder().decode([String: DataExplanation].self, from: data) else { return [:] }
        return map
    }()

    /// AI explanation if one was fetched, otherwise Cleaner's built-in knowledge.
    static func explanation(for url: URL, kind: String, owner: AppOwner?) -> DataExplanation {
        lock.lock(); let cached = aiCache[url.path]; lock.unlock()
        return cached ?? builtIn(for: url, kind: kind, owner: owner)
    }

    static func hasAI(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return aiCache[url.path] != nil
    }

    // MARK: Built-in knowledge

    /// Well-known folders worth a specific answer.
    private static let specific: [String: DataExplanation] = [
        "vm_bundles": .init(what: "A full virtual-machine disk image downloaded by the Claude desktop app.",
                            usedFor: "Running Claude's sandboxed features (computer use, code execution) safely in an isolated Linux VM.",
                            ifDeleted: "Claude re-downloads it (several GB) the next time you use those features. Quit Claude first.",
                            verdict: "review"),
        "cachedextensionvsixs": .init(what: "Downloaded installer packages (.vsix) of your VS Code extensions.",
                                      usedFor: "Reinstalling or updating extensions without downloading again.",
                                      ifDeleted: "Nothing breaks — VS Code downloads packages again only when needed.",
                                      verdict: "safe"),
        "workspacestorage": .init(what: "Per-project state the editor remembers: open tabs, search history, extension data.",
                                  usedFor: "Restoring each project the way you left it.",
                                  ifDeleted: "Projects open without remembered tabs/layout; settings and code are untouched.",
                                  verdict: "review"),
        "extensions": .init(what: "Installed editor extensions.",
                            usedFor: "Language support, AI assistants, themes and tools inside the editor.",
                            ifDeleted: "All extensions disappear and must be reinstalled.",
                            verdict: "keep"),
        "_cacache": .init(what: "npm's download cache of package tarballs.",
                          usedFor: "Installing packages faster and offline.",
                          ifDeleted: "Nothing breaks — npm re-downloads packages on the next install.",
                          verdict: "safe"),
        "partitions": .init(what: "Separate browser profiles used inside an Electron app (sessions, storage, caches).",
                            usedFor: "Keeping sign-ins and web data for built-in browser panes.",
                            ifDeleted: "You may be signed out of services used inside the app.",
                            verdict: "review"),
        "indexeddb": .init(what: "Local databases created by web content inside the app.",
                           usedFor: "Offline data, drafts and app state.",
                           ifDeleted: "Offline data and some app state are lost.",
                           verdict: "review"),
        "local storage": .init(what: "Small key-value store for web content inside the app.",
                               usedFor: "Remembering preferences and sign-in state.",
                               ifDeleted: "Some settings reset; you may need to sign in again.",
                               verdict: "review"),
    ]

    static func builtIn(for url: URL, kind: String, owner: AppOwner?) -> DataExplanation {
        let app = owner?.name ?? "the app"
        if let reason = SafetyGuard.blockReason(for: url) {
            return .init(what: "Protected data (\(reason.lowercased())).", usedFor: "Information that can't be recreated.",
                         ifDeleted: "Cleaner won't delete it — losing it could be permanent.", verdict: "keep")
        }
        if let s = specific[url.lastPathComponent.lowercased()] { return s }
        let gone = owner?.installed == false
        let leftoverNote = gone ? " The app is no longer installed, so this is most likely leftover junk." : ""

        switch kind {
        case "Application":
            return .init(what: "The \(app) application itself.", usedFor: "Running \(app).",
                         ifDeleted: "\(app) is removed. Use Uninstall to also remove its data.", verdict: "review")
        case "Cache", "Hidden cache":
            return .init(what: "Temporary copies of things \(app) downloaded or computed\(kind == "Hidden cache" ? ", kept in macOS's private per-app cache folder" : "").",
                         usedFor: "Making \(app) start and load faster.",
                         ifDeleted: "Safe — \(app) rebuilds what it needs. It may be a little slower the first time." + leftoverNote,
                         verdict: "safe")
        case "Logs":
            return .init(what: "Diagnostic logs written by \(app).", usedFor: "Troubleshooting crashes and errors.",
                         ifDeleted: "Safe — only useful when debugging a problem." + leftoverNote, verdict: "safe")
        case "Saved window state":
            return .init(what: "The window positions \(app) restores on relaunch.", usedFor: "Reopening windows where you left them.",
                         ifDeleted: "Safe — windows just open in default positions.", verdict: "safe")
        case "Web storage", "Web data", "Cookies":
            return .init(what: "Cookies, website data and network cache used by \(app)'s built-in web views.",
                         usedFor: "Keeping you signed in to web services inside \(app) and loading pages faster.",
                         ifDeleted: "Mostly safe — you may be signed out of some services inside \(app)." + leftoverNote,
                         verdict: gone ? "safe" : "review")
        case "Preferences":
            return .init(what: "\(app)'s settings file.", usedFor: "Remembering how you configured \(app).",
                         ifDeleted: gone ? "Safe — the app is gone." : "\(app) resets to default settings (tiny file — not worth deleting).",
                         verdict: gone ? "safe" : "keep")
        case "Sandbox container":
            return .init(what: "\(app)'s private sandbox: everything it saves, including settings, caches and sometimes documents.",
                         usedFor: "Isolating \(app)'s data from other apps (Mac App Store-style apps).",
                         ifDeleted: gone ? "Safe — the app is gone." : "All of \(app)'s data and settings are erased, possibly including documents.",
                         verdict: gone ? "safe" : "keep")
        case "Shared container":
            return .init(what: "Data shared between \(app) and its widgets, extensions or helper apps.",
                         usedFor: "Syncing state between the app and its extensions.",
                         ifDeleted: gone ? "Safe — the app is gone." : "Widgets/extensions lose data and \(app) may reset parts of itself.",
                         verdict: gone ? "safe" : "review")
        case "Tool folder":
            return .init(what: "Settings, downloaded packages, history or logins for a developer / command-line tool.",
                         usedFor: "Making the tool work without reconfiguring each time.",
                         ifDeleted: "The tool may lose settings or logins and re-download what it needs.", verdict: "review")
        default:
            return .init(what: "Data \(app) stores for you: databases, downloads, extensions, offline content and settings.",
                         usedFor: "Everything \(app) needs to remember between launches.",
                         ifDeleted: gone ? "Most likely leftover junk — the app is no longer installed."
                                         : "\(app) may lose sign-ins, history, downloaded content or settings and start fresh.",
                         verdict: gone ? "safe" : "review")
        }
    }

    // MARK: AI

    /// Asks the user's AI to explain specific folders. Results are cached by path.
    @MainActor
    static func explainWithAI(_ items: [(url: URL, kind: String, size: Int64?, owner: AppOwner?)]) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        var prompt = """
        For each item below on my Mac, explain in plain, non-technical English:
        - "what": what this data is (max 20 words)
        - "usedFor": what the app uses it for (max 20 words)
        - "ifDeleted": what happens if I delete it (max 25 words)
        - "verdict": "safe", "review" or "keep"
        Reply with ONLY a JSON object mapping each exact path (as written) to that object.

        """
        for i in items.prefix(40) {
            prompt += "- `\(i.url.displayPath)` — \(i.kind)\(i.owner.map { ", belongs to \($0.name)\($0.installed ? "" : " (not installed)")" } ?? "")\(i.size.map { ", \(Fmt.bytes($0))" } ?? "")\n"
        }
        let reply = try await AIService.ask(prompt)
        guard let s = reply.firstIndex(of: "{"), let e = reply.lastIndex(of: "}"),
              let data = String(reply[s...e]).data(using: .utf8),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else {
            throw AIError.cli("The AI's answer wasn't in the expected format. Try again.")
        }
        let byDisplay = Dictionary(items.map { ($0.url.displayPath, $0.url) }, uniquingKeysWith: { a, _ in a })
        var added: [String: DataExplanation] = [:]
        for (path, v) in map {
            let key = path.trimmingCharacters(in: CharacterSet(charactersIn: "` "))
            guard let url = byDisplay[key] else { continue }
            added[url.path] = DataExplanation(what: v["what"] as? String ?? "", usedFor: v["usedFor"] as? String ?? "",
                                              ifDeleted: v["ifDeleted"] as? String ?? "", verdict: v["verdict"] as? String ?? "review",
                                              fromAI: true)
        }
        store(added)
        return added.count
    }

    private static func store(_ added: [String: DataExplanation]) {
        lock.lock()
        aiCache.merge(added) { _, new in new }
        let snapshot = aiCache
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }
}
