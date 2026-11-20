import SwiftUI

struct AgentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AISettings
    @ObservedObject var model: AgentModel
    @Local private var confirmTurn: UUID?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Cleanup Agent",
                       subtitle: "Tell it what to remove in your own words. It plans, you approve, it cleans.") {
                if ai.configuredProviders.count > 1 {
                    Picker("AI", selection: $ai.activeProvider) {
                        ForEach(ai.configuredProviders) { Text($0.shortName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                Button("New Chat") { model.clear() }.disabled(model.turns.isEmpty || model.isWorking)
            }
            .padding(20)

            if !ai.isReady {
                setup
            } else {
                conversation
                inputBar.padding(16)
            }
        }
        .confirmationDialog("Run this cleanup plan?", isPresented: Binding(get: { confirmTurn != nil }, set: { if !$0 { confirmTurn = nil } })) {
            Button("Clean Now", role: .destructive) {
                if let id = confirmTurn { model.execute(id, state: state) }
            }
        } message: {
            if let id = confirmTurn, let plan = model.turns.first(where: { $0.id == id })?.plan {
                Text("\(plan.actions.filter(\.selected).count) item(s), \(Fmt.bytes(plan.selectedSize)), go to the Trash\(plan.tasks.isEmpty ? "" : " and \(plan.tasks.count) maintenance task(s) run"). Every item is re-checked by Cleaner's safety rules first.")
            }
        }
    }

    private var setup: some View {
        VStack(spacing: 14) {
            Spacer()
            SymbolTile(symbol: "wand.and.sparkles", color: .purple, size: 64)
            Text("Connect your AI to use the agent").font(.title3.weight(.semibold))
            Text("Use your Claude subscription (through Claude Code) or an API key.").foregroundStyle(.secondary)
            Button("Open AI Settings") { state.selection = .settings }.glassButton(prominent: true)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if model.turns.isEmpty { intro }
                    ForEach(model.turns) { turn in
                        if turn.role == .user { userBubble(turn) } else { agentBubble(turn) }
                    }
                    if model.isWorking {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(model.status.isEmpty ? "Thinking…" : model.status).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .glassCapsule()
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            .onChange(of: model.turns.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: model.isWorking) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                SymbolTile(symbol: "wand.and.sparkles", color: .purple, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("What should I clean?").font(.title2.weight(.bold))
                    Text("I can only pick from items Cleaner found on this Mac, every choice passes its safety rules, and nothing happens until you press Clean.")
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(AgentModel.suggestions, id: \.self) { s in
                    Button {
                        model.input = s
                        model.send(state: state)
                    } label: {
                        HStack {
                            Image(systemName: "sparkle").foregroundStyle(.purple)
                            Text(s).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 16, interactive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .glassCard(cornerRadius: 26)
    }

    private func userBubble(_ t: AgentTurn) -> some View {
        HStack {
            Spacer(minLength: 120)
            Text(t.text).textSelection(.enabled)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassCard(cornerRadius: 20, tint: .accentColor)
        }
    }

    private func agentBubble(_ t: AgentTurn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                SymbolTile(symbol: "wand.and.sparkles", color: .purple, size: 26)
                MarkdownText(text: t.text)
            }
            if let plan = t.plan { planCard(plan, turnID: t.id) }
        }
        .padding(16)
        .glassCard(cornerRadius: 22)
        .padding(.trailing, 60)
    }

    @ViewBuilder
    private func planCard(_ plan: AgentPlan, turnID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Plan").font(.headline)
                Text("\(plan.actions.filter(\.selected).count) of \(plan.actions.count) selected · \(Fmt.bytes(plan.selectedSize))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(plan.actions) { a in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { a.selected }, set: { _ in model.toggle(a.id, in: turnID) }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .disabled(plan.state != .proposed)
                    OwnerIcon(owner: a.candidate.owner, fallback: a.candidate.url, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(a.candidate.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                            SafetyBadge(safety: a.risk)
                        }
                        Text(a.reason.isEmpty ? a.candidate.label : a.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(a.candidate.url.displayPath).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(Fmt.bytes(a.candidate.size)).font(.callout.weight(.semibold)).monospacedDigit()
                    Button { a.candidate.url.revealInFinder() } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                }
                .padding(10)
                .glassCard(cornerRadius: 14, tint: a.risk == .caution ? .red : nil)
            }
            if !plan.tasks.isEmpty {
                ForEach(plan.tasks, id: \.self) { id in
                    Label(AgentModel.allowedTasks[id] ?? id, systemImage: "gearshape.2")
                        .font(.callout)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassCapsule()
                }
            }
            switch plan.state {
            case .proposed:
                GlassGroup {
                    HStack {
                        Button {
                            confirmTurn = turnID
                        } label: { Label("Clean \(Fmt.bytes(plan.selectedSize))", systemImage: "sparkles") }
                        .glassButton(prominent: true)
                        .disabled(plan.actions.filter(\.selected).isEmpty && plan.tasks.isEmpty)
                        Button("Cancel") { model.cancel(turnID) }.glassButton()
                        Spacer()
                    }
                }
                .controlSize(.large)
                .padding(.top, 4)
            case .running:
                HStack { ProgressView().controlSize(.small); Text("Cleaning…") }
            case .done:
                Label(plan.resultText ?? "Done.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).textSelection(.enabled)
            case .cancelled:
                Label("Cancelled — nothing was changed.", systemImage: "xmark.circle").foregroundStyle(.secondary)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("e.g. “delete Chrome and Brave caches and screenshots older than a month”", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .onSubmit { model.send(state: state) }
            Button { model.send(state: state) } label: {
                Image(systemName: "arrow.up").font(.headline).frame(width: 30, height: 30)
            }
            .glassButton(prominent: true)
            .clipShape(Circle())
            .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
            .keyboardShortcut(.return, modifiers: [.command])
            .padding(6)
        }
        .glassCard(cornerRadius: 26)
    }
}
