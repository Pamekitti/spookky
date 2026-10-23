import AppKit
import Darwin
import SpookkyCore
import SpookkyFiles
import SpookkyRuntime
import SpookkyWorkspace
import SpookkyGit

@MainActor final class WorkspaceHistoryController {
    weak var host: WorkspaceWindowController?
    let store: WorkspaceStore
    let sessionCatalog: any SessionCatalogReading
    init(host: WorkspaceWindowController) { self.host = host; store = host.store; sessionCatalog = host.sessionCatalog }
    var historyRefreshTask: Task<Void, Never>?
    var historyGeneration = UUID()
    var historyProjectSignature = ""
    var historyQuerySignature = ""
    var historyActivationObserver: NSObjectProtocol?
    var historyRefreshedAt: Date?
    var historySearchTask: Task<Void, Never>?
    var historyRecords: [String: [ConversationCatalogRecord]] = [:]
    var historyPageLimits: [String: Int] = [:]
    var historyCursors: [String: String] = [:]
    var historyHasMore = Set<String>()
    var historyIssues: [String: String] = [:]
    let historyWatcher = HistorySourceWatcher()
    lazy var historyCatalog = ConversationHistoryCatalog(reader: sessionCatalog, persistence: store.historyPersistence)
    func stop() {
        historyRefreshTask?.cancel(); historySearchTask?.cancel()
        historyGeneration = UUID()
        historyWatcher.stop()
        if let historyActivationObserver { NotificationCenter.default.removeObserver(historyActivationObserver) }
        historyActivationObserver = nil
    }
    func stableHistoryRows(_ incoming: [ConversationCatalogRecord], key: String, limit: Int) -> [ConversationCatalogRecord] {
        guard let host else { return [] }
        if key == "search" { return Array(incoming.prefix(limit)) }
        var byID: [ConversationID: ConversationCatalogRecord] = [:]
        for record in historyRecords[key] ?? [] { byID[record.id] = record }
        for record in incoming { byID[record.id] = record }
        let state = host.store.state
        let ranked: [(record: ConversationCatalogRecord, position: Double)] = byID.values.map { record in
            let position = state.presentation(for: record.id.threadKey).sidebarPosition ?? record.metadata.updatedAt.timeIntervalSinceReferenceDate
            return (record, position)
        }
        let ordered = ranked.sorted { left, right in
            left.position == right.position ? left.record.id.threadKey < right.record.id.threadKey : left.position > right.position
        }
        return Array(ordered.prefix(limit).map(\.record))
    }
    func removeHistoryDuplicates(_ incoming: [ConversationCatalogRecord], keeping key: String) {
        let ids = Set(incoming.map(\.id))
        for other in Array(historyRecords.keys) where other != key && other != "search" {
            guard let records = historyRecords[other] else { continue }
            historyRecords[other] = records.filter { !ids.contains($0.id) }
        }
    }
    func catalogProjectSignature() -> String {
        guard let host else { return "" }
        return host.store.state.projects.map { $0.id.uuidString + $0.location.path }.joined(separator: "\n")
    }
    func historyExclusions(for projectID: UUID?, allProjects: Bool = false) -> Set<ConversationID> {
        guard let host else { return [] }
        let state = host.store.state
        var excluded = state.archivedConversationIDs
        guard !allProjects else { return excluded }
        for entry in (state.threadPresentations ?? [:]).values where entry.hasProjectOverride && entry.projectOverride != projectID {
            if let id = entry.conversation?.id { excluded.insert(id) }
        }
        for workspace in state.workspaces {
            let entry = state.presentation(for: workspace.threadKey)
            if entry.hasProjectOverride && entry.projectOverride != projectID, let id = workspace.conversationID { excluded.insert(id) }
        }
        return excluded
    }
    func reconcileProviderIdentities() async {
        guard let host else { return }
        for workspace in host.store.state.workspaces where workspace.conversationID == nil {
            guard let primary = workspace.primaryTerminal, let binding = primary.binding, binding.tool == .codex else { continue }
            let path = host.activityRoot.appendingPathComponent("agent-identity-" + binding.id.uuidString + ".json").path
            let receipt = await Task.detached { try? AgentIntegration.read(ProviderIdentityReceipt.self, path: path) }.value
            guard let receipt, receipt.bindingID == binding.id, !receipt.candidates.isEmpty else { continue }
            let contextPath = host.activityRoot.appendingPathComponent("agent-terminal-" + binding.id.uuidString + ".json").path
            let context = await Task.detached { try? AgentIntegration.read(AgentTerminalContext.self, path: contextPath) }.value
            guard context?.secret == receipt.secret else { continue }
            guard host.sessionLaunch.pendingIdentities.insert(binding.id).inserted else { continue }
            defer { host.sessionLaunch.pendingIdentities.remove(binding.id) }
            guard let metadata = await ProviderIdentityResolver.codex(candidates: receipt.candidates, directory: binding.directory),
                  !Task.isCancelled, host.store.state.tab(primary.id)?.binding == binding else { continue }
            host.store.update { state in
                state.associateConversation(provider: .codex, sessionID: metadata.id.sessionID, title: metadata.title, workspaceID: workspace.id)
                state.recordCatalogMetadata(metadata, workspaceID: workspace.id, projectID: workspace.projectID)
            }
        }
    }
    func requestCatalogRefresh(force: Bool) {
        guard let host else { return }
        let signature = catalogProjectSignature() + "|" + host.historySearch.stringValue
        if historyRefreshTask != nil && !force && signature == historyQuerySignature { return }
        historyProjectSignature = catalogProjectSignature(); historyQuerySignature = signature
        historyRefreshTask?.cancel()
        let token = UUID(); historyGeneration = token
        let projects = host.store.state.projects, locations = host.store.state.locations
        let query = host.historySearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        historyRefreshTask = Task { [weak self, weak host] in
            guard let self, let host else { return }
            defer { if historyGeneration == token { historyRefreshTask = nil } }
            do {
                await reconcileProviderIdentities()
                if force { await host.sessionCatalog.invalidatePages() }
                if !query.isEmpty {
                    let limit = historyPageLimits["search"] ?? 10
                    let cached = try await historyCatalog.cached(allProjects: true, search: query, limit: limit, excluding: historyExclusions(for: nil, allProjects: true))
                    try Task.checkCancellation()
                    historyRecords["search"] = cached
                    if cached.contains(where: { host.store.state.presentation(for: $0.id.threadKey).sidebarPosition == nil }) {
                        host.store.update { $0.rememberSidebarPositions(cached) }
                    }
                    host.chromeRevision = ""; host.render()
                    try await refreshHistoryGroup("search", projects: projects, locations: locations, query: query, reset: true, force: false)
                } else {
                    for projectID in projects.map(\.id).map(Optional.some) + [nil] {
                        let key = projectID?.uuidString ?? "unbound"
                        let cached = try await historyCatalog.cached(projectID: projectID, limit: historyPageLimits[key] ?? 5, excluding: historyExclusions(for: projectID))
                        try Task.checkCancellation()
                        if cached.contains(where: { host.store.state.presentation(for: $0.id.threadKey).sidebarPosition == nil }) {
                            host.store.update { $0.rememberSidebarPositions(cached) }
                        }
                        removeHistoryDuplicates(cached, keeping: key)
                        historyRecords[key] = stableHistoryRows(cached, key: key, limit: historyPageLimits[key] ?? 5)
                    }
                    host.chromeRevision = ""; host.render()
                    // Discover recent external worktrees without enumerating the provider's full history.
                    _ = try await historyCatalog.refresh(query: HistoryQuery(limit: 10), projects: projects, force: false)
                    for project in projects where project.isCollapsed != true {
                        try Task.checkCancellation()
                        try await refreshHistoryGroup(project.id.uuidString, projects: projects, locations: locations, query: "", reset: true, force: false)
                    }
                    try await refreshHistoryGroup("unbound", projects: projects, locations: locations, query: "", reset: true, force: false)
                }
                guard !Task.isCancelled, historyGeneration == token else { return }
                historyRefreshedAt = Date(); host.chromeRevision = ""; host.render()
            } catch is CancellationError { }
            catch {
                guard historyGeneration == token else { return }
                historyIssues[query.isEmpty ? "unbound" : "search"] = error.localizedDescription
                host.chromeRevision = ""; host.render()
            }
        }
    }
    func refreshHistoryGroup(_ key: String, projects: [Project], locations: LocationMetadata?, query: String,
                                     reset: Bool, force: Bool) async throws {
        guard let host else { return }
        let projectID = UUID(uuidString: key), isSearch = key == "search"
        let limit = historyPageLimits[key] ?? (isSearch ? 10 : 5)
        let project = projectID.flatMap { id in projects.first { $0.id == id } }
        let directories: [String]
        if let project { directories = try await historyCatalog.directories(for: project, locations: locations) }
        else { directories = [] }
        var cursor = reset ? nil : historyCursors[key]
        var page: CatalogPage?
        for attempt in 0..<8 {
            try Task.checkCancellation()
            page = try await historyCatalog.refresh(query: HistoryQuery(projectID: projectID, directories: directories,
                search: query, limit: reset && attempt == 0 ? (isSearch ? 10 : 5) : 10, cursor: cursor,
                exactDirectories: project != nil, titleSearchOnly: isSearch && !query.contains("/") && UUID(uuidString: query) == nil), projects: projects, force: force && attempt == 0)
            try Task.checkCancellation()
            cursor = page?.nextCursor
            let cached = try await historyCatalog.cached(projectID: projectID, allProjects: isSearch, search: query, limit: limit + 1, excluding: historyExclusions(for: projectID, allProjects: isSearch))
            try Task.checkCancellation()
            if cached.contains(where: { host.store.state.presentation(for: $0.id.threadKey).sidebarPosition == nil }) {
                host.store.update { $0.rememberSidebarPositions(cached) }
            }
            removeHistoryDuplicates(cached, keeping: key)
            let knownCount = Set((historyRecords[key] ?? []).map(\.id)).union(cached.map(\.id)).count
            historyRecords[key] = stableHistoryRows(cached, key: key, limit: limit)
            if knownCount > limit || cached.count > limit || cursor != nil { historyHasMore.insert(key) } else { historyHasMore.remove(key) }
            historyCursors[key] = cursor
            for issue in page?.issues ?? [] where !issue.message.hasPrefix("No local Claude Code history") { host.sidebar.providerHistoryNotices.insert(issue.message) }
            historyIssues[key] = nil
            if let page {
                host.store.update { state in
                    for record in page.records {
                        if state.threadPresentations?[record.id.threadKey] != nil { state.rememberThread(record) }
                        if let workspace = state.workspace(for: record.id) {
                            state.recordCatalogMetadata(record.metadata, workspaceID: workspace.id, projectID: record.projectID)
                        }
                    }
                }
            }
            host.chromeRevision = ""; host.render()
            if cached.count >= limit || cursor == nil { break }
        }
    }
    func showMoreHistory(_ key: String) {
        guard let host else { return }
        if ["pinned", "archived"].contains(key) { host.sidebar.sectionLimits[key] = (host.sidebar.sectionLimits[key] ?? 5) + 10; host.chromeRevision = ""; host.render(); return }
        historyPageLimits[key] = (historyPageLimits[key] ?? (key == "search" ? 10 : 5)) + 10
        historyRefreshTask?.cancel()
        let token = UUID(); historyGeneration = token
        let projects = host.store.state.projects, locations = host.store.state.locations
        let query = host.historySearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        historyRefreshTask = Task { [weak self, weak host] in
            guard let self, let host else { return }
            defer { if historyGeneration == token { historyRefreshTask = nil } }
            do {
                try await refreshHistoryGroup(key, projects: projects, locations: locations, query: query, reset: false, force: false)
            } catch is CancellationError { }
            catch { historyIssues[key] = error.localizedDescription; host.chromeRevision = ""; host.render() }
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let host else { return }
        guard notification.object as? NSSearchField === host.historySearch else { return }
        historyPageLimits["search"] = 10
        historySearchTask?.cancel(); historyRefreshTask?.cancel()
        historySearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            requestCatalogRefresh(force: true)
        }
    }
}
