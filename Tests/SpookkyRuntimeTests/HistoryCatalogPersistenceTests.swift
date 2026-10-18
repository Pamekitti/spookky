import XCTest
import GRDB
@testable import SpookkyCore
import SpookkyWorkspace
import SpookkyPersistence

final class HistoryCatalogPersistenceTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-v7-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func metadata(_ number: Int, title: String? = nil) -> ConversationMetadata {
        ConversationMetadata(id: ConversationID(provider: .codex, sessionID: String(format: "00000000-0000-4000-8000-%012d", number)),
            title: title ?? "Conversation \(number)", directory: "/tmp/project", updatedAt: Date(timeIntervalSince1970: Double(number)))
    }

    func testGlobalAndProjectLandingDraftsRestoreFromReopenedDatabase() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite").path
        var state = WorkspaceState()
        let global = state.showLanding(homeDirectory: "/tmp/home")
        let globalTerminal = state.primaryTerminalID!
        state.editDraft(globalTerminal, tool: .claude, prompt: "Global unsent instruction")
        state.setLocation(WorkspaceLocation(path: "/tmp/chosen-folder"), projectID: nil, workspaceID: global)
        let project = state.registerProject(WorkspaceLocation(path: "/tmp/project"))
        let projectDraft = state.showLanding(projectID: project, homeDirectory: "/tmp/home")
        let projectTerminal = state.primaryTerminalID!
        state.editDraft(projectTerminal, tool: .codex, prompt: "Project unsent instruction")
        state.openSupport(.browser(url: "https://example.invalid"), title: "Retained browser")
        do { let database = try WorkspaceDatabase(path: path); try await database.save(state) }
        let reopened = try WorkspaceDatabase(path: path)
        let loaded = try await reopened.load()
        var restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.showLanding(homeDirectory: "/tmp/home"), global)
        XCTAssertEqual(restored.selectedTab?.draft.prompt, "Global unsent instruction")
        XCTAssertEqual(restored.selectedTab?.draft.tool, .claude)
        XCTAssertEqual(restored.selected?.directory, "/tmp/chosen-folder")
        XCTAssertEqual(restored.showLanding(projectID: project, homeDirectory: "/tmp/home"), projectDraft)
        XCTAssertEqual(restored.selectedTab?.draft.prompt, "Project unsent instruction")
        XCTAssertEqual(restored.selected?.support?.tabs.count, 1)
        XCTAssertTrue(restored.workspaces.flatMap(\.tabs).allSatisfy { $0.launch == nil && $0.binding == nil })
    }

    func testRemovingProjectLeavesItsDraftAccessibleWithoutReplacingGlobalDraft() throws {
        var state = WorkspaceState()
        let global = state.showLanding(homeDirectory: "/tmp")
        state.editDraft(state.primaryTerminalID!, prompt: "Global draft")
        let project = state.registerProject(WorkspaceLocation(path: "/tmp/project"))
        let draft = state.showLanding(projectID: project, homeDirectory: "/tmp")
        let terminal = state.primaryTerminalID!
        state.editDraft(terminal, tool: .claude, prompt: "Project draft")
        state.showLanding(homeDirectory: "/tmp"); state.removeProject(project)
        XCTAssertEqual(state.selectedWorkspaceID, global)
        XCTAssertEqual(state.selectedTab?.draft.prompt, "Global draft")
        XCTAssertTrue(state.openWorkspaces.contains { $0.id == draft })
        XCTAssertEqual(state.tab(terminal)?.draft.prompt, "Project draft")
        XCTAssertEqual(state.tab(terminal)?.draft.tool, .claude)
        XCTAssertNil(state.tab(terminal)?.launch); XCTAssertNil(state.tab(terminal)?.binding)
        try state.validate()
    }

    func testRemovingProjectKeepsCatalogAliasesAndStableRestoreIDs() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        let project = UUID(), workspace = UUID(), terminal = UUID()
        let original = ConversationCatalogRecord(metadata: metadata(1), projectID: project, localAlias: "My alias",
            workspaceID: workspace, terminalID: terminal)
        try await database.saveHistory([original])
        let catalog = ConversationHistoryCatalog(reader: EmptySessionCatalog(), persistence: database)
        try await catalog.removeProject(project)
        let orphaned = try await database.history(StoredHistoryQuery(projectID: project))
        let unbound = try await database.history(StoredHistoryQuery())
        XCTAssertTrue(orphaned.isEmpty)
        var expected = original; expected.projectID = nil
        XCTAssertEqual(unbound, [expected])
        var state = WorkspaceState(); let restored = state.openCatalogRecord(unbound[0])
        XCTAssertEqual(restored, workspace); XCTAssertEqual(state.primaryTerminalID, terminal)
        XCTAssertEqual(state.selected?.displayTitle, "My alias")
        XCTAssertNil(state.selectedTab?.launch); XCTAssertNil(state.selectedTab?.binding)
    }

    func testCatalogPagesDoNotCreateWorkspacesAndSearchOlderRows() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        let project = UUID(), other = UUID()
        try await database.save(WorkspaceState())
        try await database.saveHistory((1...60).map { ConversationCatalogRecord(metadata: metadata($0, title: $0 == 2 ? "Café older match" : nil), projectID: $0 > 40 ? other : project) })
        let first = try await database.history(StoredHistoryQuery(projectID: project))
        XCTAssertEqual(first.map(\.metadata.updatedAt), (36...40).reversed().map { Date(timeIntervalSince1970: Double($0)) })
        let more = try await database.history(StoredHistoryQuery(projectID: project, limit: 10, offset: 5))
        XCTAssertEqual(more.count, 10); XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(more.map(\.id))))
        let older = try await database.history(StoredHistoryQuery(allProjects: true, search: "CAFE", limit: 10))
        XCTAssertEqual(older.map(\.id), [metadata(2).id])
        let restored = try await database.load(); XCTAssertEqual(restored?.workspaces.count, 0)
    }

    func testV6MigrationExtractsPlaceholdersAndPreservesUserStateAndIDs() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite").path
        var old = WorkspaceState(); old.version = 6
        for number in 1...75 {
            let item = metadata(number)
            let id = old.ensureConversationWorkspace(item.id, location: WorkspaceLocation(path: item.directory), select: false)
            old.recordCatalogMetadata(item, workspaceID: id, projectID: nil)
        }
        let placeholder = old.workspaces[0]
        let retainedID = old.newWorkspace(directory: root.path)
        let terminal = try XCTUnwrap(old.selectedTab?.id)
        old.editDraft(terminal, tool: .claude, prompt: "retain unsent 日本語")
        old.renameWorkspace(retainedID, "My retained draft")
        old.openSupport(.browser(url: "about:blank"), title: "Browser")
        let retained = old.selected
        let payload = try JSONEncoder().encode(old)
        do {
            let queue = try DatabaseQueue(path: path)
            try await queue.write { db in
                try db.execute(sql: "CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY)")
                for version in 1...6 { try db.execute(sql: "INSERT INTO grdb_migrations VALUES (?)", arguments: ["workspace-v\(version)"]) }
                try db.execute(sql: "CREATE TABLE workspace_snapshot(id INTEGER PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL)")
                try db.execute(sql: "INSERT INTO workspace_snapshot VALUES (1, 6, ?)", arguments: [payload])
            }
        }
        let database = try WorkspaceDatabase(path: path)
        let loaded = try await database.load()
        var restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.version, 7); XCTAssertEqual(restored.workspaces, [try XCTUnwrap(retained)])
        let records = try await database.history(StoredHistoryQuery(allProjects: true, limit: 100))
        XCTAssertEqual(records.count, 75)
        let record = try XCTUnwrap(records.first { $0.id == placeholder.conversationID })
        XCTAssertEqual(record.workspaceID, placeholder.id); XCTAssertEqual(record.terminalID, placeholder.primaryTerminalID)
        restored.openCatalogRecord(record)
        XCTAssertEqual(restored.selectedWorkspaceID, placeholder.id); XCTAssertEqual(restored.primaryTerminalID, placeholder.primaryTerminalID)
        XCTAssertNil(restored.selectedTab?.binding); XCTAssertNil(restored.selectedTab?.launch)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("pre-v7") })
        try restored.validate()
    }

    func testLandingDraftsRemainSeparateAndLastViewReturnsToComposer() throws {
        var state = WorkspaceState()
        let home = state.showLanding(homeDirectory: "/tmp/home"), homeTab = try XCTUnwrap(state.primaryTerminalID)
        state.editDraft(homeTab, tool: .claude, prompt: "Keep this prompt")
        let project = state.registerProject(WorkspaceLocation(path: "/tmp/project"))
        let projectDraft = state.showLanding(projectID: project, homeDirectory: "/tmp/home")
        state.editDraft(state.primaryTerminalID!, prompt: "Project draft")
        XCTAssertNotEqual(home, projectDraft)
        XCTAssertEqual(state.showLanding(homeDirectory: "/tmp/home"), home)
        XCTAssertEqual(state.selectedTab?.draft.prompt, "Keep this prompt")
        state.openSupport(.browser(url: "about:blank"), title: "Browser")
        XCTAssertTrue(state.workspaces.flatMap(\.tabs).allSatisfy { $0.binding == nil && $0.launch == nil })
        state.promoteLanding(home); XCTAssertFalse(state.selected!.isLanding)
        state.hideWorkspace(home)
        XCTAssertTrue(state.selected!.isLanding)
        XCTAssertEqual(state.showLanding(projectID: project, homeDirectory: "/tmp/home"), projectDraft)
        XCTAssertEqual(state.selectedTab?.draft.prompt, "Project draft")
        try state.validate()
    }
}
