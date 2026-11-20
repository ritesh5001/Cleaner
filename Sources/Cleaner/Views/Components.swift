import SwiftUI
import AppKit

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct UsageBar: View {
    struct Segment {
        let fraction: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                    Rectangle()
                        .fill(s.color)
                        .frame(width: max(0, geo.size.width * min(1, s.fraction)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Color.secondary.opacity(0.15))
        .clipShape(Capsule())
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Text(value).monospacedDigit().lineLimit(1)
        }
        .font(.caption)
        .fixedSize()
    }
}

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        Text(safety.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(safety.color)
            .background(safety.color.opacity(0.15), in: Capsule())
    }
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: size, height: size)
    }
}

struct FDABanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grant Full Disk Access for a complete scan").bold()
                Text("Without it macOS hides Mail, Safari, Trash, iOS backups and other apps' data from Cleaner. Open System Settings → Privacy & Security → Full Disk Access and turn on Cleaner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { FullDiskAccess.openSettings() }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CleanReportBanner: View {
    let report: CleanReport
    var onEmptyTrash: (() -> Void)?
    @Local private var showFailures = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(report.failures.isEmpty ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                if report.trashed > 0 {
                    Text("Moved \(Fmt.bytes(report.trashed)) to the Trash. Empty the Trash to get the space back.")
                }
                if report.freed > 0 {
                    Text("Freed \(Fmt.bytes(report.freed)).")
                }
                if report.trashed == 0 && report.freed == 0 && report.failures.isEmpty {
                    Text("Nothing was removed.")
                }
                if !report.failures.isEmpty {
                    Button("\(report.failures.count) item(s) skipped — details") { showFailures = true }
                        .buttonStyle(.link)
                        .popover(isPresented: $showFailures) { failureList }
                }
            }
            .font(.callout)
            Spacer()
            if report.trashed > 0, let onEmptyTrash {
                Button("Empty Trash", role: .destructive, action: onEmptyTrash)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var failureList: some View {
        List(report.failures) { f in
            VStack(alignment: .leading) {
                Text(f.url.displayPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(f.reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 480, height: 300)
    }
}

/// Lightweight Markdown renderer for AI answers (headings, bullets, inline styles).
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Color.clear.frame(height: 2)
        } else if let h = heading(line) {
            Text(inline(h)).font(.headline).padding(.top, 4)
        } else if let b = bullet(line) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(b))
            }
            .padding(.leading, raw.hasPrefix("  ") ? 16 : 0)
        } else if line.hasPrefix("```") {
            EmptyView()
        } else {
            Text(inline(line))
        }
    }

    private func heading(_ s: String) -> String? {
        for p in ["#### ", "### ", "## ", "# "] where s.hasPrefix(p) { return String(s.dropFirst(p.count)) }
        return nil
    }

    private func bullet(_ s: String) -> String? {
        for p in ["- ", "* ", "• "] where s.hasPrefix(p) { return String(s.dropFirst(p.count)) }
        if let dot = s.firstIndex(of: "."), s[s.startIndex..<dot].allSatisfy(\.isNumber), !s[s.startIndex..<dot].isEmpty {
            return s
        }
        return nil
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

// MARK: - AI one-shot sheet

struct AIQuery: Identifiable {
    let id = UUID()
    let title: String
    let prompt: String
}

struct AIResponseSheet: View {
    let query: AIQuery
    @ObservedObject var ai: AISettings
    @Environment(\.dismiss) private var dismiss
    @Local private var answer: String?
    @Local private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(query.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(ai.activeProvider.shortName) · \(ai.model(for: ai.activeProvider))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                Group {
                    if let answer {
                        MarkdownText(text: answer)
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Asking \(ai.activeProvider.shortName)…").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            Divider()
            HStack {
                Text("Only paths, sizes and dates are shared — never file contents.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let answer {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                    }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
        .task { await run() }
    }

    private func run() async {
        guard ai.isReady else {
            error = AIError.missingKey(ai.activeProvider).localizedDescription
            return
        }
        do {
            answer = try await AIService.ask(query.prompt)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
