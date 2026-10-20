import XCTest
import GRDB
@testable import SpookkyCore
import SpookkyPersistence

final class ConversationWorkspaceTests: XCTestCase {
    func testHiddenSupportingPanelRestoresLayoutSelectionAndRecords() throws {
        for layout in [SupportingLayout.split, .fullWidth] {
            var state = WorkspaceState()
            state.newWorkspace(directory: "/tmp")
            let changes = try XCTUnwrap(state.openSupport(.changes, title: "Changes"))
            state.openSupport(.file(path: "file.txt"), title: "File")
            state.selectSupport(changes)
            state.setSupportingLayout(layout, fraction: 0.72)
            let tabs = state.selected?.support?.tabs, records = state.selected?.tabs
            state.setSupportingLayout(.collapsed)
            state.setSupportingLayout(.collapsed)
            XCTAssertEqual(state.selected?.support?.lastExpandedLayout, layout)
            state = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(state.openSupport(.changes, title: "Changes"), changes)
            XCTAssertEqual(state.selected?.support?.layout, layout)
            XCTAssertEqual(state.selected?.support?.fraction, 0.72)
            XCTAssertEqual(state.selected?.support?.selectedTabID, changes)
            XCTAssertEqual(state.selected?.support?.tabs, tabs)
            XCTAssertEqual(state.selected?.tabs, records)
            try state.validate()
        }
    }
    func testLegacyPanelDefaultsToSplitAndWorkspacesKeepIndependentLayouts() throws {
        let legacy = try JSONDecoder().decode(SupportingPanelState.self, from: Data(#"{"tabs":[],"layout":"collapsed","fraction":0.5}"#.utf8))
        XCTAssertNil(legacy.lastExpandedLayout)
        XCTAssertEqual(legacy.expandedLayout, .split)
        var state = WorkspaceState()
        let first = state.newWorkspace(directory: "/tmp")
        let firstChanges = try XCTUnwrap(state.openSupport(.changes, title: "Changes"))
        state.setSupportingLayout(.fullWidth)
        state.setSupportingLayout(.collapsed)
        let second = state.newWorkspace(directory: "/tmp")
        let secondChanges = try XCTUnwrap(state.openSupport(.changes, title: "Changes"))
        state.setSupportingLayout(.split)
        state.setSupportingLayout(.collapsed)
        state.selectSupport(firstChanges, workspaceID: first)
        XCTAssertEqual(state.workspaces.first(where: { $0.id == first })?.support?.layout, .fullWidth)
        XCTAssertEqual(state.workspaces.first(where: { $0.id == second })?.support?.layout, .collapsed)
        state.selectSupport(secondChanges, workspaceID: second)
        XCTAssertEqual(state.selected?.support?.layout, .split)
    }
    private func agent(_ state: inout WorkspaceState, _ id: UUID, tool: SessionTool, session: String? = nil,
                       status: TabStatus = .running) throws {
        state.editDraft(id, tool: tool, prompt: "literal draft 日本語\n$(do not run)")
        let spec = try LaunchSpec(tool: tool, executable: "/bin/cat", directory: "/tmp/café", initialPrompt: tool == .shell ? nil : "literal prompt")
        state.apply(.preparing, to: id); state.apply(.intent(spec, .pending), to: id)
        state.apply(.observed(SessionBinding(spec: spec), dead: status == .ended, exitCode: nil, prompt: .suppliedToProcess), to: id)
        if status == .uncertain { state.apply(.failure(.uncertain, TabFailure(.observation, "unknown"), clearIntent: false), to: id) }
        if let session {
            state.updateTab(id) { tab in
                var activity = AgentActivity(invocationID: spec.operationID, provider: tool == .shell ? .codex : tool)
                activity.sessionID = session; tab.activity = activity
            }
        }
    }
    func testMigrationSplitsAgentsAndDraftsPreservingEveryBackingRecord() throws {
        var state = WorkspaceState(); state.version = 5
        let original = state.newWorkspace(directory: "/tmp/café")
        let first = try XCTUnwrap(state.selectedTab?.id)
        try agent(&state, first, tool: .codex, session: "one", status: .uncertain)
        let shell = try XCTUnwrap(state.newTab()); try agent(&state, shell, tool: .shell)
        let second = try XCTUnwrap(state.newTab()); try agent(&state, second, tool: .claude, session: "two", status: .ended)
        let draft = try XCTUnwrap(state.newTab()); state.editDraft(draft, tool: .codex, prompt: "unsent")
        state.renameWorkspace(original, "Explicit alias"); state.renameTab(second, "Terminal alias")
        state.selectTab(second); state.bindWorkspace(original)
        let before = state
        state.migrateConversationWorkspaces(); try state.validate()
        XCTAssertEqual(state.version, 6); XCTAssertEqual(state.workspaces.count, 3)
        XCTAssertEqual(state.selectedWorkspaceID, original); XCTAssertEqual(state.primaryTerminalID, second)
        XCTAssertEqual(state.workspaces.first?.tabs.map(\.id), [shell, second])
        XCTAssertEqual(state.workspaces.first?.support?.tabs.first?.target, .terminal(tabID: shell))
        for tab in before.workspaces.flatMap(\.tabs) { XCTAssertEqual(state.tab(tab.id), tab) }
        XCTAssertTrue(state.workspaces.allSatisfy { $0.anchor == before.selected?.anchor && $0.title == "Explicit alias" && $0.customTitle })
        XCTAssertEqual(state.workspaces.first?.conversationID, ConversationID(provider: .claude, sessionID: "two"))
        let stable = state; state.migrateConversationWorkspaces(); XCTAssertEqual(state, stable)
    }
    func testManualAgentsInShellBindingsAndDuplicateHistoryRemainExplicit() throws {
        var state = WorkspaceState(); state.version = 5; state.newWorkspace(directory: "/tmp")
        let first = try XCTUnwrap(state.selectedTab?.id); try agent(&state, first, tool: .shell, session: "same")
        let second = try XCTUnwrap(state.newTab()); try agent(&state, second, tool: .shell, session: "same")
        let before = state.workspaces.flatMap(\.tabs)
        state.migrateConversationWorkspaces(); try state.validate()
        XCTAssertEqual(state.workspaces.count, 2)
        XCTAssertTrue(state.workspaces.allSatisfy { $0.conversationOwnershipAmbiguous == true })
        XCTAssertTrue(state.workspaces.allSatisfy { $0.conversationID == ConversationID(provider: .codex, sessionID: "same") })
        for tab in before { XCTAssertEqual(state.tab(tab.id), tab) }
        let id = ConversationID(provider: .codex, sessionID: "same")
        let original = state.workspaces[0], other = state.workspaces[1]
        state.selectWorkspace(original.id)
        state.apply(.terminated, to: original.primaryTerminalID!)
        XCTAssertEqual(state.workspace(for: id)?.id, other.id)
        XCTAssertEqual(state.preferredWorkspace(in: state.workspaces)?.id, other.id)
        state.apply(.terminated, to: other.primaryTerminalID!)
        XCTAssertEqual(state.workspace(for: id)?.id, original.id)
    }
    func testShellOnlyEmptyAndUnstartedMigration() throws {
        var empty = WorkspaceState(); empty.version = 5; empty.migrateConversationWorkspaces(); try empty.validate()
        XCTAssertTrue(empty.workspaces.isEmpty)
        var shell = WorkspaceState(); shell.version = 5; let original = shell.newWorkspace(directory: "/tmp")
        let first = try XCTUnwrap(shell.selectedTab?.id), second = try XCTUnwrap(shell.newTab())
        shell.migrateConversationWorkspaces(); try shell.validate()
        XCTAssertEqual(shell.workspaces.count, 1); XCTAssertEqual(shell.selectedWorkspaceID, original)
        XCTAssertEqual(shell.primaryTerminalID, second)
        XCTAssertEqual(shell.selected?.support?.tabs.first?.target, .terminal(tabID: first))
        XCTAssertNil(shell.selected?.conversationID)
    }
    func testSameCheckoutDistinctConversationsAndHidePreserveState() throws {
        var state = WorkspaceState(); let location = WorkspaceLocation(path: "/tmp", checkoutIdentity: "/tmp/.git")
        let one = ConversationID(provider: .codex, sessionID: "one"), two = ConversationID(provider: .codex, sessionID: "two")
        let first = state.ensureConversationWorkspace(one, location: location)
        let second = state.ensureConversationWorkspace(two, location: location)
        XCTAssertNotEqual(first, second); XCTAssertEqual(state.workspaces.count, 2)
        XCTAssertNil(state.selectedTab?.binding); XCTAssertNil(state.selectedTab?.launch)
        let primary = try XCTUnwrap(state.primaryTerminalID)
        state.editDraft(primary, prompt: "unsent")
        let browser = try XCTUnwrap(state.openSupport(.browser(url: "http://localhost:3000"), title: "Preview"))
        let browser2 = try XCTUnwrap(state.openSupport(.browser(url: "http://localhost:3000"), title: "Other form"))
        XCTAssertNotEqual(browser, browser2)
        state.setSupportingLayout(.fullWidth, fraction: 0.72)
        state.renameWorkspace(second, "My alias"); state.setProviderTitle("Provider name", conversationID: two)
        XCTAssertEqual(state.selected?.title, "My alias")
        let records = state.workspaces.flatMap(\.tabs)
        state.hideWorkspace(second); XCTAssertEqual(state.selectedWorkspaceID, first)
        state.selectWorkspace(second)
        XCTAssertEqual(state.primaryTerminalID, primary); XCTAssertEqual(state.selected?.support?.layout, .fullWidth)
        XCTAssertEqual(state.selected?.support?.fraction, 0.72); XCTAssertEqual(state.workspaces.flatMap(\.tabs), records)
        state.closeSupport(browser2); XCTAssertEqual(state.selected?.support?.selectedTabID, browser)
        XCTAssertEqual(state.primaryTerminalID, primary); try state.validate()
        let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state)); XCTAssertEqual(restored, state)
    }
    func testAgentLaunchSeparationKeepsTerminalIDAndDraft() throws {
        var state = WorkspaceState(); let original = state.newWorkspace(directory: "/tmp")
        let primary = try XCTUnwrap(state.primaryTerminalID), added = try XCTUnwrap(state.newTab())
        state.editDraft(added, tool: .claude, prompt: "retain literal prompt")
        let before = state.tab(added)
        let sibling = try XCTUnwrap(state.separateAgentTerminal(added)); try state.validate()
        XCTAssertNotEqual(sibling, original); XCTAssertEqual(state.primaryTerminalID, added)
        XCTAssertEqual(state.tab(added), before)
        XCTAssertEqual(state.workspaces.first?.primaryTerminalID, primary)
        XCTAssertTrue(state.workspaces.first?.support?.tabs.isEmpty == true)
    }
    func testMigrationKeepsInFlightLocationOperationWithOriginalOwner() throws {
        var state = WorkspaceState(); state.version = 5
        let original = state.newWorkspace(directory: "/tmp")
        state.editDraft(state.selectedTab!.id, tool: .codex)
        let second = try XCTUnwrap(state.newTab()); state.editDraft(second, tool: .claude)
        let request = LocationRequest(kind: .create, destination: "/tmp/new", workspaceID: original)
        state.recordOperation(LocationOperation(request))
        state.migrateConversationWorkspaces(); try state.validate()
        XCTAssertEqual(state.workspaces.count, 2)
        XCTAssertEqual(state.workspaces.first?.locationOperationID, request.id)
        XCTAssertNil(state.workspaces.last?.locationOperationID)
        let siblingID = state.workspaces.last!.id
        XCTAssertEqual(state.workspaces.last?.locationOwnerWorkspaceID, original)
        XCTAssertFalse(state.resolveConversationLocation(workspaceID: siblingID))
        var completed = LocationOperation(request); completed.status = .complete
        completed.receipts = [LocationReceipt(.filesystemComplete, location: WorkspaceLocation(path: "/tmp/new"))]
        state.recordOperation(completed)
        XCTAssertTrue(state.resolveConversationLocation(workspaceID: siblingID))
        XCTAssertEqual(state.workspaces.last?.selectedLocation.path, "/tmp/new")
        XCTAssertNil(state.workspaces.last?.locationOwnerWorkspaceID)
        XCTAssertEqual(state.locations?.operations.first?.request.workspaceID, original)
    }

    func testAuthenticatedManualAgentGetsSiblingWithoutStealingOtherSelection() throws {
        var state = WorkspaceState(); let original = state.newWorkspace(directory: "/tmp")
        let supportID = try XCTUnwrap(state.newTab()); try agent(&state, supportID, tool: .shell)
        let binding = try XCTUnwrap(state.tab(supportID)?.binding)
        let other = state.newWorkspace(directory: "/tmp/other")
        let event = AgentEvent(bindingID: binding.id, invocationID: UUID(), secret: UUID(), provider: .codex, kind: .attached, sessionID: "manual-session")
        XCTAssertEqual(state.recordAgentEvent(event), supportID)
        XCTAssertEqual(state.selectedWorkspaceID, other)
        let conversation = try XCTUnwrap(state.workspace(for: ConversationID(provider: .codex, sessionID: "manual-session")))
        XCTAssertNotEqual(conversation.id, original); XCTAssertEqual(conversation.primaryTerminalID, supportID)
        XCTAssertEqual(conversation.primaryTerminal?.binding, binding); try state.validate()
    }

    func testClosedSupportingTerminalIsDiscoverableAndReopensSameRecord() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let primary = try XCTUnwrap(state.primaryTerminalID), shell = try XCTUnwrap(state.newTab())
        try agent(&state, shell, tool: .shell)
        let record = state.tab(shell)
        state.closeSupport(shell)
        XCTAssertEqual(state.selected?.retainedSupportingTerminals.map(\.id), [shell])
        XCTAssertEqual(state.tab(shell), record); XCTAssertEqual(state.primaryTerminalID, primary)
        let supportID = try XCTUnwrap(state.openSupport(.terminal(tabID: shell), title: "Retained shell"))
        XCTAssertEqual(state.selected?.support?.selectedTabID, supportID)
        XCTAssertEqual(state.selectedTab?.id, shell); XCTAssertEqual(state.tab(shell), record)
        XCTAssertTrue(state.selected?.retainedSupportingTerminals.isEmpty == true); try state.validate()
    }

    func testCatalogDiscoveryDoesNotSelectReopenExpandOrChangeDraftsAndBindings() throws {
        var state = WorkspaceState()
        let location = WorkspaceLocation(path: "/tmp/project", checkoutIdentity: "/tmp/project/.git")
        let projectID = state.registerProject(location)
        let active = state.newWorkspace(location: location, projectID: projectID)
        let terminal = try XCTUnwrap(state.primaryTerminalID); try agent(&state, terminal, tool: .shell)
        let closedID = ConversationID(provider: .codex, sessionID: "already-closed")
        let closed = state.ensureConversationWorkspace(closedID, location: location, projectID: projectID)
        state.editDraft(state.primaryTerminalID!, prompt: "retain closed draft")
        state.hideWorkspace(closed); state.selectWorkspace(active); state.setProjectCollapsed(projectID, true)
        let before = state, lastTool = state.lastTool
        XCTAssertEqual(state.ensureConversationWorkspace(closedID, location: location, projectID: projectID, select: false), closed)
        for id in ["external-one", "external-two"] {
            let discovered = state.ensureConversationWorkspace(ConversationID(provider: .claude, sessionID: id), location: location, projectID: projectID, select: false)
            XCTAssertTrue(state.workspaces.first { $0.id == discovered }?.viewClosed == true)
        }
        XCTAssertEqual(state.selectedWorkspaceID, active); XCTAssertEqual(state.projects, before.projects)
        XCTAssertEqual(state.lastTool, lastTool)
        for workspace in before.workspaces { XCTAssertEqual(state.workspaces.first { $0.id == workspace.id }, workspace) }
        XCTAssertEqual(state.tab(terminal)?.binding, before.tab(terminal)?.binding)
        state.selectWorkspace(closed); XCTAssertFalse(state.selected?.viewClosed == true)
        XCTAssertEqual(state.projects.first?.isCollapsed, false); try state.validate()
    }

    private func legacyDatabase(_ path: String, payload: Data, rejectUpdate: Bool = false) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE workspace_snapshot (id INTEGER PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for version in 1...5 { try db.execute(sql: "INSERT INTO grdb_migrations VALUES (?)", arguments: ["workspace-v\(version)"]) }
            try db.execute(sql: "INSERT INTO workspace_snapshot VALUES (1, 5, ?)", arguments: [payload])
            if rejectUpdate { try db.execute(sql: "CREATE TRIGGER interrupted BEFORE UPDATE ON workspace_snapshot BEGIN SELECT RAISE(ABORT, 'interrupted fixture'); END") }
        }
        return queue
    }
    func testAtomicMigrationBackupAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PrivateFiles.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        var state = WorkspaceState(); state.version = 5; state.newWorkspace(directory: "/tmp")
        try agent(&state, state.selectedTab!.id, tool: .codex, session: "one")
        state.newTab(); state.editDraft(state.selectedTab!.id, tool: .claude, prompt: "draft")
        let payload = try JSONEncoder().encode(state)
        let path = root.appendingPathComponent("state.sqlite").path
        let queue = try legacyDatabase(path, payload: payload)
        let database = try WorkspaceDatabase(path: path), loaded = try await database.load()
        XCTAssertEqual(loaded?.version, 8); XCTAssertEqual(loaded?.workspaces.count, 2)
        for tab in state.workspaces.flatMap(\.tabs) { XCTAssertEqual(loaded?.tab(tab.id), tab) }
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.contains("pre-v6") })
        let backupQueue = try DatabaseQueue(path: root.appendingPathComponent(backup).path)
        let backupBytes = try await backupQueue.read { try Data.fetchOne($0, sql: "SELECT payload FROM workspace_snapshot") }
        let migratedVersion = try await queue.read { try Int.fetchOne($0, sql: "SELECT version FROM workspace_snapshot") }
        XCTAssertEqual(backupBytes, payload); XCTAssertEqual(migratedVersion, 8)
        let reopened = try WorkspaceDatabase(path: path), again = try await reopened.load(); XCTAssertEqual(loaded, again)
    }
    func testInterruptedAndInvalidMigrationPreserveOriginalPayloadAndVersion() throws {
        for interrupted in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try PrivateFiles.directory(root); defer { try? FileManager.default.removeItem(at: root) }
            var state = WorkspaceState(); state.version = 5; state.newWorkspace(directory: "/tmp")
            let payload = interrupted ? try JSONEncoder().encode(state) : Data("invalid snapshot".utf8)
            let path = root.appendingPathComponent("state.sqlite").path
            let queue = try legacyDatabase(path, payload: payload, rejectUpdate: interrupted)
            XCTAssertThrowsError(try WorkspaceDatabase(path: path))
            XCTAssertEqual(try queue.read { try Data.fetchOne($0, sql: "SELECT payload FROM workspace_snapshot") }, payload)
            XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT version FROM workspace_snapshot") }, 5)
            XCTAssertFalse(try queue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }.contains("workspace-v6"))
        }
    }
}
