import Foundation

@MainActor
final class JunkScanner: ObservableObject {
    @Published private(set) var results: [CategoryResult] = []
    @Published var selected: Set<URL> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var status = ""
    @Published private(set) var lastScan: Date?
    @Published var lastReport: CleanReport?

    private var scanTask: Task<Void, Never>?

    var totalFound: Int64 { results.reduce(0) { $0 + $1.total } }
    var selectedSize: Int64 {
        results.flatMap(\.items).filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size }
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        results = []
        selected = []
        lastReport = nil
        status = "Preparing…"
        let context = ScanContext.current()

        scanTask = Task {
            var collected: [CategoryResult] = []
            await withTaskGroup(of: CategoryResult?.self) { group in
                for rule in CleanupRules.all {
                    group.addTask { RuleEvaluator.evaluate(rule, context: context) }
                }
                for await result in group {
                    guard let result else { continue }
                    collected.append(result)
                    status = "Found \(result.rule.title)"
                    results = Self.dedupe(collected)
                }
            }
            results = Self.dedupe(collected)
            selected = Set(results.filter { $0.rule.selectedByDefault }.flatMap { $0.items.map(\.url) })
            lastScan = Date()
            status = results.isEmpty ? "Nothing to clean" : "Scan complete"
            isScanning = false
        }
    }

    func stop() {
        scanTask?.cancel()
        isScanning = false
        status = "Stopped"
    }

    func clean() {
        let targets = results.flatMap { r in
            r.items.filter { selected.contains($0.url) }
                .map { CleanTarget(url: $0.url, size: $0.size, permanent: r.rule.permanent) }
        }
        guard !targets.isEmpty else { return }
        isCleaning = true
        Task {
            let report = await Task.detached { Cleaner.remove(targets) }.value
            apply(report)
            isCleaning = false
        }
    }

    func emptyTrash() {
        isCleaning = true
        Task {
            let report = await Task.detached { Cleaner.emptyTrash() }.value
            var merged = lastReport ?? CleanReport()
            merged.freed += report.freed
            merged.trashed = 0
            lastReport = merged
            results.removeAll { $0.rule.id == "trash" }
            isCleaning = false
        }
    }

    private func apply(_ report: CleanReport) {
        let removed = Set(report.removed)
        results = results
            .map { var r = $0; r.items.removeAll { removed.contains($0.url) }; return r }
            .filter { !$0.isEmpty }
        selected.subtract(removed)
        lastReport = report
    }

    /// Specific rules win over catch-all rules (e.g. Homebrew cache vs. "all user caches"),
    /// then results are ordered as declared in CleanupRules.
    private static func dedupe(_ results: [CategoryResult]) -> [CategoryResult] {
        let claimed = Set(results.filter { !$0.rule.catchAll }.flatMap { $0.items.map(\.url) })
        let order = Dictionary(uniqueKeysWithValues: CleanupRules.all.enumerated().map { ($1.id, $0) })
        return results
            .map { r in
                guard r.rule.catchAll else { return r }
                var c = r
                c.items.removeAll { claimed.contains($0.url) }
                return c
            }
            .filter { !$0.isEmpty }
            .sorted { (order[$0.rule.id] ?? 0) < (order[$1.rule.id] ?? 0) }
    }
}
