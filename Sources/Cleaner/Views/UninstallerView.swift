import SwiftUI
import AppKit

struct UninstallerView: View {
    @EnvironmentObject var ai: AISettings
    @ObservedObject var model: UninstallerModel
    @Local private var query: AIQuery?
    @Local private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Uninstaller", subtitle: "Remove apps together with their caches, preferences, containers and helpers.") {
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload apps")
            }
            .padding(20)
            Divider()

            HStack(spacing: 0) {
                appList.frame(width: 320)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.load() }
        .sheet(item: $query) { q in AIResponseSheet(query: q, ai: ai) }
        .confirmationDialog("Uninstall \(model.selectedApp?.name ?? "")?", isPresented: $confirm) {
            Button("Move App & \(model.leftoverSelection.count) Leftovers to Trash", role: .destructive) { model.uninstall() }
        } message: {
            Text("The app and the selected related files will be moved to the Trash.")
        }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(model.filteredApps, selection: $model.selectedID) { app in
                HStack(spacing: 10) {
                    FileIcon(url: app.url, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).lineLimit(1)
                        Text("Opened \(Fmt.relative(app.lastUsed))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(app.size.map(Fmt.bytes) ?? "…").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .tag(app.url)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let app = model.selectedApp {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    FileIcon(url: app.url, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title2.bold())
                        Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Last opened \(Fmt.relative(app.lastUsed)) · \(app.size.map(Fmt.bytes) ?? "measuring…")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        query = AIQuery(title: app.name, prompt: Prompts.app(app, leftovers: model.leftovers))
                    } label: { Label("Ask AI", systemImage: "sparkles") }
                }

                Text("Related files").font(.headline)
                if model.isFindingLeftovers {
                    HStack { ProgressView().controlSize(.small); Text("Searching Library folders…").foregroundStyle(.secondary) }
                } else if model.leftovers.isEmpty {
                    Text("No related files found.").foregroundStyle(.secondary)
                } else {
                    List(model.leftovers) { item in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { model.leftoverSelection.contains(item.url) },
                                set: { if $0 { model.leftoverSelection.insert(item.url) } else { model.leftoverSelection.remove(item.url) } }
                            ))
                            .toggleStyle(.checkbox).labelsHidden()
                            FileIcon(url: item.url, size: 16)
                            Text(item.url.displayPath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contextMenu { Button("Reveal in Finder") { item.url.revealInFinder() } }
                    }
                    .listStyle(.bordered)
                }

                if let msg = model.message {
                    Text(msg).font(.callout).foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
                HStack {
                    Text("Total: \(Fmt.bytes((app.size ?? 0) + model.leftoverSize))").monospacedDigit()
                    Spacer()
                    if model.isRunning(app) {
                        Button("Quit \(app.name)") { model.quit(app) }
                    }
                    Button("Uninstall") { confirm = true }
                        .glassButton(prominent: true)
                        .tint(.red)
                        .disabled(model.isFindingLeftovers)
                }
            }
            .padding(20)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "xmark.app").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Select an app to see everything it installed.").foregroundStyle(.secondary)
                if let msg = model.message { Text(msg).font(.callout).foregroundStyle(.secondary).padding(.top, 6) }
            }
            .padding()
        }
    }
}
