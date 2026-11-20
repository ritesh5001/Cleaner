import Foundation

/// Per-user AI configuration. Every macOS user brings their own provider: a subscription
/// through their own signed-in CLI (Claude Code / Gemini CLI) or a pay-as-you-go API key.
@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()

    @Published var activeProvider: AIProviderKind {
        didSet { UserDefaults.standard.set(activeProvider.rawValue, forKey: "ai.activeProvider") }
    }
    @Published private(set) var maskedKeys: [AIProviderKind: String] = [:]
    @Published private(set) var cliPaths: [AIProviderKind: String] = [:]
    @Published private(set) var isDetecting = false
    @Published private(set) var modelOverrides: [String: String]
    @Published var shareFolderListings: Bool {
        didSet { UserDefaults.standard.set(shareFolderListings, forKey: "ai.shareListings") }
    }

    private init() {
        let d = UserDefaults.standard
        let saved = d.string(forKey: "ai.activeProvider")
        activeProvider = AIProviderKind(rawValue: saved ?? "") ?? .claudeCode
        modelOverrides = d.dictionary(forKey: "ai.models") as? [String: String] ?? [:]
        shareFolderListings = d.object(forKey: "ai.shareListings") as? Bool ?? true
        for k in AIProviderKind.allCases {
            if let name = k.cliName, let p = CLILocator.cachedPath(name) { cliPaths[k] = p }
        }
        refreshKeys()
        detectCLIs(pickDefault: saved == nil)
    }

    var isReady: Bool { isConfigured(activeProvider) }
    var configuredProviders: [AIProviderKind] { AIProviderKind.allCases.filter(isConfigured) }

    func isConfigured(_ k: AIProviderKind) -> Bool {
        k.usesAPIKey ? maskedKeys[k] != nil : cliPaths[k] != nil
    }

    func model(for k: AIProviderKind) -> String {
        let m = modelOverrides[k.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? k.defaultModel : m
    }

    func setModel(_ m: String, for k: AIProviderKind) {
        modelOverrides[k.rawValue] = m
        UserDefaults.standard.set(modelOverrides, forKey: "ai.models")
    }

    /// Finds Claude Code / Gemini CLI. On first launch, prefers the user's subscription if available.
    func detectCLIs(pickDefault: Bool = false) {
        isDetecting = true
        Task {
            var found: [AIProviderKind: String] = [:]
            for k in AIProviderKind.allCases {
                guard let name = k.cliName else { continue }
                if let p = await Task.detached(operation: { CLILocator.detect(name) }).value { found[k] = p }
            }
            cliPaths = found
            isDetecting = false
            if pickDefault || !isConfigured(activeProvider), let first = configuredProviders.first {
                activeProvider = first
            }
        }
    }

    @discardableResult
    func saveKey(_ key: String, for k: AIProviderKind) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ok = Keychain.save(trimmed, account: k.rawValue)
        if ok { UserDefaults.standard.set(String(trimmed.suffix(4)), forKey: "ai.keyHint.\(k.rawValue)") }
        refreshKeys()
        if ok, !isConfigured(activeProvider) { activeProvider = k }
        return ok
    }

    func removeKey(for k: AIProviderKind) {
        Keychain.delete(account: k.rawValue)
        refreshKeys()
        if !isConfigured(activeProvider), let other = configuredProviders.first { activeProvider = other }
    }

    func refreshKeys() {
        var m: [AIProviderKind: String] = [:]
        // Only check that a key exists — reading the secret is deferred until an AI request,
        // so launching the app never triggers a Keychain prompt.
        for k in AIProviderKind.allCases where k.usesAPIKey && Keychain.exists(account: k.rawValue) {
            m[k] = "••••••••" + (UserDefaults.standard.string(forKey: "ai.keyHint.\(k.rawValue)") ?? "")
        }
        maskedKeys = m
    }
}

enum AIService {
    static func client(_ kind: AIProviderKind) throws -> AIClient {
        switch kind {
        case .claudeCode, .geminiCLI:
            guard let name = kind.cliName, let path = CLILocator.cachedPath(name) else { throw AIError.cliMissing(kind) }
            return kind == .claudeCode ? ClaudeCodeClient(binary: path) : GeminiCLIClient(binary: path)
        case .claude, .gemini:
            guard let key = Keychain.read(account: kind.rawValue), !key.isEmpty else { throw AIError.missingKey(kind) }
            return kind == .claude ? ClaudeClient(apiKey: key) : GeminiClient(apiKey: key)
        }
    }

    static func complete(kind: AIProviderKind, model: String, system: String,
                         messages: [ChatMessage], maxTokens: Int = 2048) async throws -> String {
        try await client(kind).complete(system: system, messages: messages, model: model, maxTokens: maxTokens)
    }

    static func listModels(kind: AIProviderKind) async throws -> [String] {
        try await client(kind).listModels()
    }

    /// Ask the user's active provider, with Cleaner's safety-focused system prompt.
    @MainActor
    static func ask(_ prompt: String, history: [ChatMessage] = [], extraSystem: String? = nil) async throws -> String {
        let s = AISettings.shared
        var system = Prompts.system
        if let extraSystem, !extraSystem.isEmpty { system += "\n\n" + extraSystem }
        return try await complete(kind: s.activeProvider, model: s.model(for: s.activeProvider), system: system,
                                  messages: history + [ChatMessage(role: .user, text: prompt)], maxTokens: 3000)
    }
}
