import Foundation
import SpookkyCore

/// Bounds native controls while searching all retained metadata, including closed views.
public struct ConversationSidebarPage: Sendable {
    public let workspaces: [Workspace]
    public let matchingCount: Int
    public var remaining: Int { max(0, matchingCount - workspaces.count) }
    public init(state: WorkspaceState, query: String = "", limit: Int = 50) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsedProjects = Set(state.projects.filter { $0.isCollapsed == true }.map(\.id))
        let matches = state.workspaces.filter { workspace in
            if query.isEmpty, let projectID = workspace.projectID, collapsedProjects.contains(projectID) { return false }
            guard workspace.conversationID != nil || workspace.viewClosed != true else { return false }
            return query.isEmpty || [workspace.displayTitle, workspace.title, workspace.directory,
                workspace.catalogMetadata?.title ?? "", workspace.conversationID?.sessionID ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted {
            let a = $0.catalogMetadata?.updatedAt ?? .distantFuture
            let b = $1.catalogMetadata?.updatedAt ?? .distantFuture
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }
        matchingCount = matches.count
        var page = Array(matches.prefix(max(1, min(limit, 10_000))))
        if query.isEmpty, let selected = state.selected,
           selected.projectID.map({ !collapsedProjects.contains($0) }) ?? true, !page.contains(where: { $0.id == selected.id }) { page.append(selected) }
        workspaces = page
    }
}
