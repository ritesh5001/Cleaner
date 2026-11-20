import Foundation

enum AIProviderKind: String, CaseIterable, Identifiable {
    /// Your Claude Pro/Max subscription, through your own signed-in Claude Code CLI.
    case claudeCode
    /// Anthropic API key.
    case claude
    /// Your Google account, through your own signed-in Gemini CLI.
    case geminiCLI
    /// Gemini API key.
    case gemini

    var id: String { rawValue }

    var usesAPIKey: Bool { self == .claude || self == .gemini }
    var cliName: String? {
        switch self {
        case .claudeCode: "claude"
        case .geminiCLI: "gemini"
        default: nil
        }
    }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude subscription (via Claude Code)"
        case .claude: "Claude API key"
        case .geminiCLI: "Google account (via Gemini CLI)"
        case .gemini: "Gemini API key"
        }
    }

    var shortName: String {
        switch self {
        case .claudeCode: "Claude (subscription)"
        case .claude: "Claude API"
        case .geminiCLI: "Gemini CLI"
        case .gemini: "Gemini API"
        }
    }

    /// Sensible defaults; users can pick any model their account has access to.
    var defaultModel: String {
        switch self {
        case .claudeCode: "sonnet"
        case .claude: "claude-sonnet-5-5"
        case .geminiCLI: ""
        case .gemini: "gemini-3.5-flash"
        }
    }

    var keyURL: URL {
        switch self {
        case .claudeCode: URL(string: "https://docs.anthropic.com/en/docs/claude-code/setup")!
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")!
        case .geminiCLI: URL(string: "https://github.com/google-gemini/gemini-cli")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    var keyPlaceholder: String { self == .claude ? "sk-ant-…" : "AIza…" }

    var setupHint: String {
        switch self {
        case .claudeCode:
            "Uses your Claude Pro/Max plan through your own Claude Code login: Storage Fusion runs `claude -p` on this Mac with tools and MCP servers turned off. Your login never touches Storage Fusion, and usage counts toward your plan's limits. Install Claude Code, then run `claude` once in Terminal to sign in."
        case .geminiCLI:
            "Uses your Google account through your own Gemini CLI login. Install it with `npm install -g @google/gemini-cli`, then run `gemini` once to sign in."
        case .claude, .gemini:
            "Pay-as-you-go API key, stored in this Mac user's Keychain."
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

enum AIError: LocalizedError {
    case missingKey(AIProviderKind)
    case cliMissing(AIProviderKind)
    case cli(String)
    case http(Int, String)
    case empty
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey(let k):
            k.usesAPIKey ? "No \(k.shortName) key yet. Add one in Settings → AI." : AIError.cliMissing(k).errorDescription
        case .cliMissing(let k): "\(k.cliName ?? "CLI") wasn't found on this Mac. Install it and sign in, then press “Detect” in Settings → AI."
        case .cli(let msg): "The AI command failed: \(msg)"
        case .http(let code, let msg):
            switch code {
            case 401, 403: "The API key was rejected (\(code)). Check it in Settings → AI. \(msg)"
            case 404: "Model not found (404). Pick another model in Settings → AI. \(msg)"
            case 429: "Rate limit or quota reached (429). \(msg)"
            default: "AI request failed (\(code)): \(msg)"
            }
        case .empty: "The AI returned an empty answer. Try again or choose another model."
        case .badResponse: "Unexpected response from the AI provider."
        }
    }
}

protocol AIClient {
    func complete(system: String, messages: [ChatMessage], model: String, maxTokens: Int) async throws -> String
    func listModels() async throws -> [String]
}

private func sendJSON(_ req: URLRequest) async throws -> [String: Any] {
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse }
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    guard (200..<300).contains(http.statusCode) else {
        let msg = ((json?["error"] as? [String: Any])?["message"] as? String)
            ?? String(decoding: data.prefix(300), as: UTF8.self)
        throw AIError.http(http.statusCode, msg)
    }
    guard let json else { throw AIError.badResponse }
    return json
}

// MARK: - Anthropic Messages API

struct ClaudeClient: AIClient {
    let apiKey: String
    private let base = "https://api.anthropic.com/v1"

    private func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: URL(string: base + path)!)
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.timeoutInterval = 120
        return r
    }

    func complete(system: String, messages: [ChatMessage], model: String, maxTokens: Int) async throws -> String {
        var req = request("/messages")
        req.httpMethod = "POST"
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.text] },
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await sendJSON(req)
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined()
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }

    func listModels() async throws -> [String] {
        let json = try await sendJSON(request("/models?limit=100"))
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
}

// MARK: - Google Gemini API

struct GeminiClient: AIClient {
    let apiKey: String
    private let base = "https://generativelanguage.googleapis.com/v1beta"

    private func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: URL(string: base + path)!)
        r.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.timeoutInterval = 120
        return r
    }

    func complete(system: String, messages: [ChatMessage], model: String, maxTokens: Int) async throws -> String {
        let id = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var req = request("/models/\(escaped):generateContent")
        req.httpMethod = "POST"
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": messages.map { ["role": $0.role == .user ? "user" : "model", "parts": [["text": $0.text]]] },
            // Extra headroom: newer Gemini models spend output tokens on thinking.
            "generationConfig": ["maxOutputTokens": maxTokens * 2],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await sendJSON(req)
        if let feedback = json["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            throw AIError.http(400, "Request blocked by Gemini safety filters (\(reason)).")
        }
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let parts = ((candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }

    func listModels() async throws -> [String] {
        let json = try await sendJSON(request("/models?pageSize=200"))
        return (json["models"] as? [[String: Any]] ?? []).compactMap { m in
            guard let name = m["name"] as? String,
                  (m["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") else { return nil }
            return name.replacingOccurrences(of: "models/", with: "")
        }
        .filter { $0.contains("gemini") }
    }
}

// MARK: - Local CLIs (use the person's own subscription login)

enum CLILocator {
    private static func defaultsKey(_ name: String) -> String { "ai.cliPath.\(name)" }

    /// Last detected path (readable from any thread).
    static func cachedPath(_ name: String) -> String? {
        guard let p = UserDefaults.standard.string(forKey: defaultsKey(name)),
              FileManager.default.isExecutableFile(atPath: p) else { return nil }
        return p
    }

    /// Looks in common install locations, then asks the user's login shell (GUI apps don't inherit PATH).
    static func detect(_ name: String) -> String? {
        let home = Paths.home.path
        var candidates = [
            "\(home)/.local/bin/\(name)", "\(home)/.claude/local/\(name)", "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)", "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)",
            "\(home)/.volta/bin/\(name)",
        ]
        let nvm = URL(fileURLWithPath: "\(home)/.nvm/versions/node")
        candidates += Paths.children(of: nvm).map { $0.appendingPathComponent("bin/\(name)").path }
        var found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil {
            let r = Shell.run("/bin/zsh", ["-lic", "command -v \(name)"])
            let p = r.out.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if p.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: p) { found = p }
        }
        UserDefaults.standard.set(found, forKey: defaultsKey(name))
        return found
    }

    /// Environment for child CLIs: GUI apps start with a minimal PATH, but CLIs often need node etc.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = Paths.home.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
            + Paths.children(of: URL(fileURLWithPath: "\(home)/.nvm/versions/node")).map { $0.appendingPathComponent("bin").path }
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        // Claude Code finds its Keychain login by user name.
        env["USER"] = env["USER"] ?? NSUserName()
        env["LOGNAME"] = env["LOGNAME"] ?? NSUserName()
        env["HOME"] = env["HOME"] ?? home
        return env
    }

    /// Neutral working directory so the CLI doesn't pick up any project's instructions.
    static var workDir: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cleaner-ai", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// CLIs are stateless here, so earlier turns are replayed as a transcript.
    static func transcript(_ messages: [ChatMessage]) -> String {
        guard messages.count > 1, let last = messages.last else { return messages.last?.text ?? "" }
        var s = "Conversation so far:\n\n"
        for m in messages.dropLast() { s += "\(m.role == .user ? "User" : "Assistant"): \(m.text)\n\n" }
        s += "User's new message (answer this):\n\(last.text)"
        return s
    }
}

struct ClaudeCodeClient: AIClient {
    let binary: String

    func complete(system: String, messages: [ChatMessage], model: String, maxTokens: Int) async throws -> String {
        var args = ["-p", "--output-format", "json", "--system-prompt", system,
                    "--tools", "", "--strict-mcp-config", "--no-session-persistence"]
        if !model.isEmpty { args += ["--model", model] }
        let input = CLILocator.transcript(messages)
        let bin = binary
        let r = await Task.detached {
            Shell.run(bin, args, stdin: input, cwd: CLILocator.workDir, env: CLILocator.environment, timeout: 300)
        }.value
        let json = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any]
        if let json {
            let text = json["result"] as? String ?? ""
            if (json["is_error"] as? Bool) == true { throw AIError.cli(text.isEmpty ? "Claude Code reported an error" : text) }
            guard !text.isEmpty else { throw AIError.empty }
            return text
        }
        let err = (r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines)
        if err.localizedCaseInsensitiveContains("login") || err.localizedCaseInsensitiveContains("auth") {
            throw AIError.cli("Claude Code isn't signed in. Open Terminal, run `claude` and sign in with your Claude account. (\(err.prefix(200)))")
        }
        throw AIError.cli(err.isEmpty ? "exit code \(r.status)" : String(err.prefix(400)))
    }

    func listModels() async throws -> [String] {
        ["sonnet", "opus", "haiku", "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "claude-fable-5-2"]
    }
}

struct GeminiCLIClient: AIClient {
    let binary: String

    func complete(system: String, messages: [ChatMessage], model: String, maxTokens: Int) async throws -> String {
        // Gemini CLI has no system-prompt flag, so instructions go first on stdin.
        let input = "<instructions>\n\(system)\n</instructions>\n\n" + CLILocator.transcript(messages)
        var args = ["-p", "Follow the instructions and answer the request above."]
        if !model.isEmpty { args += ["-m", model] }
        let bin = binary
        let r = await Task.detached {
            Shell.run(bin, args, stdin: input, cwd: CLILocator.workDir, env: CLILocator.environment, timeout: 300)
        }.value
        let text = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok else {
            let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIError.cli(String((err.isEmpty ? text : err).prefix(400)))
        }
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }

    func listModels() async throws -> [String] {
        ["gemini-3.5-flash", "gemini-3.5-pro", "gemini-3.1-pro-preview"]
    }
}
