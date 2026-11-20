import SwiftUI

struct AssistantView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AISettings
    @ObservedObject var model: AssistantModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "AI Assistant", subtitle: "Ask anything about your Mac's storage and speed.") {
                if ai.configuredProviders.count > 1 {
                    Picker("Provider", selection: $ai.activeProvider) {
                        ForEach(ai.configuredProviders) { Text($0.shortName).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                    .labelsHidden()
                }
                Toggle("Include Mac context", isOn: $model.attachContext)
                    .help("Shares disk & memory stats and your latest scan results (paths and sizes only).")
                Button("Clear") { model.clear() }.disabled(model.messages.isEmpty)
            }
            .padding(20)
            Divider()

            if !ai.isReady {
                setupPrompt
            } else {
                conversation
                Divider()
                inputBar.padding(12)
            }
        }
    }

    private var setupPrompt: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "key.horizontal").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Connect your own AI").font(.title3)
            Text("Use your Claude subscription (through Claude Code), your Google account (through Gemini CLI), or an API key. Each Mac user connects their own.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
            Button("Open AI Settings") { state.selection = .settings }.glassButton(prominent: true)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.messages.isEmpty {
                        Text("Try asking:").font(.headline).padding(.top, 8)
                        ForEach(AssistantModel.suggestions, id: \.self) { s in
                            Button {
                                model.input = s
                                send()
                            } label: {
                                Text(s).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    ForEach(model.messages) { m in bubble(m) }
                    if model.isSending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(ai.activeProvider.shortName) is thinking…").foregroundStyle(.secondary)
                        }
                    }
                    if let err = model.error {
                        Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
            }
            .onChange(of: model.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func bubble(_ m: ChatMessage) -> some View {
        HStack(alignment: .top) {
            if m.role == .user { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 4) {
                if m.role == .assistant {
                    Label(ai.activeProvider.shortName, systemImage: "sparkles").font(.caption).foregroundStyle(.purple)
                    MarkdownText(text: m.text)
                } else {
                    Text(m.text).textSelection(.enabled)
                }
            }
            .padding(12)
            .glassCard(cornerRadius: 18, tint: m.role == .user ? .accentColor : nil)
            if m.role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about your storage, a folder, or what's safe to delete…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(10)
                .glassCard(cornerRadius: 10)
                .onSubmit { send() }
            Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.isSending)
                .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    private func send() {
        let context = model.attachContext ? ContextBuilder.summary(state) : nil
        Task { await model.send(context: context) }
    }
}
