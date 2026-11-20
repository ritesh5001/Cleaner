import Foundation

@MainActor
final class AssistantModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var input = ""
    @Published private(set) var isSending = false
    @Published var error: String?
    @Published var attachContext = true

    static let suggestions = [
        "Why is my “System Data” so large, and what can I safely do about it?",
        "Based on my last Smart Scan, what should I clean first?",
        "Which of my largest files should I review or move to an external drive?",
        "My Mac feels slow. What do my memory numbers say?",
        "How do I safely clean up Xcode, Docker and Homebrew space?",
    ]

    func send(context: String?) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        input = ""
        error = nil
        let history = messages
        messages.append(ChatMessage(role: .user, text: text))
        isSending = true
        defer { isSending = false }
        do {
            let reply = try await AIService.ask(text, history: history, extraSystem: context)
            messages.append(ChatMessage(role: .assistant, text: reply))
        } catch {
            // Keep the conversation strictly alternating user/assistant.
            messages.removeLast()
            input = text
            self.error = error.localizedDescription
        }
    }

    func clear() {
        messages = []
        error = nil
    }
}
