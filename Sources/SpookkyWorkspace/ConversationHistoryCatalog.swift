import Foundation
import SpookkyCore

public struct CatalogPage: Sendable {
    public let records: [ConversationCatalogRecord]
    public let nextCursor: String?
    public let issues: [SessionCatalogIssue]
    public let truncated: Bool
}

/// The provider owns history; this service stores only the metadata requested by the UI.
public actor ConversationHistoryCatalog {
    private let reader: any SessionCatalogReading
    private let persistence: (any HistoryCatalogPersistence)?
    private let associations = ProjectAssociationResolver()
    private var memory: [ConversationID: ConversationCatalogRecord] = [:]
    public init(reader: any SessionCatalogReading, persistence: (any HistoryCatalogPersistence)?) {
        self.reader = reader; self.persistence = persistence
    }

    public func cached(projectID: UUID? = nil, allProjects: Bool = false, search: String = "", limit: Int = 5, excluding: Set<ConversationID> = []) async throws -> [ConversationCatalogRecord] {
        let limit = max(1, limit)
        if let persistence {
            var records: [ConversationCatalogRecord] = []
            var offset = 0
            while records.count < limit {
                try Task.checkCancellation()
                let count = excluding.isEmpty ? min(100, limit - records.count) : 100
                let page = try await persistence.history(StoredHistoryQuery(projectID: projectID, allProjects: allProjects,
                    search: search, limit: count, offset: offset))
                records += page.filter { !excluding.contains($0.id) }; offset += page.count
                if page.count < count { break }
            }
            return Array(records.prefix(limit))
        }
        return Array(memory.values.filter {
            !excluding.contains($0.id) && (allProjects || $0.projectID == projectID) && (search.isEmpty || [$0.displayTitle, $0.metadata.directory, $0.id.sessionID].contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted { historyNewestFirst($0.metadata, $1.metadata) }.prefix(limit))
    }

    public func refresh(query: HistoryQuery, projects: [Project], force: Bool = false) async throws -> CatalogPage {
        let page = await reader.page(query: query, force: force)
        try Task.checkCancellation()
        let batch = try await associations.resolveBatch(directories: Array(Set(page.conversations.map(\.directory))), projects: projects)
        try Task.checkCancellation()
        var records: [ConversationCatalogRecord] = []
        var preservingProjectFor = Set<ConversationID>()
        for metadata in page.conversations {
            let association = batch.resolution(for: metadata.directory)
            if association.status == .unavailable || association.status == .ambiguous { preservingProjectFor.insert(metadata.id) }
            records.append(ConversationCatalogRecord(metadata: metadata, projectID: association.projectID))
        }
        let registeredProjectIDs = Set(projects.map(\.id))
        if let persistence {
            records = try await persistence.mergeHistoryMetadata(records, preservingProjectFor: preservingProjectFor,
                registeredProjectIDs: registeredProjectIDs)
        } else {
            records = records.map {
                $0.mergingMetadata(over: memory[$0.id], preservingProject: preservingProjectFor.contains($0.id),
                                   registeredProjectIDs: registeredProjectIDs)
            }
            for record in records { memory[record.id] = record }
        }
        return CatalogPage(records: records, nextCursor: page.nextCursor, issues: page.issues, truncated: page.truncated || batch.truncated)
    }

    public func record(_ id: ConversationID) async throws -> ConversationCatalogRecord? {
        if let persistence { return try await persistence.conversation(id) }
        return memory[id]
    }
    public func save(_ records: [ConversationCatalogRecord]) async throws {
        if let persistence { try await persistence.saveHistory(records) }
        else { for record in records { memory[record.id] = record } }
    }
    public func rename(_ id: ConversationID, alias: String) async throws {
        let name = String(alias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        guard !name.isEmpty else { throw LaunchError.invalid("Enter a conversation name.") }
        if let persistence { _ = try await persistence.setHistoryAlias(id, alias: name) }
        else { memory[id]?.localAlias = name }
    }
    public func removeProject(_ id: UUID) async throws {
        if let persistence { try await persistence.unassignHistoryProject(id) }
        else { for key in Array(memory.keys) where memory[key]?.projectID == id { memory[key]?.projectID = nil } }
    }
    public func directories(for project: Project, locations: LocationMetadata?) async throws -> [String] {
        var directories = [project.location.path, project.location.scopePath]
        if let persistence { directories += try await persistence.historyDirectories(projectID: project.id) }
        else { directories += memory.values.filter { $0.projectID == project.id }.map(\.metadata.directory) }
        directories += locations?.checkouts.filter {
            $0.location.commonRepository != nil && $0.location.commonRepository == project.location.commonRepository
        }.map(\.location.path) ?? []
        return Array(Set(directories)).sorted()
    }
}
