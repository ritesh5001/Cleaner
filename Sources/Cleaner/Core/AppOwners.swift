import Foundation
import AppKit

/// Who a file or folder belongs to: an installed app, a developer tool, macOS itself, or unknown.
struct AppOwner: Hashable, Sendable {
    enum Source: String, Sendable {
        case bundleID   // matched by bundle identifier — certain
        case name       // matched by folder name — likely
        case known      // from Cleaner's built-in list of tools
        case apple      // part of macOS
        case ai         // identified by the user's AI
        case unknown
    }

    let key: String
    let name: String
    let bundleURL: URL?
    let symbol: String?
    let source: Source
    var note: String? = nil
    var installed = true

    var isCertain: Bool { source == .bundleID || source == .known || source == .apple }

    @MainActor var icon: NSImage {
        if let bundleURL { return NSWorkspace.shared.icon(forFile: bundleURL.path) }
        let img = NSImage(systemSymbolName: symbol ?? "questionmark.app", accessibilityDescription: name) ?? NSImage()
        return img
    }
}

/// Maps folder names like `BraveSoftware`, `com.microsoft.VSCode` or `openbot-updater` to apps.
final class AppOwnerResolver: @unchecked Sendable {
    static let shared = AppOwnerResolver()

    private struct AppEntry {
        let name: String
        let id: String
        let url: URL
        let keys: [String]   // lowercased name variants
    }

    private let lock = NSLock()
    private var apps: [AppEntry] = []
    private var byID: [String: AppEntry] = [:]
    private var byName: [String: AppEntry] = [:]
    private var byVendor: [String: [AppEntry]] = [:]
    private var memo: [String: AppOwner?] = [:]
    private var loaded = false

    /// Identifications made by the user's AI, keyed by lowercased item name. Persisted.
    private var aiOwners: [String: [String: String]] =
        UserDefaults.standard.dictionary(forKey: "owners.ai") as? [String: [String: String]] ?? [:]

    // MARK: Index

    func reload() {
        let urls = AppCatalog.appURLs(includeSystem: true)
            + NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        var list: [AppEntry] = []
        var seen = Set<String>()
        // Skip helper apps nested inside other apps (e.g. "Google Chrome Helper.app").
        for url in urls where !url.deletingLastPathComponent().path.contains(".app/") {
            guard let b = Bundle(url: url), let id = b.bundleIdentifier?.lowercased(), seen.insert(id).inserted else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            var keys = [name.lowercased(), name.lowercased().replacingOccurrences(of: " ", with: "")]
            if let exec = b.object(forInfoDictionaryKey: "CFBundleExecutable") as? String { keys.append(exec.lowercased()) }
            if let short = b.object(forInfoDictionaryKey: "CFBundleName") as? String { keys.append(short.lowercased()) }
            list.append(AppEntry(name: name, id: id, url: url, keys: Array(Set(keys))))
        }
        lock.lock()
        apps = list
        byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        byName = [:]
        for a in list { for k in a.keys where byName[k] == nil { byName[k] = a } }
        byVendor = Dictionary(grouping: list) { vendor($0.id) }
        memo = [:]
        loaded = true
        lock.unlock()
    }

    private func ensureLoaded() {
        lock.lock(); let l = loaded; lock.unlock()
        if !l { reload() }
    }

    // MARK: Built-in knowledge (tools and folders that aren't apps)

    private static let known: [String: (name: String, bundleID: String?, symbol: String)] = [
        "homebrew": ("Homebrew", nil, "mug"),
        "pip": ("Python (pip)", nil, "chevron.left.forwardslash.chevron.right"),
        "ms-playwright": ("Playwright test browsers", nil, "theatermasks"),
        "dotslash": ("DotSlash (used by Codex)", nil, "terminal"),
        "node-gyp": ("Node.js (node-gyp)", nil, "terminal"),
        "typescript": ("TypeScript", nil, "terminal"),
        "yarn": ("Yarn", nil, "shippingbox"),
        "pnpm": ("pnpm", nil, "shippingbox"),
        "cocoapods": ("CocoaPods", nil, "shippingbox"),
        "go-build": ("Go", nil, "terminal"),
        "org.swift.swiftpm": ("Swift Package Manager", nil, "swift"),
        "claude-cli-nodejs": ("Claude Code", nil, "terminal"),
        "cleaner-build": ("Cleaner (this app's build files)", nil, "sparkles"),
        "geoservices": ("macOS Maps & Location", nil, "map"),
        "jetbrains": ("JetBrains IDEs", nil, "hammer"),
        "clang": ("Xcode compiler (clang)", nil, "hammer"),
        ".npm": ("npm", nil, "shippingbox"),
        ".gradle": ("Gradle", nil, "shippingbox"),
        ".vscode": ("Visual Studio Code", "com.microsoft.vscode", "chevron.left.forwardslash.chevron.right"),
        ".cursor": ("Cursor", nil, "chevron.left.forwardslash.chevron.right"),
        ".claude": ("Claude Code", nil, "terminal"),
        ".codex": ("Codex", nil, "terminal"),
        ".cache": ("Command-line tools (shared cache)", nil, "terminal"),
        ".nvm": ("nvm (Node.js versions)", nil, "terminal"),
        ".cargo": ("Rust (Cargo)", nil, "terminal"),
        ".rustup": ("Rust toolchains", nil, "terminal"),
        ".docker": ("Docker", "com.docker.docker", "shippingbox"),
        ".android": ("Android tools", nil, "terminal"),
        ".local": ("Command-line tools", nil, "terminal"),
        ".bun": ("Bun", nil, "terminal"),
        ".ollama": ("Ollama", nil, "cpu"),
        ".expo": ("Expo", nil, "iphone"),
        ".m2": ("Maven", nil, "shippingbox"),
        ".pyenv": ("pyenv", nil, "terminal"),
        ".conda": ("Conda", nil, "terminal"),
        ".copilot": ("GitHub Copilot CLI", nil, "terminal"),
        ".net": (".NET SDK", nil, "terminal"),
        ".gstack": ("gstack (Claude Code skills)", nil, "terminal"),
        "codex": ("Codex", nil, "terminal"),
        "swift-frontend": ("Swift compiler", nil, "swift"),
    ]

    /// Folder names macOS frameworks and daemons use.
    private static let appleNames: Set<String> = [
        "familycircled", "passkit", "cloudkit", "animoji", "gamekit", "geod", "metal", "mediaanalysis",
        "keyboardservices", "frontboard", "accessibility", "assistant", "intents", "languagemodeling",
        "ppm", "finance", "passes", "mobile documents", "com.apple.itunescloud", "spotlight",
    ]

    private static let toolSuffixes = ["-updater", "_updater", ".shipit", "-helper", " helper", ".helper", "-crashpad"]
    private static let fileSuffixes = [".plist", ".savedstate", ".binarycookies", ".sqlite3", ".db"]

    // MARK: Resolution

    func owner(for url: URL) -> AppOwner? {
        ensureLoaded()
        let path = url.path
        lock.lock()
        if let cached = memo[path] { lock.unlock(); return cached }
        lock.unlock()
        let result = resolve(url)
        lock.lock(); memo[path] = result; lock.unlock()
        return result
    }

    private func resolve(_ url: URL) -> AppOwner? {
        var n = url.lastPathComponent.lowercased()
        for s in Self.fileSuffixes where n.hasSuffix(s) { n = String(n.dropLast(s.count)) }

        // 1. Built-in list
        if let k = Self.known[n] { return knownOwner(n, k) }
        if Self.appleNames.contains(n) { return appleOwner }

        // 2. Bundle-ID-shaped names (Containers, Preferences, /var/folders…)
        var id = n
        if id.hasPrefix("group.") { id = String(id.dropFirst(6)) }
        let parts = id.split(separator: ".")
        if parts.count >= 3, let first = parts.first, first.count == 10, first.allSatisfy({ $0.isLetter || $0.isNumber }),
           !["com", "org", "net", "app", "io"].contains(String(first)) {
            id = parts.dropFirst().joined(separator: ".")   // strip Team ID prefix of group containers
        }
        if id.split(separator: ".").count >= 2, !id.contains(" ") {
            if let a = matchBundleID(id) ?? launchServicesApp(id) { return installedOwner(a, .bundleID) }
            if id.hasPrefix("com.apple.") { return appleOwner }
        }

        // 3. Name matches, after removing updater/helper suffixes
        var base = n.hasPrefix(".") ? String(n.dropFirst()) : n
        for s in Self.toolSuffixes where base.hasSuffix(s) { base = String(base.dropLast(s.count)) }
        if let k = Self.known[base] { return knownOwner(base, k) }
        lock.lock()
        let exact = byName[base] ?? byName[base.replacingOccurrences(of: " ", with: "")]
        let vendorApps = byVendor[base] ?? []
        let all = apps
        lock.unlock()
        if let exact { return installedOwner(exact, .name) }

        // 4. Vendor folders ("Google" holding Chrome and Drive data)
        if !vendorApps.isEmpty {
            let inside = Set(Paths.children(of: url).map { $0.lastPathComponent.lowercased() })
            let hits = vendorApps.filter { app in inside.contains { app.name.lowercased().contains($0) && $0.count >= 4 } }
            if hits.count == 1 { return installedOwner(hits[0], .name) }
            let names = (hits.isEmpty ? vendorApps : hits).map(\.name).sorted().joined(separator: ", ")
            return AppOwner(key: "vendor:\(base)", name: "\(url.lastPathComponent) (shared by \(names))",
                            bundleURL: nil, symbol: "building.2", source: .name)
        }

        // 5. "bravesoftware" → Brave Browser (first word of the app name)
        if base.count >= 4 {
            let firstWord = all.filter { a in
                let w = a.name.lowercased().split(separator: " ").first.map(String.init) ?? ""
                guard w.count >= 4, base.hasPrefix(w) else { return false }
                // "bravesoftware" → Brave Browser, but not "console-ninja" → Console.
                let rest = base.dropFirst(w.count)
                return rest.isEmpty || ["software", "app", "inc", "labs", "hq", "desktop", "browser"].contains(String(rest))
            }
            if firstWord.count == 1 { return installedOwner(firstWord[0], .name) }
        }

        // 6. The user's AI identified it earlier
        if let ai = aiOwner(n) { return ai }

        // 7. Bundle ID of an app that's no longer installed
        if id.split(separator: ".").count >= 3, !id.contains(" "), id.first?.isLetter == true {
            let vendorName = id.split(separator: ".").dropFirst().first.map { $0.capitalized } ?? id
            return AppOwner(key: "gone:\(vendor(id))", name: "\(vendorName) (not installed)", bundleURL: nil,
                            symbol: "app.dashed", source: .unknown, installed: false)
        }
        return nil
    }

    private func matchBundleID(_ id: String) -> AppEntry? {
        lock.lock(); defer { lock.unlock() }
        if let a = byID[id] { return a }
        // Helpers, extensions: com.vendor.app.helper → com.vendor.app
        let prefixes = apps.filter { id.hasPrefix($0.id + ".") }.sorted { $0.id.count > $1.id.count }
        return prefixes.first
    }

    /// LaunchServices knows apps anywhere on disk (not just /Applications).
    private func launchServicesApp(_ id: String) -> AppEntry? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return AppEntry(name: name, id: id, url: url, keys: [name.lowercased()])
    }

    private func vendor(_ id: String) -> String {
        let p = id.split(separator: ".")
        return p.count >= 2 ? String(p[1]) : id
    }

    private var appleOwner: AppOwner {
        AppOwner(key: "apple", name: "macOS (Apple)", bundleURL: nil, symbol: "apple.logo", source: .apple)
    }

    private func installedOwner(_ a: AppEntry, _ source: AppOwner.Source) -> AppOwner {
        AppOwner(key: a.id, name: a.name, bundleURL: a.url, symbol: nil, source: source)
    }

    private func knownOwner(_ key: String, _ k: (name: String, bundleID: String?, symbol: String)) -> AppOwner {
        if let id = k.bundleID {
            lock.lock(); let a = byID[id]; lock.unlock()
            if let a { return installedOwner(a, .known) }
        }
        return AppOwner(key: "tool:\(k.name.lowercased())", name: k.name, bundleURL: nil, symbol: k.symbol, source: .known)
    }

    private func aiOwner(_ n: String) -> AppOwner? {
        lock.lock(); let entry = aiOwners[n]; lock.unlock()
        guard let entry, let name = entry["app"], !name.isEmpty, entry["kind"] != "unknown" else { return nil }
        lock.lock(); let match = byName[name.lowercased()] ?? byName[name.lowercased().replacingOccurrences(of: " ", with: "")]; lock.unlock()
        if entry["kind"] == "macos" { var o = appleOwner; o.note = entry["note"]; return o }
        return AppOwner(key: match?.id ?? "ai:\(name.lowercased())", name: name, bundleURL: match?.url,
                        symbol: entry["kind"] == "tool" ? "terminal" : "sparkles", source: .ai, note: entry["note"])
    }

    // MARK: AI identification

    /// Asks the user's AI provider to identify items Cleaner couldn't attribute. Results are cached.
    @MainActor
    func identifyWithAI(_ items: [(url: URL, size: Int64?)]) async throws -> Int {
        let unique = Dictionary(items.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        guard !unique.isEmpty else { return 0 }
        var prompt = """
        These folders and files are on a Mac. For each one, identify which application, developer tool, \
        or macOS component created it. Reply with ONLY a JSON object mapping the exact item name to \
        {"app": "App or tool name as people know it", "kind": "app" | "tool" | "macos" | "unknown", \
        "note": "what this data is, max 12 words"}.

        """
        for (name, item) in unique.prefix(80) {
            prompt += "- \(name) — `\(item.url.displayPath)`\(item.size.map { " — \(Fmt.bytes($0))" } ?? "")\n"
        }
        let reply = try await AIService.ask(prompt)
        guard let s = reply.firstIndex(of: "{"), let e = reply.lastIndex(of: "}"),
              let data = String(reply[s...e]).data(using: .utf8),
              let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else {
            throw AIError.cli("The AI's answer wasn't in the expected format. Try again.")
        }
        storeAIOwners(map.mapValues { $0.compactMapValues { $0 as? String } })
        return map.count
    }

    private func storeAIOwners(_ map: [String: [String: String]]) {
        lock.lock()
        for (name, v) in map {
            var key = name.lowercased()
            for suf in Self.fileSuffixes where key.hasSuffix(suf) { key = String(key.dropLast(suf.count)) }
            aiOwners[key] = v
        }
        memo = [:]
        let snapshot = aiOwners
        lock.unlock()
        UserDefaults.standard.set(snapshot, forKey: "owners.ai")
    }
}
