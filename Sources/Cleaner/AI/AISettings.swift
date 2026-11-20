import Foundation

/// Per-user AI configuration. Every macOS user brings their own provider + key.
@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()

    @Published var activeProvider: AIProviderKind {
        didSet { UserDefaults.standard.set(activeProvider.rawValue, forKey: "ai.activeProvider") }
    }
    @Published private(set) var maskedKeys: [AIProviderKind: String] = [:]
    @Published private(set) var modelOverrides: [String: String]
    @Published var shareFolderListings: Bool {
        didSet { UserDefaults.standard.set(shareFolderListings, forKey: "ai.shareListings") }
    }

    private init() {
        let d = UserDefaults.standard
        activeProvider = AIProviderKind(rawValue: d.string(forKey: "ai.activeProvider") ?? "") ?? .claude
        modelOverrides = d.dictionary(forKey: "ai.models") as? [String: String] ?? [:]
        shareFolderListings = d.object(forKey: "ai.shareListings") as? Bool ?? true
        refreshKeys()
    }

    var isReady: Bool { isConfigured(activeProvider) }
    var configuredProviders: [AIProviderKind] { AIProviderKind.allCases.filter(isConfigured) }

    func isConfigured(_ k: AIProviderKind) -> Bool { maskedKeys[k] != nil }

    func model(for k: AIProviderKind) -> String {
        let m = modelOverrides[k.rawValue]?.trimmingCharacters(in: .whitespaces) ?? ""
        return m.isEmpty ? k.defaultModel : m
    }

    func setModel(_ m: String, for k: AIProviderKind) {
        modelOverrides[k.rawValue] = m
        UserDefaults.standard.set(modelOverrides, forKey: "ai.models")
    }

    @discardableResult
    func saveKey(_ key: String, for k: AIProviderKind) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ok = Keychain.save(trimmed, account: k.rawValue)
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
        for k in AIProviderKind.allCases {
            if let key = Keychain.read(account: k.rawValue), !key.isEmpty {
                m[k] = "••••••••" + key.suffix(4)
            }
        }
        maskedKeys = m
    }
}

enum AIService {
    static func client(_ kind: AIProviderKind, key: String) -> AIClient {
        switch kind {
        case .claude: ClaudeClient(apiKey: key)
        case .gemini: GeminiClient(apiKey: key)
        }
    }

    static func complete(kind: AIProviderKind, model: String, system: String,
                         messages: [ChatMessage], maxTokens: Int = 2048) async throws -> String {
        guard let key = Keychain.read(account: kind.rawValue), !key.isEmpty else { throw AIError.missingKey(kind) }
        return try await client(kind, key: key).complete(system: system, messages: messages, model: model, maxTokens: maxTokens)
    }

    static func listModels(kind: AIProviderKind) async throws -> [String] {
        guard let key = Keychain.read(account: kind.rawValue), !key.isEmpty else { throw AIError.missingKey(kind) }
        return try await client(kind, key: key).listModels().sorted()
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
