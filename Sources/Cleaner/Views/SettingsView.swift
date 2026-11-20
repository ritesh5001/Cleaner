import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var ai: AISettings
    @EnvironmentObject var state: AppState
    @AppStorage("deletePermanently") private var deletePermanently = false
    @Local private var exclusions: [String] = SafetyGuard.excludedPaths

    var body: some View {
        Form {
            Section {
                Picker("Use for AI features", selection: $ai.activeProvider) {
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu)
                if !ai.isReady {
                    Label("\(ai.activeProvider.shortName) isn't set up yet — see below.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
            } header: {
                Text("AI provider")
            } footer: {
                Text("Every Mac user connects their own AI: a Claude subscription through their own Claude Code login, a Google account through Gemini CLI, or a pay-as-you-go API key stored in their Keychain.")
            }

            ForEach(AIProviderKind.allCases) { kind in
                ProviderSection(kind: kind)
            }

            Section("Privacy") {
                Toggle("When explaining a folder, include the names of items inside it", isOn: $ai.shareFolderListings)
                Text("Cleaner sends paths (your home folder appears as ~), sizes and dates. It never uploads the contents of your files.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Cleaning") {
                Toggle("Delete permanently instead of moving to Trash", isOn: $deletePermanently)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Never touch these folders")
                        Spacer()
                        Button("Add…") { addExclusion() }
                    }
                    if exclusions.isEmpty {
                        Text("No exclusions.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(exclusions, id: \.self) { p in
                        HStack {
                            Text(Paths.display(URL(fileURLWithPath: p))).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { removeExclusion(p) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                }
                LabeledContent("Cleanup history") {
                    Button("Show in Finder") { CleanupLog.shared.fileURL.revealInFinder() }
                }
            }

            Section("Permissions") {
                HStack {
                    Label(state.hasFullDiskAccess ? "Full Disk Access granted" : "Full Disk Access not granted",
                          systemImage: state.hasFullDiskAccess ? "checkmark.shield.fill" : "exclamationmark.shield")
                        .foregroundStyle(state.hasFullDiskAccess ? .green : .orange)
                    Spacer()
                    Button("Open Privacy Settings") { FullDiskAccess.openSettings() }
                }
                Text("Full Disk Access lets Cleaner see Mail, Safari, Trash, iOS backups and other protected app data. macOS system files stay read-only either way (System Integrity Protection).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { exclusions = SafetyGuard.excludedPaths }
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var list = SafetyGuard.excludedPaths
        for url in panel.urls where !list.contains(url.path) { list.append(url.path) }
        SafetyGuard.excludedPaths = list
        exclusions = list
    }

    private func removeExclusion(_ p: String) {
        SafetyGuard.excludedPaths.removeAll { $0 == p }
        exclusions = SafetyGuard.excludedPaths
    }
}

private struct ProviderSection: View {
    let kind: AIProviderKind
    @EnvironmentObject var ai: AISettings
    @Local private var keyInput = ""
    @Local private var modelInput = ""
    @Local private var models: [String] = []
    @Local private var status: String?
    @Local private var busy = false

    var body: some View {
        Section {
            Text(kind.setupHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !kind.usesAPIKey {
                LabeledContent(kind.cliName ?? "CLI") {
                    HStack {
                        if let path = ai.cliPaths[kind] {
                            Label(Paths.display(URL(fileURLWithPath: path)), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).lineLimit(1).truncationMode(.middle)
                        } else {
                            Label("Not found", systemImage: "xmark.circle").foregroundStyle(.secondary)
                        }
                        Button(ai.isDetecting ? "Detecting…" : "Detect") { ai.detectCLIs() }.disabled(ai.isDetecting)
                    }
                }
                if ai.cliPaths[kind] == nil {
                    Link("How to install \(kind.cliName ?? "") →", destination: kind.keyURL).font(.caption)
                }
            } else if let masked = ai.maskedKeys[kind] {
                LabeledContent("API key") {
                    HStack {
                        Text(masked).font(.body.monospaced()).foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) {
                            ai.removeKey(for: kind)
                            status = nil
                            models = []
                        }
                    }
                }
            } else {
                LabeledContent("API key") {
                    HStack {
                        SecureField("", text: $keyInput, prompt: Text(kind.keyPlaceholder))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 240)
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey).disabled(keyInput.isEmpty)
                    }
                }
                Link("Get a \(kind.shortName) API key →", destination: kind.keyURL).font(.caption)
            }

            LabeledContent("Model") {
                HStack {
                    TextField("", text: $modelInput, prompt: Text(kind.defaultModel))
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 220)
                    if !models.isEmpty {
                        Menu("Choose") {
                            ForEach(models, id: \.self) { m in
                                Button(m) { modelInput = m }
                            }
                        }
                        .fixedSize()
                    }
                }
            }

            HStack(spacing: 10) {
                Button(kind.usesAPIKey ? "Fetch available models" : "Show models") { Task { await fetchModels() } }
                Button("Test connection") { Task { await test() } }
                if busy { ProgressView().controlSize(.small) }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            .disabled(!ai.isConfigured(kind) || busy)
        } header: {
            HStack {
                Text(kind.displayName)
                if ai.activeProvider == kind && ai.isConfigured(kind) {
                    Text("ACTIVE").font(.caption2.bold()).foregroundStyle(.green)
                }
            }
        }
        .onAppear { modelInput = ai.modelOverrides[kind.rawValue] ?? "" }
        .onChange(of: modelInput) { _, new in ai.setModel(new, for: kind) }
    }

    private func saveKey() {
        if ai.saveKey(keyInput, for: kind) {
            keyInput = ""
            status = "Saved to Keychain. Testing…"
            Task { await test() }
        } else {
            status = "Couldn't save the key to Keychain."
        }
    }

    private func fetchModels() async {
        busy = true
        defer { busy = false }
        do {
            models = try await AIService.listModels(kind: kind)
            status = models.isEmpty ? "No models returned." : "\(models.count) models available — use Choose."
        } catch {
            status = error.localizedDescription
        }
    }

    private func test() async {
        busy = true
        defer { busy = false }
        let model = ai.model(for: kind)
        do {
            _ = try await AIService.complete(kind: kind, model: model, system: "Reply with the single word OK.",
                                             messages: [ChatMessage(role: .user, text: "ping")], maxTokens: 256)
            status = "✓ Connected (\(model))"
        } catch AIError.empty {
            status = "✓ Connected (\(model))"
        } catch {
            status = error.localizedDescription
        }
    }
}
