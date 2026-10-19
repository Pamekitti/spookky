import Foundation

public struct ThreadPresentation: Codable, Equatable, Sendable {
    public var pinnedAt: Date?
    public var archivedAt: Date?
    public var lastVisitedAt: Date?
    public var projectOverride: UUID?
    public var hasProjectOverride = false
    public var conversation: ConversationCatalogRecord?
    public var pullRequest: ThreadPullRequest?
    public init() {}
}

extension ConversationID {
    public var threadKey: String { provider.rawValue + ":" + sessionID }
}

extension Workspace {
    public var threadKey: String { conversationID?.threadKey ?? "workspace:" + id.uuidString }
}

extension WorkspaceState {
    public func presentation(for key: String) -> ThreadPresentation { threadPresentations?[key] ?? ThreadPresentation() }
    public func isArchived(_ workspace: Workspace) -> Bool { presentation(for: workspace.threadKey).archivedAt != nil }
    public var archivedConversationIDs: Set<ConversationID> {
        Set((threadPresentations ?? [:]).values.filter { $0.archivedAt != nil }.compactMap { $0.conversation?.id } + workspaces.filter { isArchived($0) }.compactMap(\.conversationID))
    }
    public mutating func rememberThread(_ record: ConversationCatalogRecord) {
        var entry = presentation(for: record.id.threadKey)
        entry.conversation = record
        if threadPresentations == nil { threadPresentations = [:] }
        threadPresentations?[record.id.threadKey] = entry
    }
    public mutating func editThread(_ key: String, _ edit: (inout ThreadPresentation) -> Void) {
        var entry = presentation(for: key); edit(&entry)
        if threadPresentations == nil { threadPresentations = [:] }
        threadPresentations?[key] = entry
        if entry.hasProjectOverride {
            for index in workspaces.indices where workspaces[index].threadKey == key { workspaces[index].projectID = entry.projectOverride }
        }
        if entry.archivedAt != nil, let workspace = selected, workspace.threadKey == key {
            showLanding(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        }
    }
    public mutating func migratePersistentThreads() {
        guard version == 7 else { return }
        let selected = selectedWorkspaceID
        for index in workspaces.indices {
            if workspaces[index].viewClosed == true { workspaces[index].viewClosed = false }
            if let record = workspaces[index].catalogMetadata {
                rememberThread(ConversationCatalogRecord(metadata: record, projectID: workspaces[index].projectID,
                    localAlias: workspaces[index].customTitle ? workspaces[index].title : nil,
                    workspaceID: workspaces[index].id, terminalID: workspaces[index].primaryTerminalID))
            }
        }
        version = 8
        let contexts = Set(workspaces.compactMap(\.landingContext))
        for context in contexts {
            _ = showLanding(projectID: UUID(uuidString: context), homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        }
        selectedWorkspaceID = selected
    }
}
