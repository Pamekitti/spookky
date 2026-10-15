import XCTest
import SpookkyCore
import SpookkyWorkspace
import SpookkyPersistence
import SpookkyRuntime

final class PersistenceTests: XCTestCase {
    func testDraftProjectsAndSplitRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-db-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        var state = WorkspaceState()
        let location = WorkspaceLocation(path: "/tmp/café/日本語", checkoutIdentity: "/tmp/.git", branch: "dev")
        let project = state.registerProject(location)
        state.newWorkspace(location: location, projectID: project)
        let first = try XCTUnwrap(state.selectedTab?.id)
        let text = String(repeating: "Draft 日本語\n", count: 1000)
        state.editDraft(first, tool: .claude, prompt: text)
        let second = try XCTUnwrap(state.newTab())
        state.setSplit(first: first, second: second); state.setSplitFraction(0.63)
        state.sidebarCollapsed = true; state.appearance = .light
        try await database.save(state)
        let restored = try await database.load()
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored?.tab(first)?.draft.prompt, text)
    }
    func testEmptySavedStateDoesNotBecomeFirstUse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-db-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        let initial = try await db.load(); XCTAssertNil(initial)
        try await db.save(WorkspaceState())
        let restored = try await db.load(); XCTAssertNotNil(restored); XCTAssertTrue(restored!.workspaces.isEmpty)
    }
    func testRealRuntimeRestoresSameBinding() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-m1-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/spookky-launch").path
        let runtime = try TmuxRuntime(executable: PackagedRuntime.tmux(), helper: helper, root: root.appendingPathComponent("rt"))
        let socket = await runtime.socket
        defer { _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"]) }
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let binding = try await runtime.create(spec)
        let before = try await runtime.inspect(binding)
        let db = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        state.bindWorkspace(state.selectedWorkspaceID!)
        let id = state.selectedTab!.id
        state.apply(.preparing, to: id)
        state.apply(.intent(spec, .none), to: id)
        state.apply(.observed(binding, dead: false, exitCode: nil, prompt: nil), to: id)
        try await db.save(state)
        let restored = try await db.load()
        let after = try await runtime.inspect(restored!.selectedTab!.binding!)
        XCTAssertEqual(before?.processID, after?.processID)
        XCTAssertEqual(restored?.workspaces.count, 1)
        let all = try await runtime.list(); XCTAssertEqual(all.count, 1)
    }
    func testCorruptDatabaseIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-db-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("state.sqlite")
        let content = Data("invalid SQLite fixture".utf8); try content.write(to: path)
        XCTAssertThrowsError(try WorkspaceDatabase(path: path.path))
        XCTAssertEqual(try Data(contentsOf: path), content)
    }
}

extension PersistenceTests {
    func testFileViewRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        var state = WorkspaceState(); let id = state.newWorkspace(directory: "/tmp")
        var view = FileViewState(); view.sidebar = true; view.changes = true; view.preview = true
        view.selectedPath = "src/café.swift"; view.selectedGroup = "Staged"; view.reference = "refs/heads/dev"
        view.expanded = ["src"]; view.scroll = 42; view.fraction = 0.6; view.splitDiff = true
        state.setFileView(view, workspaceID: id); try await database.save(state)
        let restored = try await database.load(); XCTAssertEqual(restored?.selected?.fileView, view)
        XCTAssertEqual(restored?.version, 4)
    }
}
