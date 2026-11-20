import Foundation

/// Something the agent is allowed to act on — always discovered by Cleaner itself, never invented by the AI.
struct AgentCandidate: Identifiable, Hashable {
    let id: String
    let url: URL
    let size: Int64
    let label: String
    let owner: AppOwner?
    let safety: Safety
    let permanent: Bool
}

struct AgentAction: Identifiable, Hashable {
    let candidate: AgentCandidate
    let reason: String
    let risk: Safety
    var selected: Bool
    var id: String { candidate.id }
}

struct AgentPlan: Hashable {
    var actions: [AgentAction]
    var tasks: [String]
    var state: State = .proposed
    var resultText: String?

    enum State: Hashable { case proposed, running, done, cancelled }

    var selectedSize: Int64 { actions.filter(\.selected).reduce(0) { $0 + $1.candidate.size } }
}

struct AgentTurn: Identifiable, Hashable {
    enum Role: Hashable { case user, agent }
    let id = UUID()
    let role: Role
    var text: String
    var plan: AgentPlan?
}

/// "Tell me what to clean and I'll do it": natural language → validated plan → one-click execution.
@MainActor
final class AgentModel: ObservableObject {
    @Published private(set) var turns: [AgentTurn] = []
    @Published var input = ""
    @Published private(set) var isWorking = false
    @Published private(set) var status = ""

    private var candidates: [String: AgentCandidate] = [:]

    static let suggestions = [
        "Clean all browser caches (Chrome, Brave, Safari)",
        "Free up 10 GB but don't touch my projects or documents",
        "Delete leftovers of apps I've already uninstalled",
        "Remove developer junk: npm, Gradle, Homebrew and build folders",
        "Delete old screenshots and installers in Downloads",
        "Clean VS Code caches and old extension versions",
    ]

    static let allowedTasks: [String: String] = [
        "brew": "Homebrew Cleanup", "dns": "Flush DNS Cache", "purge": "Flush File Cache (RAM)",
        "thin": "Thin Time Machine Snapshots", "simctl": "Remove Unavailable Simulators",
        "quicklook": "Reset Quick Look", "launchservices": "Rebuild Launch Services",
    ]

    func clear() {
        turns = []
        candidates = [:]
    }

    // MARK: Asking

    func send(state: AppState) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isWorking else { return }
        input = ""
        turns.append(AgentTurn(role: .user, text: text))
        isWorking = true
        Task {
            await prepareInventory(state)
            status = "Planning with \(AISettings.shared.activeProvider.shortName)…"
            do {
                let (reply, plan) = try await plan(for: text)
                turns.append(AgentTurn(role: .agent, text: reply, plan: plan))
            } catch {
                turns.append(AgentTurn(role: .agent, text: "⚠️ \(error.localizedDescription)"))
            }
            status = ""
            isWorking = false
        }
    }

    /// Makes sure Cleaner has looked around the Mac, then builds the list of allowed items.
    private func prepareInventory(_ state: AppState) async {
        if state.junk.results.isEmpty && state.junk.lastScan == nil {
            status = "Running Smart Scan…"
            state.junk.scan()
        }
        if state.appStorage.footprints.isEmpty {
            status = "Measuring apps (first time takes about a minute)…"
            state.appStorage.scan()
        }
        while state.junk.isScanning || state.appStorage.isScanning {
            try? await Task.sleep(for: .milliseconds(400))
            if state.appStorage.isScanning { status = "Measuring apps… \(state.appStorage.status)" }
        }
        candidates = Self.buildInventory(state)
    }

    static func buildInventory(_ state: AppState) -> [String: AgentCandidate] {
        var list: [(URL, Int64, String, AppOwner?, Safety, Bool)] = []
        var seen = Set<String>()
        func add(_ u: URL, _ size: Int64, _ label: String, _ owner: AppOwner?, _ safety: Safety, _ permanent: Bool = false) {
            guard size > 0, seen.insert(u.path).inserted, SafetyGuard.blockReason(for: u) == nil else { return }
            list.append((u, size, label, owner, safety, permanent))
        }
        let resolver = AppOwnerResolver.shared
        for r in state.junk.results {
            for i in r.items { add(i.url, i.size, "Smart Scan · \(r.rule.title)", resolver.owner(for: i.url), r.rule.safety, r.rule.permanent) }
        }
        for f in state.appStorage.footprints {
            for i in f.items where (i.size ?? 0) >= 2_000_000 {
                let safety: Safety = i.cleanable ? .safe : (i.kind == "Sandbox container" ? .caution : .review)
                add(i.url, i.size ?? 0, "\(f.owner.name) · \(i.kind)\(f.owner.installed ? "" : " (app not installed)")", f.owner, safety)
            }
            if let b = f.appBundle, let s = f.appSize, s >= 30_000_000 {
                add(b, s, "Application · \(f.owner.name) (last opened \(Fmt.relative(AppCatalog.lastUsed(b))))", f.owner, .caution)
            }
        }
        for f in state.largeFiles.files.prefix(60) { add(f.url, f.size, "Large file (modified \(Fmt.date(f.modified)))", nil, .review) }
        for g in state.duplicates.groups.prefix(40) {
            for f in g.files.dropFirst() { add(f.url, g.size, "Duplicate copy of \(g.files[0].url.lastPathComponent)", nil, .safe) }
        }

        let top = list.sorted { $0.1 > $1.1 }.prefix(400)
        var out: [String: AgentCandidate] = [:]
        for (i, c) in top.enumerated() {
            let id = "c\(i + 1)"
            out[id] = AgentCandidate(id: id, url: c.0, size: c.1, label: c.2, owner: c.3, safety: c.4, permanent: c.5)
        }
        return out
    }

    private func plan(for request: String) async throws -> (String, AgentPlan?) {
        let sorted = candidates.values.sorted { $0.size > $1.size }
        var inventory = ""
        for c in sorted {
            inventory += "\(c.id) | \(Fmt.bytes(c.size)) | \(c.label) | `\(c.url.displayPath)` | \(c.safety.label)\n"
        }
        let tasks = Self.allowedTasks.map { "\($0.key) = \($0.value)" }.sorted().joined(separator: ", ")
        let system = """
        You are Cleaner's cleanup agent. The user tells you in plain language what to remove from their Mac. \
        You may ONLY choose items from the inventory by id, and maintenance tasks from this list: \(tasks).
        Rules:
        - Pick exactly what the request covers; don't add unrelated items. If the user asks to free an amount of space, pick the safest items first until you reach it.
        - Rate each action's risk honestly: "safe" (caches/logs/rebuildable), "review" (data the user may want), "caution" (app data with logins/documents, whole apps).
        - Never pick items that look like documents, photos, projects' source code, or credentials unless the user explicitly asks.
        - Items go to the Trash (recoverable) except ones already in the Trash.
        - If nothing matches, return no actions and say why. If the request is unclear, ask one short question.
        Reply with ONLY a JSON object:
        {"reply": "1–3 friendly sentences describing the plan and total size", "actions": [{"id": "c12", "reason": "short why", "risk": "safe"}], "tasks": ["brew"]}
        """
        var history: [ChatMessage] = []
        for t in turns.dropLast().suffix(6) {
            history.append(ChatMessage(role: t.role == .user ? .user : .assistant, text: t.text))
        }
        let prompt = "Inventory (id | size | what | path | rating):\n\(inventory)\nUser request: \(request)"
        let raw = try await AIService.complete(kind: AISettings.shared.activeProvider,
                                               model: AISettings.shared.model(for: AISettings.shared.activeProvider),
                                               system: Prompts.system + "\n\n" + system,
                                               messages: history + [ChatMessage(role: .user, text: prompt)], maxTokens: 4000)
        guard let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"),
              let data = String(raw[s...e]).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (raw, nil)   // The AI answered in prose (e.g. a question) — show it as-is.
        }
        let reply = json["reply"] as? String ?? ""
        var actions: [AgentAction] = []
        var dropped = 0
        for a in json["actions"] as? [[String: Any]] ?? [] {
            guard let id = a["id"] as? String, let c = candidates[id],
                  SafetyGuard.blockReason(for: c.url) == nil else { dropped += 1; continue }
            let aiRisk: Safety = { switch (a["risk"] as? String ?? "").lowercased() {
                case "safe": .safe
                case "caution": .caution
                default: .review } }()
            // Never let the AI rate something safer than Cleaner's own rules do.
            let risk = [aiRisk, c.safety].max { $0.rank < $1.rank } ?? aiRisk
            if !actions.contains(where: { $0.id == id }) {
                actions.append(AgentAction(candidate: c, reason: a["reason"] as? String ?? "", risk: risk, selected: risk != .caution))
            }
        }
        let taskIDs = (json["tasks"] as? [String] ?? []).filter { Self.allowedTasks[$0] != nil }
        var text = reply
        if dropped > 0 { text += "\n\n(\(dropped) suggestion(s) were ignored because they weren't valid or are protected.)" }
        if actions.isEmpty && taskIDs.isEmpty { return (text.isEmpty ? "I didn't find anything matching that." : text, nil) }
        return (text, AgentPlan(actions: actions.sorted { $0.candidate.size > $1.candidate.size }, tasks: taskIDs))
    }

    // MARK: Executing

    func toggle(_ actionID: String, in turnID: UUID) {
        guard let t = turns.firstIndex(where: { $0.id == turnID }),
              let a = turns[t].plan?.actions.firstIndex(where: { $0.id == actionID }) else { return }
        turns[t].plan?.actions[a].selected.toggle()
    }

    func cancel(_ turnID: UUID) {
        guard let t = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[t].plan?.state = .cancelled
    }

    func execute(_ turnID: UUID, state: AppState) {
        guard let t = turns.firstIndex(where: { $0.id == turnID }), let plan = turns[t].plan, plan.state == .proposed else { return }
        turns[t].plan?.state = .running
        let targets = plan.actions.filter(\.selected).map { CleanTarget(url: $0.candidate.url, size: $0.candidate.size, permanent: $0.candidate.permanent) }
        Task {
            let report = await Task.detached { Cleaner.remove(targets) }.value
            for u in report.removed {
                SizeIndex.shared.invalidate(u)
                state.appStorage.removeItem(u)
            }
            state.junk.forget(Set(report.removed))
            var lines = ["Done. Moved \(report.removed.count) item(s) — \(Fmt.bytes(report.trashed + report.freed))\(report.trashed > 0 ? " — to the Trash (empty it to get the space back)" : "")."]
            if !report.failures.isEmpty {
                lines.append("\(report.failures.count) skipped: " + report.failures.prefix(3).map { "\($0.url.lastPathComponent) (\($0.reason))" }.joined(separator: "; "))
            }
            for id in plan.tasks {
                guard let task = MaintenanceModel.tasks.first(where: { $0.id == id }) else { continue }
                let r = await Task.detached { task.admin ? Shell.runAdmin(task.command) : Shell.sh(task.command) }.value
                lines.append(r.ok ? "✓ \(task.title)" : "✗ \(task.title) didn't finish (\(r.err.contains("-128") ? "cancelled" : "error"))")
            }
            state.refreshStats()
            if let i = turns.firstIndex(where: { $0.id == turnID }) {
                turns[i].plan?.state = .done
                turns[i].plan?.resultText = lines.joined(separator: "\n")
            }
        }
    }
}

extension Safety {
    var rank: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .caution: 2
        }
    }
}
