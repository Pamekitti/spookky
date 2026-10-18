import XCTest
import SpookkyCore
import SpookkyWorkspace
import SpookkyPersistence

final class HistoryMetadataMergeTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-history-merge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func metadata(title: String? = "Provider title", directory: String = "/tmp/project", updated: Double = 1,
                          availability: ConversationAvailability = .local) -> ConversationMetadata {
        ConversationMetadata(id: ConversationID(provider: .codex, sessionID: "00000000-0000-4000-8000-000000000001"),
            title: title, directory: directory, updatedAt: Date(timeIntervalSince1970: updated), availability: availability)
    }

    func testProviderMetadataCannotReplaceCurrentAliasOrRestoreIDsAndReturnsTheSavedRow() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        let firstProject = UUID(), secondProject = UUID(), workspace = UUID(), terminal = UUID()
        let original = ConversationCatalogRecord(metadata: metadata(), projectID: firstProject, localAlias: "Latest local alias",
            workspaceID: workspace, terminalID: terminal)
        try await database.saveHistory([original])
        let incoming = ConversationCatalogRecord(metadata: metadata(title: "Renamed provider title", updated: 2), projectID: secondProject,
            localAlias: "Stale alias from before refresh", workspaceID: UUID(), terminalID: UUID())
        let storage: any HistoryCatalogPersistence = database
        let merged = try await storage.mergeHistoryMetadata([incoming], preservingProjectFor: [], registeredProjectIDs: [firstProject, secondProject])
        let result = try XCTUnwrap(merged.first)
        XCTAssertEqual(result.localAlias, original.localAlias)
        XCTAssertEqual(result.workspaceID, workspace); XCTAssertEqual(result.terminalID, terminal)
        XCTAssertEqual(result.metadata, incoming.metadata); XCTAssertEqual(result.projectID, secondProject)
        let saved = try await database.conversation(original.id)
        XCTAssertEqual(saved, result)
        var renamed = result; renamed.localAlias = "Explicit new alias"
        try await database.saveHistory([renamed])
        let explicit = try await database.conversation(original.id)
        XCTAssertEqual(explicit?.localAlias, "Explicit new alias")
    }

    func testUnresolvedAssociationKeepsOnlyAStillRegisteredProject() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        let project = UUID(), original = ConversationCatalogRecord(metadata: metadata(), projectID: project)
        try await database.saveHistory([original])
        let incoming = ConversationCatalogRecord(metadata: metadata(updated: 2))
        let retained = try await database.mergeHistoryMetadata([incoming], preservingProjectFor: [incoming.id], registeredProjectIDs: [project])
        XCTAssertEqual(retained.first?.projectID, project)
        let removed = try await database.mergeHistoryMetadata([incoming], preservingProjectFor: [incoming.id], registeredProjectIDs: [])
        XCTAssertNil(removed.first?.projectID)
        try await database.saveHistory([original])
        let unregistered = try await database.mergeHistoryMetadata([incoming], preservingProjectFor: [], registeredProjectIDs: [project])
        XCTAssertNil(unregistered.first?.projectID)
    }

    func testPartialMetadataRetainsTheObservedTitleWhileRefreshingAvailability() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        let original = ConversationCatalogRecord(metadata: metadata(title: "Previously observed title"))
        try await database.saveHistory([original])
        let incoming = ConversationCatalogRecord(metadata: metadata(title: nil, updated: 9, availability: .folderUnavailable))
        let merged = try await database.mergeHistoryMetadata([incoming], preservingProjectFor: [], registeredProjectIDs: [])
        XCTAssertEqual(merged.first?.metadata.title, "Previously observed title")
        XCTAssertEqual(merged.first?.metadata.updatedAt, incoming.metadata.updatedAt)
        XCTAssertEqual(merged.first?.metadata.availability, .folderUnavailable)
    }

    func testCatalogRefreshReturnsTheAtomicMergeWithoutSeparatePreviousRecordReads() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        let storage = MetadataMergeProbe(base: database)
        var state = WorkspaceState()
        let project = state.registerProject(WorkspaceLocation(path: root.path))
        let original = ConversationCatalogRecord(metadata: metadata(directory: root.path), projectID: project,
            localAlias: "Local alias", workspaceID: UUID(), terminalID: UUID())
        try await database.saveHistory([original])
        let catalog = ConversationHistoryCatalog(reader: MetadataRefreshFixture(item: metadata(title: "Updated provider title", directory: root.path, updated: 2)), persistence: storage)
        let page = try await catalog.refresh(query: HistoryQuery(), projects: state.projects)
        XCTAssertEqual(page.records.first?.localAlias, original.localAlias)
        XCTAssertEqual(page.records.first?.workspaceID, original.workspaceID)
        XCTAssertEqual(page.records.first?.terminalID, original.terminalID)
        XCTAssertEqual(page.records.first?.metadata.title, "Updated provider title")
        let calls = await storage.calls()
        XCTAssertEqual(calls.reads, 0); XCTAssertEqual(calls.merges, 1)
    }

    func testDefaultFixtureAdapterPreservesLocalFields() async throws {
        let original = ConversationCatalogRecord(metadata: metadata(), localAlias: "Fixture alias", workspaceID: UUID(), terminalID: UUID())
        let fixture: any HistoryCatalogPersistence = MetadataMemoryFixture(record: original)
        let incoming = ConversationCatalogRecord(metadata: metadata(title: "Fresh provider title", updated: 2), localAlias: "Stale")
        let merged = try await fixture.mergeHistoryMetadata([incoming], preservingProjectFor: [], registeredProjectIDs: [])
        XCTAssertEqual(merged.first?.localAlias, original.localAlias)
        XCTAssertEqual(merged.first?.workspaceID, original.workspaceID)
        XCTAssertEqual(merged.first?.metadata, incoming.metadata)
        let saved = try await fixture.conversation(original.id)
        XCTAssertEqual(saved, merged.first)
    }
    func testRenameAfterProviderRefreshChangesOnlyAliasFromTheCapturedConversationID() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        let original = ConversationCatalogRecord(metadata: metadata(), projectID: UUID(), localAlias: "Old alias", workspaceID: UUID(), terminalID: UUID())
        try await database.saveHistory([original])
        let capturedID = original.id
        let project = UUID(), incoming = ConversationCatalogRecord(metadata: metadata(title: "Current provider title", directory: "/tmp/current-folder", updated: 20), projectID: project)
        let refreshed = try await database.mergeHistoryMetadata([incoming], preservingProjectFor: [], registeredProjectIDs: [project])
        let catalog = ConversationHistoryCatalog(reader: EmptySessionCatalog(), persistence: database)
        try await catalog.rename(capturedID, alias: "New local alias")
        let renamed = try await database.conversation(capturedID)
        var expected = try XCTUnwrap(refreshed.first); expected.localAlias = "New local alias"
        XCTAssertEqual(renamed, expected)
        let searchable = try await database.history(StoredHistoryQuery(allProjects: true, search: "New local alias"))
        XCTAssertEqual(searchable, [expected])
    }

    func testProjectUnassignmentPreservesLatestMetadataAliasesAndIDsAcrossBatches() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        let project = UUID(), other = UUID()
        let records = (1...105).map { number in
            ConversationCatalogRecord(metadata: ConversationMetadata(id: ConversationID(provider: .codex,
                sessionID: String(format: "00000000-0000-4000-8000-%012d", number)), title: "Current \(number)",
                directory: "/tmp/current/\(number)", updatedAt: Date(timeIntervalSince1970: Double(number))),
                projectID: number == 105 ? other : project, localAlias: "Alias \(number)", workspaceID: UUID(), terminalID: UUID())
        }
        try await database.saveHistory(records)
        let catalog = ConversationHistoryCatalog(reader: EmptySessionCatalog(), persistence: database)
        try await catalog.removeProject(project)
        for record in records {
            var expected = record
            if expected.projectID == project { expected.projectID = nil }
            let saved = try await database.conversation(record.id)
            XCTAssertEqual(saved, expected)
        }
        let oldProject = try await database.history(StoredHistoryQuery(projectID: project))
        XCTAssertTrue(oldProject.isEmpty)
        let unaffected = try await database.history(StoredHistoryQuery(projectID: other))
        XCTAssertEqual(unaffected, [try XCTUnwrap(records.last)])
    }

    func testLocalFieldUpdatesDoNotCreateMissingCatalogEntries() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        let missing = try await database.setHistoryAlias(metadata().id, alias: "Missing")
        XCTAssertNil(missing)
        try await database.unassignHistoryProject(UUID())
        let rows = try await database.history(StoredHistoryQuery(allProjects: true))
        XCTAssertTrue(rows.isEmpty)
    }

}

private struct MetadataRefreshFixture: SessionCatalogReading {
    let item: ConversationMetadata
    func refresh(force: Bool) async -> SessionCatalogSnapshot { SessionCatalogSnapshot(conversations: [item]) }
}

private actor MetadataMergeProbe: HistoryCatalogPersistence {
    let base: WorkspaceDatabase
    private var reads = 0, merges = 0
    init(base: WorkspaceDatabase) { self.base = base }
    func calls() -> (reads: Int, merges: Int) { (reads, merges) }
    func history(_ query: StoredHistoryQuery) async throws -> [ConversationCatalogRecord] { try await base.history(query) }
    func conversation(_ id: ConversationID) async throws -> ConversationCatalogRecord? {
        reads += 1; return try await base.conversation(id)
    }
    func saveHistory(_ records: [ConversationCatalogRecord]) async throws { try await base.saveHistory(records) }
    func historyDirectories(projectID: UUID) async throws -> [String] { try await base.historyDirectories(projectID: projectID) }
    func mergeHistoryMetadata(_ records: [ConversationCatalogRecord], preservingProjectFor: Set<ConversationID>,
                              registeredProjectIDs: Set<UUID>) async throws -> [ConversationCatalogRecord] {
        merges += 1
        return try await base.mergeHistoryMetadata(records, preservingProjectFor: preservingProjectFor, registeredProjectIDs: registeredProjectIDs)
    }
}

private actor MetadataMemoryFixture: HistoryCatalogPersistence {
    var record: ConversationCatalogRecord
    init(record: ConversationCatalogRecord) { self.record = record }
    func history(_ query: StoredHistoryQuery) async throws -> [ConversationCatalogRecord] { [record] }
    func conversation(_ id: ConversationID) async throws -> ConversationCatalogRecord? { id == record.id ? record : nil }
    func saveHistory(_ records: [ConversationCatalogRecord]) async throws { if let first = records.first { record = first } }
    func historyDirectories(projectID: UUID) async throws -> [String] { record.projectID == projectID ? [record.metadata.directory] : [] }
}
