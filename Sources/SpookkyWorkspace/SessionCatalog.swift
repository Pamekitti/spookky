import Foundation
import SpookkyCore

public protocol SessionCatalogReading: Sendable {
    func refresh(force: Bool) async -> SessionCatalogSnapshot
    func page(query: HistoryQuery, force: Bool) async -> HistoryPage
    func invalidatePages() async
    var historySourceRoots: [String] { get }
}
public extension SessionCatalogReading {
    var historySourceRoots: [String] { [] }
    func invalidatePages() async {}
    func page(query: HistoryQuery, force: Bool = false) async -> HistoryPage {
        let snapshot = await refresh(force: force)
        let position = query.cursor.flatMap { Data(base64Encoded: $0) }
            .flatMap { try? JSONDecoder().decode(HistoryPosition.self, from: $0) }
        let matches = snapshot.conversations.filter { query.matches($0) && (position?.containsOlder($0) ?? true) }
            .sorted(by: historyNewestFirst)
        let entries = Array(matches.prefix(query.limit))
        let cursor = matches.count > entries.count ? entries.last.flatMap { try? JSONEncoder().encode(HistoryPosition($0)).base64EncodedString() } : nil
        return HistoryPage(conversations: entries, nextCursor: cursor, issues: snapshot.issues,
            truncated: snapshot.truncated, refreshedAt: snapshot.refreshedAt)
    }
}
public struct EmptySessionCatalog: SessionCatalogReading {
    public init() {}
    public func refresh(force: Bool) async -> SessionCatalogSnapshot { SessionCatalogSnapshot(conversations: []) }
}
public actor SessionCatalog: SessionCatalogReading {
    private let resolver: any ExecutableResolver
    private let environment: [String: String]
    private let claudeRoot: URL
    private var claude = ClaudeHistoryReader()
    private var snapshot: SessionCatalogSnapshot?
    private var pending: Task<(SessionCatalogSnapshot, ClaudeHistoryReader), Never>?
    public nonisolated let historySourceRoots: [String]
    private var pages: [HistoryQuery: HistoryPage] = [:]
    private struct ProviderPage: Codable {
        var entries: [ConversationMetadata] = []
        var cursor: String?
        var exhausted = false
    }
    private struct PageCursor: Codable {
        let identity: String
        var codex = ProviderPage()
        var claude = ProviderPage()
    }

    public init(resolver: any ExecutableResolver = CLIResolver(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                claudeRoot: URL? = nil) {
        self.resolver = resolver; self.environment = environment
        let base = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        self.claudeRoot = claudeRoot ?? base.appendingPathComponent("projects")
        let codexRoot = environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        self.historySourceRoots = [codexRoot, self.claudeRoot.path]
    }

    public func page(query: HistoryQuery, force: Bool = false) async -> HistoryPage {
        if !force, let cached = pages[query], Date().timeIntervalSince(cached.refreshedAt) < 30 { return cached }
        var state = PageCursor(identity: query.identity)
        if let cursor = query.cursor {
            guard cursor.utf8.count <= 1_048_576, let bytes = Data(base64Encoded: cursor),
                  let decoded = try? JSONDecoder().decode(PageCursor.self, from: bytes), decoded.identity == query.identity else {
                return HistoryPage(conversations: [], issues: [SessionCatalogIssue(.codex, "This history page expired. Refresh conversations and retry.")], truncated: true)
            }
            state = decoded
        }
        var issues: [SessionCatalogIssue] = [], truncated = false
        if !state.codex.exhausted, state.codex.entries.count < query.limit, !Task.isCancelled {
            do {
                let spec = try await resolver.resolve(.codex, directory: FileManager.default.homeDirectoryForCurrentUser.path, prompt: nil)
                try Task.checkCancellation()
                let result = try CodexHistoryReader.page(executable: spec.executable,
                    environment: environment.merging(spec.environment) { _, supplied in supplied },
                    query: HistoryQuery(projectID: query.projectID, directories: query.directories, search: query.search,
                        limit: query.limit - state.codex.entries.count, exactDirectories: query.exactDirectories,
                        titleSearchOnly: query.titleSearchOnly), cursor: state.codex.cursor)
                state.codex.entries += result.conversations; state.codex.cursor = result.nextCursor
                state.codex.exhausted = result.nextCursor == nil
                issues += result.issues; truncated = result.truncated
            } catch is CancellationError { return HistoryPage(conversations: [], truncated: true) }
            catch {
                state.codex.exhausted = true
                issues.append(SessionCatalogIssue(.codex, "Codex local history is unavailable. Check the installed CLI and retry."))
            }
        }
        if !state.claude.exhausted, state.claude.entries.count < query.limit, !Task.isCancelled {
            let result = claude.page(root: claudeRoot,
                query: HistoryQuery(projectID: query.projectID, directories: query.directories, search: query.search,
                    limit: query.limit - state.claude.entries.count, exactDirectories: query.exactDirectories,
                    titleSearchOnly: query.titleSearchOnly),
                cursor: state.claude.cursor, force: force)
            state.claude.entries += result.conversations; state.claude.cursor = result.nextCursor
            state.claude.exhausted = result.nextCursor == nil
            issues += result.issues; truncated = truncated || result.truncated
        }
        if Task.isCancelled { return HistoryPage(conversations: [], truncated: true) }
        let observed = Self.reconcile(state.codex.entries + state.claude.entries)
        let entries = Array(observed.conversations.prefix(query.limit)), emitted = Set(entries.map(\.id))
        state.codex.entries.removeAll { emitted.contains($0.id) }; state.claude.entries.removeAll { emitted.contains($0.id) }
        let more = !state.codex.entries.isEmpty || !state.claude.entries.isEmpty || !state.codex.exhausted || !state.claude.exhausted
        let cursor = more ? (try? JSONEncoder().encode(state).base64EncodedString()) : nil
        let result = HistoryPage(conversations: entries, nextCursor: cursor, issues: issues, truncated: truncated)
        if pages.count >= 64, let oldest = pages.min(by: { $0.value.refreshedAt < $1.value.refreshedAt })?.key { pages.removeValue(forKey: oldest) }
        pages[query] = result
        return result
    }

    public func invalidatePages() async {
        pages.removeAll()
        claude.invalidateIndex()
    }

    public func refresh(force: Bool = false) async -> SessionCatalogSnapshot {
        if let pending { return await pending.value.0 }
        if !force, let snapshot, Date().timeIntervalSince(snapshot.refreshedAt) < 30 { return snapshot }
        let resolver = resolver, environment = environment, root = claudeRoot, reader = claude
        let task = Task.detached { () -> (SessionCatalogSnapshot, ClaudeHistoryReader) in
            var entries: [ConversationMetadata] = [], issues: [SessionCatalogIssue] = [], truncated = false
            do {
                let spec = try await resolver.resolve(.codex, directory: FileManager.default.homeDirectoryForCurrentUser.path, prompt: nil)
                let result = try CodexHistoryReader.read(executable: spec.executable,
                    environment: environment.merging(spec.environment) { _, supplied in supplied })
                entries += result.conversations; issues += result.issues; truncated = result.truncated
            } catch { issues.append(SessionCatalogIssue(.codex, "Codex local history is unavailable. Check the installed CLI and retry.")) }
            var reader = reader
            let result = reader.read(root: root)
            entries += result.conversations; issues += result.issues; truncated = truncated || result.truncated
            return (Self.reconcile(entries, issues: issues, truncated: truncated), reader)
        }
        pending = task
        let result = await task.value
        snapshot = result.0; claude = result.1; pending = nil
        return result.0
    }

    static func reconcile(_ entries: [ConversationMetadata], issues: [SessionCatalogIssue] = [], truncated: Bool = false) -> SessionCatalogSnapshot {
        var records: [ConversationID: ConversationMetadata] = [:]
        for var entry in entries {
            if let current = records[entry.id] {
                if current.directory != entry.directory {
                    // A duplicated provider ID with conflicting cwd is unsafe to resume.
                    entry.availability = .historyUnavailable
                } else if current.updatedAt > entry.updatedAt { continue }
                if current.availability == .historyUnavailable { entry.availability = .historyUnavailable }
            }
            var directory: ObjCBool = false
            if entry.availability == .local && (!FileManager.default.fileExists(atPath: entry.directory, isDirectory: &directory) || !directory.boolValue) {
                entry.availability = .folderUnavailable
            }
            if entry.availability == .local, let path = entry.historyPath, !FileManager.default.fileExists(atPath: path) { entry.availability = .historyUnavailable }
            records[entry.id] = entry
        }
        return SessionCatalogSnapshot(conversations: records.values.sorted(by: historyNewestFirst), issues: issues, truncated: truncated)
    }

    public static func matching(_ entries: [ConversationMetadata], directories: [String], search: String = "") -> [ConversationMetadata] {
        let roots = directories.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { item in
            let path = URL(fileURLWithPath: item.directory).standardizedFileURL.path
            return roots.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") } &&
                (query.isEmpty || item.displayTitle.localizedCaseInsensitiveContains(query) ||
                 item.id.sessionID.localizedCaseInsensitiveContains(query) || item.directory.localizedCaseInsensitiveContains(query))
        }
    }
}
