import Foundation

struct PlannedMove: Identifiable, Hashable {
    let source: URL
    let folder: String
    let size: Int64
    var id: URL { source }
}

struct MoveRecord: Codable {
    let from: String
    let to: String
}

@MainActor
final class OrganizerModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case type = "By type"
        case month = "By month"
        case typeMonth = "By type, then month"
        case ai = "AI suggestion"
        var id: String { rawValue }
    }

    @Published var source: URL = Paths.home.appendingPathComponent("Downloads") {
        didSet { if source != oldValue { plan = []; excludedFolders = [] } }
    }
    @Published var mode: Mode = .type { didSet { if mode != oldValue { plan = [] } } }
    @Published private(set) var plan: [PlannedMove] = []
    @Published var excludedFolders: Set<String> = []
    @Published private(set) var isPlanning = false
    @Published private(set) var isApplying = false
    @Published var message: String?
    @Published private(set) var canUndo = FileManager.default.fileExists(atPath: OrganizerModel.undoFile.path)

    static let undoFile: URL = CleanupLog.shared.fileURL.deletingLastPathComponent().appendingPathComponent("organizer-undo.json")

    var folders: [(name: String, moves: [PlannedMove])] {
        Dictionary(grouping: plan, by: \.folder)
            .map { ($0.key, $0.value.sorted { $0.source.lastPathComponent.localizedStandardCompare($1.source.lastPathComponent) == .orderedAscending }) }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }
    var activeMoves: [PlannedMove] { plan.filter { !excludedFolders.contains($0.folder) } }

    // MARK: Categories

    nonisolated static let typeFolders: [(String, Set<String>)] = [
        ("Images", ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "svg", "bmp", "tif", "tiff", "raw", "cr2", "nef", "dng", "avif", "ico"]),
        ("Videos", ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv"]),
        ("Audio", ["mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff", "opus"]),
        ("PDFs", ["pdf"]),
        ("Documents", ["doc", "docx", "txt", "rtf", "md", "pages", "odt", "epub", "tex"]),
        ("Spreadsheets", ["xls", "xlsx", "csv", "tsv", "numbers", "ods"]),
        ("Presentations", ["ppt", "pptx", "key", "odp"]),
        ("Archives", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]),
        ("Installers", ["dmg", "pkg", "mpkg", "iso", "xip", "apk", "aab", "ipa", "exe", "msi"]),
        ("Code", ["js", "ts", "tsx", "jsx", "py", "swift", "java", "kt", "html", "css", "json", "xml", "yml", "yaml",
                  "sh", "rb", "go", "rs", "php", "c", "cpp", "h", "sql", "ipynb", "vcf"]),
        ("Design", ["psd", "ai", "fig", "sketch", "xd", "indd", "afdesign", "afphoto"]),
        ("Fonts", ["ttf", "otf", "woff", "woff2"]),
    ]

    nonisolated static func typeFolder(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return typeFolders.first { $0.1.contains(ext) }?.0 ?? "Other"
    }

    nonisolated static func monthFolder(for date: Date?) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM MMMM"
        return f.string(from: date ?? Date())
    }

    // MARK: Planning

    /// Loose files only (folders are left alone), skipping hidden files and downloads in progress.
    nonisolated static func candidates(in folder: URL) -> [(url: URL, size: Int64, date: Date?)] {
        let partial: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]
        let recent = Date().addingTimeInterval(-120)
        return Paths.children(of: folder).compactMap { u in
            guard !u.lastPathComponent.hasPrefix("."),
                  let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .totalFileAllocatedSizeKey,
                                                          .contentModificationDateKey, .creationDateKey]),
                  v.isRegularFile == true || v.isPackage == true,
                  !partial.contains(u.pathExtension.lowercased()) else { return nil }
            if let m = v.contentModificationDate, m > recent { return nil }
            return (u, Int64(v.totalFileAllocatedSize ?? 0), v.creationDate ?? v.contentModificationDate)
        }
    }

    func makePlan() {
        isPlanning = true
        message = nil
        excludedFolders = []
        let folder = source, mode = mode
        Task {
            let files = await Task.detached { Self.candidates(in: folder) }.value
            guard !files.isEmpty else {
                plan = []
                message = "No loose files to organize in \(folder.displayPath)."
                isPlanning = false
                return
            }
            switch mode {
            case .type:
                plan = files.map { PlannedMove(source: $0.url, folder: Self.typeFolder(for: $0.url), size: $0.size) }
            case .month:
                plan = files.map { PlannedMove(source: $0.url, folder: Self.monthFolder(for: $0.date), size: $0.size) }
            case .typeMonth:
                plan = files.map { PlannedMove(source: $0.url, folder: "\(Self.typeFolder(for: $0.url))/\(Self.monthFolder(for: $0.date))", size: $0.size) }
            case .ai:
                await planWithAI(files)
            }
            plan.removeAll { $0.folder.isEmpty }
            isPlanning = false
        }
    }

    private func planWithAI(_ files: [(url: URL, size: Int64, date: Date?)]) async {
        let sample = Array(files.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(250))
        var prompt = """
        Organize the loose files in my folder `\(source.displayPath)` into a small set of clear subfolders \
        (5–12 folders, grouped by project, client, topic or purpose — use file types only as a fallback). \
        Reply with ONLY a JSON object mapping folder names to arrays of exact file names, e.g. \
        {"Invoices": ["a.pdf"], "Website Assets": ["logo.png"]}. Use each file name exactly once. \
        Folder names: short, Title Case, no slashes.

        Files (name — size — date):

        """
        for f in sample { prompt += "\(f.url.lastPathComponent) — \(Fmt.bytes(f.size)) — \(Fmt.date(f.date))\n" }
        do {
            let reply = try await AIService.ask(prompt)
            guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
                  let data = String(reply[start...end]).data(using: .utf8),
                  let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String]] else {
                message = "The AI's answer wasn't in the expected format. Try again or use “By type”."
                plan = []
                return
            }
            let byName = Dictionary(sample.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
            var moves: [PlannedMove] = []
            var used = Set<String>()
            for (rawFolder, names) in map {
                let folder = Self.sanitize(rawFolder)
                guard !folder.isEmpty else { continue }
                for n in names where !used.contains(n) {
                    guard let f = byName[n] else { continue }
                    used.insert(n)
                    moves.append(PlannedMove(source: f.url, folder: folder, size: f.size))
                }
            }
            plan = moves
            let skipped = files.count - moves.count
            message = skipped > 0 ? "\(skipped) file(s) weren't placed by the AI and will stay where they are." : nil
        } catch {
            message = error.localizedDescription
            plan = []
        }
    }

    nonisolated static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return String(s.prefix(60))
    }

    // MARK: Applying & undo

    func apply() {
        let moves = activeMoves
        guard !moves.isEmpty else { return }
        isApplying = true
        let base = source
        Task {
            let (done, failed) = await Task.detached { Self.perform(moves, base: base) }.value
            if let data = try? JSONEncoder().encode(done) { try? data.write(to: Self.undoFile) }
            canUndo = !done.isEmpty
            message = "Moved \(done.count) file(s) into \(Set(moves.map(\.folder)).count) folder(s)."
                + (failed.isEmpty ? "" : " \(failed.count) couldn't be moved (\(failed.first ?? "")).")
            plan = []
            isApplying = false
        }
    }

    nonisolated static func perform(_ moves: [PlannedMove], base: URL) -> ([MoveRecord], [String]) {
        let fm = FileManager.default
        var done: [MoveRecord] = [], failed: [String] = []
        for m in moves {
            let dir = base.appendingPathComponent(m.folder, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = uniqueDestination(dir.appendingPathComponent(m.source.lastPathComponent))
                try fm.moveItem(at: m.source, to: dest)
                done.append(MoveRecord(from: m.source.path, to: dest.path))
            } catch {
                failed.append("\(m.source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (done, failed)
    }

    /// Moves files back to where they were and removes organizer folders that became empty.
    nonisolated static func restore(_ records: [MoveRecord]) -> Int {
            let fm = FileManager.default
            var n = 0
            var touchedDirs = Set<String>()
            for r in records.reversed() where fm.fileExists(atPath: r.to) && !fm.fileExists(atPath: r.from) {
                if (try? fm.moveItem(atPath: r.to, toPath: r.from)) != nil {
                    n += 1
                    touchedDirs.insert((r.to as NSString).deletingLastPathComponent)
                }
            }
            // Remove folders the organizer created if they're now empty (deepest first),
            // never climbing to or above the folder that was organized.
            let bases = Set(records.map { ($0.from as NSString).deletingLastPathComponent })
            for d in touchedDirs.sorted(by: { $0.count > $1.count }) {
                var dir = d
                while !bases.contains(dir), bases.contains(where: { dir.hasPrefix($0 + "/") }),
                      let items = try? fm.contentsOfDirectory(atPath: dir),
                      items.allSatisfy({ $0 == ".DS_Store" }) {
                    try? fm.removeItem(atPath: dir)
                    dir = (dir as NSString).deletingLastPathComponent
                }
            }
            return n
        }

    nonisolated private static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for i in 2...999 {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent(ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    func undo() {
        guard let data = try? Data(contentsOf: Self.undoFile),
              let records = try? JSONDecoder().decode([MoveRecord].self, from: data) else { return }
        isApplying = true
        Task {
            let restored = await Task.detached { Self.restore(records) }.value
            try? FileManager.default.removeItem(at: Self.undoFile)
            canUndo = false
            message = "Undo complete: \(restored) file(s) moved back."
            isApplying = false
        }
    }
}
