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
    mutating func read(root: URL, limit: Int = 5_000) -> SessionCatalogSnapshot {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default, start = ProcessInfo.processInfo.systemUptime
        guard fm.fileExists(atPath: root.path) else {
            cache = [:]
            return SessionCatalogSnapshot(conversations: [], issues: [SessionCatalogIssue(.claude, "No local Claude Code history folder is available.")])
        }
        var issues: [SessionCatalogIssue] = [], entries: [ConversationMetadata] = [], visited = Set<String>(), count = 0, truncated = false
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var enumerationFailed = false
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return false }) else {
            return SessionCatalogSnapshot(conversations: [], issues: [SessionCatalogIssue(.claude, "Claude Code history could not be read.")])
        }
        while let url = enumerator.nextObject() as? URL {
            if ProcessInfo.processInfo.systemUptime - start > 4 || count >= limit { truncated = true; break }
            if enumerator.level > 2 { enumerator.skipDescendants(); continue }
            guard enumerator.level == 2, url.pathExtension == "jsonl", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { continue }
            count += 1; visited.insert(url.path)
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, let modified = values.contentModificationDate else { continue }
                let item: ConversationMetadata?
                if let cached = cache[url.path], cached.size == size, cached.modified == modified { item = cached.metadata }
                else {
                    let observed = try Self.metadata(url: url, size: size, modified: modified)
                    if let observed, observed.title == nil, let title = cache[url.path]?.metadata?.title {
                        item = ConversationMetadata(id: observed.id, title: title, directory: observed.directory,
                            updatedAt: observed.updatedAt, source: observed.source, historyPath: observed.historyPath)
                    } else { item = observed }
                    cache[url.path] = Cached(size: size, modified: modified, metadata: item)
                }
                if let item { entries.append(item) }
                else { issues.append(SessionCatalogIssue(.claude, "A local history file has no usable session metadata.")) }
            } catch { issues.append(SessionCatalogIssue(.claude, "A local history file could not be read.")) }
        }
        if enumerationFailed { issues.append(SessionCatalogIssue(.claude, "Some Claude Code history folders could not be read.")) }
        cache = cache.filter { visited.contains($0.key) }
        return SessionCatalogSnapshot(conversations: entries, issues: Array(Set(issues.map(\.message))).sorted().map { SessionCatalogIssue(.claude, $0) }, truncated: truncated)
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
