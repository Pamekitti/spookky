import Foundation
import SpookkyCore

// Version-dependent local Code storage, isolated from catalog reconciliation.
// The CLI has no metadata-list command. Read only bounded heads/tails, never messages.
struct ClaudeHistoryReader: Sendable {
    struct Cached: Sendable {
        let size: Int
        let modified: Date
        let metadata: ConversationMetadata?
    }
    var cache: [String: Cached] = [:]
    private struct FileRecord: Sendable {
        let url: URL
        let size: Int
        let modified: Date
    }
    private struct Cursor: Codable {
        let modified: Date
        let path: String
    }
    private var files: [FileRecord] = []
    private var indexedRoot: String?
    private var indexedAt = Date.distantPast
    private var indexIssues: [SessionCatalogIssue] = []
    private var indexTruncated = false

    mutating func invalidateIndex() { indexedAt = .distantPast }

    mutating func page(root: URL, query: HistoryQuery, cursor: String? = nil, force: Bool = false) -> HistoryPage {
        index(root: root, force: force)
        var issues = indexIssues
        let position: Cursor?
        if let cursor {
            guard let bytes = Data(base64Encoded: cursor), let value = try? JSONDecoder().decode(Cursor.self, from: bytes) else {
                return HistoryPage(conversations: [], issues: [SessionCatalogIssue(.claude, "This history page expired. Refresh conversations and retry.")], truncated: true)
            }
            position = value
        } else { position = nil }
        var startIndex = 0
        if let position {
            var end = files.count
            while startIndex < end {
                let middle = startIndex + (end - startIndex) / 2, file = files[middle]
                if file.modified > position.modified || (file.modified == position.modified && file.url.path <= position.path) {
                    startIndex = middle + 1
                } else { end = middle }
            }
        }
        var entries: [ConversationMetadata] = [], inspected = 0, last: FileRecord?
        let start = ProcessInfo.processInfo.systemUptime
        for file in files.dropFirst(startIndex) {
            if Task.isCancelled || inspected >= 256 || ProcessInfo.processInfo.systemUptime - start >= 2 { break }
            inspected += 1; last = file
            do {
                if let item = try observe(file) {
                    if query.matches(item) { entries.append(item) }
                } else { issues.append(SessionCatalogIssue(.claude, "A local history file has no usable session metadata.")) }
            } catch { issues.append(SessionCatalogIssue(.claude, "A local history file could not be read.")) }
            if entries.count >= query.limit { break }
        }
        let more = inspected < files.count - startIndex
        let nextCursor = more ? last.flatMap { try? JSONEncoder().encode(Cursor(modified: $0.modified, path: $0.url.path)).base64EncodedString() } : nil
        return HistoryPage(conversations: entries, nextCursor: nextCursor, issues: unique(issues),
            truncated: indexTruncated || (more && entries.count < query.limit))
    }

    mutating func read(root: URL, limit: Int = 5_000) -> SessionCatalogSnapshot {
        index(root: root, force: true, limit: limit)
        var entries: [ConversationMetadata] = [], issues = indexIssues
        for file in files.prefix(max(0, limit)) {
            if Task.isCancelled { break }
            do {
                if let item = try observe(file) { entries.append(item) }
                else { issues.append(SessionCatalogIssue(.claude, "A local history file has no usable session metadata.")) }
            }
            catch { issues.append(SessionCatalogIssue(.claude, "A local history file could not be read.")) }
        }
        return SessionCatalogSnapshot(conversations: entries, issues: unique(issues), truncated: indexTruncated)
    }

    private mutating func index(root: URL, force: Bool, limit: Int = 20_000) {
        let root = root.standardizedFileURL
        if !force, root.path == indexedRoot, Date().timeIntervalSince(indexedAt) < 30 { return }
        if root.path != indexedRoot { cache = [:]; files = [] }
        indexedRoot = root.path; indexedAt = Date()
        let fm = FileManager.default, start = ProcessInfo.processInfo.systemUptime
        guard fm.fileExists(atPath: root.path) else {
            cache = [:]; files = []; indexTruncated = false
            indexIssues = [SessionCatalogIssue(.claude, "No local Claude Code history folder is available.")]
            return
        }
        var issues: [SessionCatalogIssue] = [], observed: [FileRecord] = [], visited = Set<String>(), count = 0, truncated = false
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var enumerationFailed = false
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return false }) else {
            indexIssues = [SessionCatalogIssue(.claude, "Claude Code history could not be read.")]; indexTruncated = true
            return
        }
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime - start > 4 || count >= limit { truncated = true; break }
            if enumerator.level > 2 { enumerator.skipDescendants(); continue }
            guard enumerator.level == 2, url.pathExtension == "jsonl", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
            count += 1; visited.insert(url.path)
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, let modified = values.contentModificationDate else { continue }
                observed.append(FileRecord(url: url, size: size, modified: modified))
            } catch { issues.append(SessionCatalogIssue(.claude, "A local history file could not be inspected.")) }
        }
        if enumerationFailed { issues.append(SessionCatalogIssue(.claude, "Some Claude Code history folders could not be read.")) }
        if truncated {
            issues.append(SessionCatalogIssue(.claude, "Claude Code history indexing reached its file or time limit. Some older conversations require the provider's native history."))
        }
        if !truncated && !enumerationFailed { cache = cache.filter { visited.contains($0.key) } }
        else { observed += files.filter { !visited.contains($0.url.path) } }
        files = observed.sorted { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified }
        if files.count > 20_000 { files = Array(files.prefix(20_000)) }
        if cache.count > 20_000 {
            let retained = Set(files.map { $0.url.path }); cache = cache.filter { retained.contains($0.key) }
        }
        indexIssues = issues; indexTruncated = truncated || enumerationFailed
    }

    private mutating func observe(_ file: FileRecord) throws -> ConversationMetadata? {
        let item: ConversationMetadata?
        if let cached = cache[file.url.path], cached.size == file.size, cached.modified == file.modified { return cached.metadata }
        let observed = try Self.metadata(url: file.url, size: file.size, modified: file.modified)
        if let observed, observed.title == nil, let title = cache[file.url.path]?.metadata?.title {
            item = ConversationMetadata(id: observed.id, title: title, directory: observed.directory,
                updatedAt: observed.updatedAt, source: observed.source, historyPath: observed.historyPath)
        } else { item = observed }
        cache[file.url.path] = Cached(size: file.size, modified: file.modified, metadata: item)
        return item
    }

    private func unique(_ issues: [SessionCatalogIssue]) -> [SessionCatalogIssue] {
        Array(Set(issues.map(\.message))).sorted().map { SessionCatalogIssue(.claude, $0) }
    }
    static func metadata(url: URL, size: Int, modified: Date) throws -> ConversationMetadata? {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let window = 32_768
        let head = try handle.read(upToCount: window) ?? Data()
        var chunks = [head]
        if size > window {
            try handle.seek(toOffset: UInt64(max(window, size - window)))
            let tail = try handle.read(upToCount: window) ?? Data()
            // The first tail line can be a partial record.
            if let newline = tail.firstIndex(of: 10) { chunks.append(Data(tail.suffix(from: tail.index(after: newline)))) }
        }
        let id = url.deletingPathExtension().lastPathComponent
        var cwd: String?, title: String?
        for chunk in chunks {
            for line in chunk.split(separator: 10) {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      row["sessionId"] as? String == id else { continue }
                if row["isSidechain"] as? Bool == true { return nil }
                if cwd == nil, let value = row["cwd"] as? String, value.hasPrefix("/"), !value.contains("\0") { cwd = value }
                if row["type"] as? String == "custom-title", let value = row["customTitle"] as? String { title = value }
                if row["type"] as? String == "summary", title == nil { title = row["summary"] as? String }
            }
        }
        guard let cwd else { return nil }
        return ConversationMetadata(id: ConversationID(provider: .claude, sessionID: id), title: title,
            directory: cwd, updatedAt: modified, source: "local Code", historyPath: url.path)
    }
}
