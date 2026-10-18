import Foundation
import SpookkyCore

public protocol SessionCatalogReading: Sendable {
    func refresh(force: Bool) async -> SessionCatalogSnapshot
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

    public init(resolver: any ExecutableResolver = CLIResolver(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                claudeRoot: URL? = nil) {
        self.resolver = resolver; self.environment = environment
        let base = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        self.claudeRoot = claudeRoot ?? base.appendingPathComponent("projects")
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
        return SessionCatalogSnapshot(conversations: records.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return ($0.id.provider.rawValue, $0.id.sessionID) < ($1.id.provider.rawValue, $1.id.sessionID)
        }, issues: issues, truncated: truncated)
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
