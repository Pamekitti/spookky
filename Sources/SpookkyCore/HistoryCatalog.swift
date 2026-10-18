import Foundation

/// Provider metadata is retained independently of terminal and workspace lifetimes.
public struct ConversationCatalogRecord: Codable, Equatable, Identifiable, Sendable {
    public var metadata: ConversationMetadata
    public var projectID: UUID?
    public var localAlias: String?
    public var workspaceID: UUID?
    public var terminalID: UUID?
    public var id: ConversationID { metadata.id }
    public var displayTitle: String { localAlias ?? metadata.displayTitle }
    public init(metadata: ConversationMetadata, projectID: UUID? = nil, localAlias: String? = nil,
                workspaceID: UUID? = nil, terminalID: UUID? = nil) {
        self.metadata = metadata; self.projectID = projectID; self.localAlias = localAlias
        self.workspaceID = workspaceID; self.terminalID = terminalID
    }
}

extension Workspace {
    public var isLanding: Bool { landingContext != nil }
    public var isImportedHistoryPlaceholder: Bool {
        catalogMetadata != nil && viewClosed == true && !customTitle && anchor == nil && tabs.count == 1 &&
            locationOperationID == nil && locationOwnerWorkspaceID == nil &&
            support?.tabs.isEmpty != false && tabs.allSatisfy {
                $0.binding == nil && $0.launch == nil && $0.draft.prompt.isEmpty && !$0.customTitle
            }
    }
}

extension WorkspaceState {
    @discardableResult public mutating func showLanding(projectID: UUID? = nil, homeDirectory: String) -> UUID {
        let context = projectID?.uuidString ?? "global"
        if let existing = workspaces.first(where: { $0.landingContext == context }) {
            selectWorkspace(existing.id); return existing.id
        }
        let location = projectID.flatMap { id in projects.first { $0.id == id }?.location } ?? WorkspaceLocation(path: homeDirectory)
        let id = newWorkspace(location: location, projectID: projectID)
        if let index = workspaces.firstIndex(where: { $0.id == id }) {
            workspaces[index].landingContext = context
            workspaces[index].title = "New session"; workspaces[index].automaticTitle = nil
        }
        return id
    }

    public mutating func promoteLanding(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), workspaces[index].isLanding else { return }
        workspaces[index].landingContext = nil
        workspaces[index].automaticTitle = .friendly
        let tool = workspaces[index].primaryTerminal?.draft.tool ?? .codex
        workspaces[index].title = tool == .shell ? "Terminal" : tool.displayName + " session"
    }

    /// Returns the catalog rows so persistence can migrate both stores in one transaction.
    public mutating func migrateHistoryCatalog() -> [ConversationCatalogRecord] {
        guard version == 6 else { return [] }
        let records = workspaces.compactMap { workspace -> ConversationCatalogRecord? in
            guard let metadata = workspace.catalogMetadata else { return nil }
            return ConversationCatalogRecord(metadata: metadata, projectID: workspace.projectID,
                localAlias: workspace.customTitle ? workspace.title : nil,
                workspaceID: workspace.id, terminalID: workspace.primaryTerminalID)
        }
        for index in workspaces.indices {
            if var panel = workspaces[index].support {
                for tab in panel.tabs.indices {
                    if case .file = panel.tabs[tab].target {
                        var view = panel.tabs[tab].fileView ?? FileViewState()
                        view.changes = false; view.selectedGroup = nil; view.againstBranch = false; view.reference = nil; view.sidebar = false
                        panel.tabs[tab].fileView = view
                    }
                }
                workspaces[index].support = panel
            }
        }
        workspaces.removeAll { $0.isImportedHistoryPlaceholder && $0.id != selectedWorkspaceID }
        version = 7
        return records
    }

    @discardableResult public mutating func openCatalogRecord(_ record: ConversationCatalogRecord) -> UUID {
        if let existing = workspace(for: record.id) {
            selectWorkspace(existing.id)
            recordCatalogMetadata(record.metadata, workspaceID: existing.id, projectID: record.projectID)
            return existing.id
        }
        var workspace = Workspace(location: WorkspaceLocation(path: record.metadata.directory), projectID: record.projectID,
            tool: record.id.provider, id: record.workspaceID ?? UUID(), title: record.displayTitle)
        if let terminalID = record.terminalID {
            workspace.tabs = [WorkspaceTab(id: terminalID, tool: record.id.provider)]
            workspace.primaryTerminalID = terminalID; workspace.selectedTabID = terminalID
        }
        workspace.conversationID = record.id; workspace.catalogMetadata = record.metadata
        workspace.customTitle = record.localAlias != nil; workspace.viewClosed = false
        workspaces.append(workspace); selectWorkspace(workspace.id)
        setProviderTitle(record.metadata.title, conversationID: record.id)
        return workspace.id
    }
}
