import Foundation

enum AIProviderKind: String, CaseIterable, Identifiable {
    case claude, gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude (Anthropic)"
        case .gemini: "Gemini (Google)"
        }
    }

    var shortName: String { self == .claude ? "Claude" : "Gemini" }

    /// Sensible defaults; users can pick any model their key has access to via "Fetch models".
    var defaultModel: String {
        switch self {
        case .claude: "claude-sonnet-5-5"
        case .gemini: "gemini-3.5-flash"
        }
    }

    var keyURL: URL {
        switch self {
        case .claude: URL(string: "https://console.anthropic.com/settings/keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    var keyPlaceholder: String { self == .claude ? "sk-ant-…" : "AIza…" }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

enum AIError: LocalizedError {
    case missingKey(AIProviderKind)
    case http(Int, String)
    case empty
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey(let k): "No \(k.shortName) API key yet. Add one in Settings → AI."
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
