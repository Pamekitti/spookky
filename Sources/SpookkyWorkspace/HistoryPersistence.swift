import Foundation
import SpookkyCore

public struct StoredHistoryQuery: Sendable {
    public var projectID: UUID?
    public var allProjects: Bool
    public var search: String
    public var limit: Int
    public var offset: Int
    public init(projectID: UUID? = nil, allProjects: Bool = false, search: String = "", limit: Int = 5, offset: Int = 0) {
        self.projectID = projectID; self.allProjects = allProjects; self.search = search
        self.limit = max(1, min(100, limit)); self.offset = max(0, offset)
    }
}

public protocol HistoryCatalogPersistence: Sendable {
    func history(_ query: StoredHistoryQuery) async throws -> [ConversationCatalogRecord]
    func conversation(_ id: ConversationID) async throws -> ConversationCatalogRecord?
    func saveHistory(_ records: [ConversationCatalogRecord]) async throws
    func setHistoryAlias(_ id: ConversationID, alias: String) async throws -> ConversationCatalogRecord?
    func unassignHistoryProject(_ id: UUID) async throws
    func mergeHistoryMetadata(_ records: [ConversationCatalogRecord], preservingProjectFor: Set<ConversationID>,
                              registeredProjectIDs: Set<UUID>) async throws -> [ConversationCatalogRecord]
    func historyDirectories(projectID: UUID) async throws -> [String]
}

public extension HistoryCatalogPersistence {
    func setHistoryAlias(_ id: ConversationID, alias: String) async throws -> ConversationCatalogRecord? {
        guard var record = try await conversation(id) else { return nil }
        record.localAlias = alias
        try await saveHistory([record]); return record
    }
    func unassignHistoryProject(_ id: UUID) async throws {
        while true {
            let page = try await history(StoredHistoryQuery(projectID: id, limit: 100)).filter { $0.projectID == id }
            guard !page.isEmpty else { return }
            try await saveHistory(page.map { item in var item = item; item.projectID = nil; return item })
        }
    }
    func mergeHistoryMetadata(_ records: [ConversationCatalogRecord], preservingProjectFor: Set<ConversationID>,
                              registeredProjectIDs: Set<UUID>) async throws -> [ConversationCatalogRecord] {
        var merged: [ConversationCatalogRecord] = []
        for record in records {
            let previous = try await conversation(record.id)
            merged.append(record.mergingMetadata(over: previous, preservingProject: preservingProjectFor.contains(record.id),
                                                  registeredProjectIDs: registeredProjectIDs))
        }
        try await saveHistory(merged)
        return merged
    }
}

public extension ConversationCatalogRecord {
    func mergingMetadata(over previous: ConversationCatalogRecord?, preservingProject: Bool,
                         registeredProjectIDs: Set<UUID>) -> ConversationCatalogRecord {
        var result = self
        result.localAlias = previous?.localAlias
        result.workspaceID = previous?.workspaceID; result.terminalID = previous?.terminalID
        if metadata.title == nil, let title = previous?.metadata.title {
            result.metadata = ConversationMetadata(id: metadata.id, title: title, directory: metadata.directory,
                updatedAt: metadata.updatedAt, source: metadata.source, providerProjectID: metadata.providerProjectID,
                historyPath: metadata.historyPath, availability: metadata.availability)
        }
        if let projectID {
            result.projectID = registeredProjectIDs.contains(projectID) ? projectID : nil
        } else if preservingProject, let projectID = previous?.projectID, registeredProjectIDs.contains(projectID) {
            result.projectID = projectID
        } else { result.projectID = nil }
        return result
    }
}
