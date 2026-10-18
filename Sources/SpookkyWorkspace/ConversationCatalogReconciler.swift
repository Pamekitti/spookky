import Foundation
import SpookkyCore

public enum ConversationCatalogReconciler {
    public static func apply(_ snapshot: SessionCatalogSnapshot, batch: ProjectAssociationBatch, to state: inout WorkspaceState) {
        let previous = Dictionary(state.workspaces.compactMap { w in w.catalogMetadata.map { ($0.id, $0) } }, uniquingKeysWith: { a, _ in a })
        for observed in snapshot.conversations {
            if Task.isCancelled { return }
            let old = previous[observed.id]
            let item = ConversationMetadata(id: observed.id, title: observed.title ?? old?.title,
                directory: observed.directory, updatedAt: observed.updatedAt, source: observed.source,
                providerProjectID: observed.providerProjectID, historyPath: observed.historyPath, availability: observed.availability)
            let association = batch.resolution(for: item.directory)
            let location = association.location ?? state.workspace(for: item.id)?.selectedLocation ?? WorkspaceLocation(path: item.directory)
            let id = state.ensureConversationWorkspace(item.id, location: location, projectID: association.projectID, select: false)
            state.recordCatalogMetadata(item, workspaceID: id, projectID: association.projectID)
        }
        // Only a complete successful provider inventory can establish that a record disappeared.
        let observed = Set(snapshot.conversations.map(\.id))
        let failed = Set(snapshot.issues.map { $0.provider.rawValue })
        if !snapshot.truncated {
            for workspace in state.workspaces {
                guard var item = workspace.catalogMetadata, !observed.contains(item.id), !failed.contains(item.id.provider.rawValue) else { continue }
                item.availability = .historyUnavailable
                state.recordCatalogMetadata(item, workspaceID: workspace.id, projectID: nil)
            }
        }
    }
}
