import XCTest
import GRDB
import SpookkyCore
import SpookkyPersistence

final class WorkspaceNamingTests: XCTestCase {
    func testFriendlyNamesAreUniqueAndExhaustionIsBounded() {
        var state = WorkspaceState()
        for _ in 0..<64 { state.newWorkspace(directory: "/tmp") }
        let titles = state.workspaces.map(\.title)
        XCTAssertEqual(Set(titles.map { $0.lowercased() }).count, 64)
        XCTAssertTrue(titles.allSatisfy { $0.split(separator: " ").count == 2 })
        XCTAssertEqual(WorkspaceNaming.friendly(excluding: titles + ["QUIET MAPLE 2"]), "Quiet Maple 3")
        let title = state.selected!.title
        state.bindWorkspace(state.selectedWorkspaceID!)
        XCTAssertEqual(state.selected?.title, title)
    }

    func testPromptTitleHandlesWhitespaceLineBoundariesAndUnicode() {
        XCTAssertNil(WorkspaceNaming.promptTitle(" \t\n\r\n"))
        XCTAssertEqual(WorkspaceNaming.promptTitle("\n \t\n Fix\t login   timeout\nIgnore this line"), "Fix login timeout")
        XCTAssertEqual(WorkspaceNaming.promptTitle("one two three four five six seven"), "one two three four five six")
        XCTAssertEqual(WorkspaceNaming.promptTitle(String(repeating: "界", count: 100)), String(repeating: "界", count: 48))
        XCTAssertEqual(WorkspaceNaming.promptTitle(String(repeating: "👩🏽‍💻", count: 100)), String(repeating: "👩🏽‍💻", count: 48))
        XCTAssertEqual(WorkspaceNaming.promptTitle(String(repeating: "x", count: 47) + " y"), String(repeating: "x", count: 47))
    }

    private func intent(_ state: inout WorkspaceState, tool: SessionTool, prompt: String) throws -> LaunchSpec {
        let id = state.selectedTab!.id
        state.editDraft(id, tool: tool, prompt: prompt)
        let spec = try LaunchSpec(tool: tool, executable: "/bin/cat", directory: "/tmp",
                                  initialPrompt: tool == .shell ? nil : prompt)
        state.apply(.preparing, to: id)
        state.bindWorkspace(state.selectedWorkspaceID!)
        state.apply(.intent(spec, tool == .shell || prompt.isEmpty ? .none : .pending), to: id)
        return spec
    }

    func testFirstLaterAgentPromptNamesWorkspaceAndRetryKeepsIt() throws {
        var state = WorkspaceState(); let workspace = state.newWorkspace(directory: "/tmp/workspace-deadbeef")
        let title = state.selected!.title
        _ = try intent(&state, tool: .shell, prompt: "Retained agent draft")
        XCTAssertEqual(state.selected?.title, title)
        state.newTab(); _ = try intent(&state, tool: .codex, prompt: " \n ")
        XCTAssertEqual(state.selected?.title, title)
        state.newTab()
        let spec = try intent(&state, tool: .claude, prompt: "Fix login timeout\nContext")
        let tab = state.selectedTab!.id
        XCTAssertEqual(state.selected?.title, "Fix login timeout")
        XCTAssertEqual(state.selected?.automaticTitle, .prompt)
        XCTAssertEqual(spec.arguments, ["--", "Fix login timeout\nContext"])
        state.apply(.failure(.failed, TabFailure(.validation, "Launch failed"), clearIntent: true), to: tab)
        _ = try intent(&state, tool: .claude, prompt: "Different retry prompt")
        XCTAssertEqual(state.selected?.title, "Fix login timeout")
        state.newTab(); _ = try intent(&state, tool: .codex, prompt: "Another task")
        XCTAssertEqual(state.selected?.title, "Fix login timeout")
        XCTAssertEqual(state.selectedWorkspaceID, workspace)
        XCTAssertEqual(state.selected?.directory, "/tmp/workspace-deadbeef")
        let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
    }

    func testManualNameWinsAndRejectedIntentCannotRename() throws {
        var state = WorkspaceState(); let workspace = state.newWorkspace(directory: "/tmp")
        state.renameWorkspace(workspace, "My work")
        _ = try intent(&state, tool: .codex, prompt: "Fix login")
        XCTAssertEqual(state.selected?.title, "My work")
        state.newWorkspace(directory: "/tmp")
        let title = state.selected!.title, tab = state.selectedTab!.id
        state.editDraft(tab, tool: .codex, prompt: "Rejected launch")
        let spec = try LaunchSpec(tool: .codex, executable: "/bin/cat", directory: "/tmp", initialPrompt: "Rejected launch")
        state.apply(.intent(spec, .pending), to: tab)
        XCTAssertEqual(state.selected?.title, title)
        XCTAssertNil(state.selectedTab?.launch)
    }

    func testLegacyMigrationPreservesReadableNamesDraftsBindingsAndBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite").path
        var state = WorkspaceState(); state.version = 3
        for name in ["workspace-deadbeef", "New workspace", "Home", "My task", "workspace-01234567", "workspace-not-a-hash"] {
            let workspace = state.newWorkspace(directory: "/tmp/" + name)
            state.renameWorkspace(workspace, name)
        }
        let tab = state.workspaces[0].selectedTabID
        state.editDraft(tab, tool: .codex, prompt: "Retain unsent 日本語\nContext")
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let live = state.workspaces[2].selectedTabID
        state.apply(.preparing, to: live); state.apply(.intent(spec, .none), to: live)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: live)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var workspaces = try XCTUnwrap(object["workspaces"] as? [[String: Any]])
        for index in workspaces.indices {
            workspaces[index].removeValue(forKey: "automaticTitle")
            workspaces[index]["customTitle"] = index == 3 || index == 4
        }
        object["workspaces"] = workspaces
        let payload = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(WorkspaceState.self, from: payload)
        let queue = try DatabaseQueue(path: path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE workspace_snapshot (id INTEGER PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('workspace-v1'), ('workspace-v2'), ('workspace-v3')")
            try db.execute(sql: "INSERT INTO workspace_snapshot VALUES (1, 3, ?)", arguments: [payload])
        }
        let database = try WorkspaceDatabase(path: path)
        let loaded = try await database.load(), restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.version, 5)
        XCTAssertEqual(restored.workspaces.map(\.id), legacy.workspaces.map(\.id))
        XCTAssertEqual(restored.workspaces.map(\.tabs), legacy.workspaces.map(\.tabs))
        XCTAssertEqual(restored.workspaces.map(\.selectedLocation), legacy.workspaces.map(\.selectedLocation))
        XCTAssertEqual(restored.selectedWorkspaceID, legacy.selectedWorkspaceID)
        XCTAssertEqual(restored.workspaces.prefix(2).map(\.automaticTitle), [.friendly, .friendly])
        XCTAssertTrue(restored.workspaces.prefix(2).allSatisfy { !WorkspaceNaming.isGeneric($0.title) })
        XCTAssertEqual(restored.workspaces.dropFirst(2).map(\.title), ["Home", "My task", "workspace-01234567", "workspace-not-a-hash"])
        try await database.save(restored)
        let reopened = try WorkspaceDatabase(path: path)
        let again = try await reopened.load(); XCTAssertEqual(again, restored)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.contains("pre-v5") })
        let preserved = try DatabaseQueue(path: root.appendingPathComponent(backup).path)
        let bytes = try await preserved.read { try Data.fetchOne($0, sql: "SELECT payload FROM workspace_snapshot") }
        XCTAssertEqual(bytes, payload)
    }

    func testActivityOnlyVersionFourMigrationPreservesUnreadAndDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PrivateFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite").path
        var state = WorkspaceState(); state.version = 4
        let workspace = state.newWorkspace(directory: "/tmp")
        state.renameWorkspace(workspace, "New workspace")
        let tab = state.selectedTab!.id
        let spec = try LaunchSpec(tool: .codex, executable: "/bin/cat", directory: "/tmp")
        state.apply(.preparing, to: tab); state.apply(.intent(spec, .none), to: tab)
        state.recordAgentEvent(AgentEvent(bindingID: spec.operationID, invocationID: UUID(), secret: UUID(), provider: .codex, kind: .finished))
        state.newTab()
        state.editDraft(state.selectedTab!.id, tool: .claude, prompt: "Retain unsent 日本語")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var workspaces = try XCTUnwrap(object["workspaces"] as? [[String: Any]])
        workspaces[0].removeValue(forKey: "automaticTitle"); workspaces[0]["customTitle"] = false
        object["workspaces"] = workspaces
        let payload = try JSONSerialization.data(withJSONObject: object)
        let queue = try DatabaseQueue(path: path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE workspace_snapshot (id INTEGER PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for version in 1...4 { try db.execute(sql: "INSERT INTO grdb_migrations VALUES (?)", arguments: ["workspace-v\(version)"]) }
            try db.execute(sql: "INSERT INTO workspace_snapshot VALUES (1, 4, ?)", arguments: [payload])
        }
        let database = try WorkspaceDatabase(path: path)
        let loaded = try await database.load(), restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.version, 5)
        XCTAssertEqual(restored.selected?.automaticTitle, .friendly)
        XCTAssertFalse(WorkspaceNaming.isGeneric(restored.selected!.title))
        XCTAssertEqual(restored.workspaces[0].tabs, state.workspaces[0].tabs)
        XCTAssertTrue(restored.tab(tab)?.activity?.unread == true)
        XCTAssertEqual(restored.selectedTab?.draft.prompt, "Retain unsent 日本語")
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.contains("pre-v5") })
        let preserved = try DatabaseQueue(path: root.appendingPathComponent(backup).path)
        let bytes = try await preserved.read { try Data.fetchOne($0, sql: "SELECT payload FROM workspace_snapshot") }
        XCTAssertEqual(bytes, payload)
    }

    func testGeneratedBranchRecognitionUsesWorkspaceIdentity() {
        let id = UUID()
        XCTAssertTrue(WorkspaceNaming.isGeneratedBranch("spookky/workspace-" + id.uuidString.prefix(8).lowercased(), workspaceID: id))
        XCTAssertFalse(WorkspaceNaming.isGeneratedBranch("fix/login-timeout", workspaceID: id))
        XCTAssertFalse(WorkspaceNaming.isGeneratedBranch(nil, workspaceID: id))
    }

    func testFutureSnapshotIsRejectedWithoutChangingPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite").path
        var state = WorkspaceState(); state.version = 6; state.newWorkspace(directory: "/tmp")
        let payload = try JSONEncoder().encode(state), queue = try DatabaseQueue(path: path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE workspace_snapshot (id INTEGER PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('workspace-v1'), ('workspace-v2'), ('workspace-v3')")
            try db.execute(sql: "INSERT INTO workspace_snapshot VALUES (1, 6, ?)", arguments: [payload])
        }
        XCTAssertThrowsError(try WorkspaceDatabase(path: path))
        let bytes = try await queue.read { try Data.fetchOne($0, sql: "SELECT payload FROM workspace_snapshot") }
        XCTAssertEqual(bytes, payload)
    }
}
