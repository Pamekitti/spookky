import XCTest
import GRDB
@testable import SpookkyCore
import SpookkyFiles
import SpookkyPersistence

final class PersistentThreadTests: XCTestCase {
    func testExplicitProjectAssignmentWinsWhenOpeningUncachedThread() throws {
        var state = WorkspaceState()
        let first = state.registerProject(WorkspaceLocation(path: "/tmp/first"))
        let second = state.registerProject(WorkspaceLocation(path: "/tmp/second"))
        let record = ConversationCatalogRecord(metadata: ConversationMetadata(id: ConversationID(provider: .codex, sessionID: "saved-thread"),
            title: "Saved title", directory: "/tmp/original", updatedAt: Date()), projectID: first)
        state.rememberThread(record)
        state.editThread(record.id.threadKey) { $0.hasProjectOverride = true; $0.projectOverride = second }
        state.openCatalogRecord(record)
        XCTAssertEqual(state.selected?.projectID, second)
        XCTAssertEqual(state.selected?.directory, "/tmp/original")
        XCTAssertEqual(state.selected?.conversationID, record.id)
        XCTAssertNil(state.selectedTab?.binding)
        try state.validate()
    }
    func testEndedLandingRepairsWithoutLosingDraftOrFolder() throws {
        var state = WorkspaceState()
        let id = state.showLanding(homeDirectory: "/tmp")
        let terminal = try XCTUnwrap(state.primaryTerminalID)
        state.editDraft(terminal, tool: .claude, prompt: "Keep 日本語 unsent")
        state.updateTab(terminal) { $0.status = .ended }
        state.newWorkspace(directory: "/tmp/other")
        XCTAssertEqual(state.showLanding(homeDirectory: "/tmp"), id)
        XCTAssertEqual(state.selectedTab?.status, .draft)
        XCTAssertEqual(state.selectedTab?.draft.prompt, "Keep 日本語 unsent")
        XCTAssertEqual(state.selected?.selectedLocation.path, "/tmp")
        try state.validate()
    }
    func testLandingWithExecutionIsRetainedAsThread() throws {
        var state = WorkspaceState(); let original = state.showLanding(homeDirectory: "/tmp")
        let terminal = try XCTUnwrap(state.primaryTerminalID)
        state.editDraft(terminal, tool: .codex, prompt: "retain draft")
        let spec = try LaunchSpec(tool: .codex, executable: "/bin/cat", directory: "/tmp")
        state.apply(.preparing, to: terminal)
        state.apply(.intent(spec, .pending), to: terminal)
        let binding = SessionBinding(spec: spec); state.apply(.observed(binding, dead: false, exitCode: nil, prompt: PromptDelivery.none), to: terminal)
        let landing = state.showLanding(homeDirectory: "/tmp")
        XCTAssertNotEqual(landing, original)
        XCTAssertFalse(try XCTUnwrap(state.workspaces.first { $0.id == original }).isLanding)
        XCTAssertEqual(state.tab(terminal)?.binding, binding)
        XCTAssertEqual(state.selectedTab?.draft.prompt, "retain draft")
    }
    func testArchiveAndPinDoNotChangeExecutionAndRoundTrip() throws {
        var state = WorkspaceState(); let id = state.newWorkspace(directory: "/tmp")
        let terminal = try XCTUnwrap(state.primaryTerminalID)
        let spec = try LaunchSpec(tool: .codex, executable: "/bin/cat", directory: "/tmp")
        state.apply(.preparing, to: terminal)
        state.apply(.intent(spec, .none), to: terminal)
        let binding = SessionBinding(spec: spec); state.apply(.observed(binding, dead: false, exitCode: nil, prompt: PromptDelivery.none), to: terminal)
        let key = try XCTUnwrap(state.selected).threadKey
        state.editThread(key) { $0.pinnedAt = Date(); $0.archivedAt = Date() }
        XCTAssertTrue(state.selected?.isLanding == true)
        XCTAssertEqual(state.tab(terminal)?.binding, binding)
        let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertNotNil(restored.presentation(for: key).pinnedAt)
        XCTAssertNotNil(restored.presentation(for: key).archivedAt)
        XCTAssertTrue(restored.workspaces.contains { $0.id == id })
        try restored.validate()
    }
    func testStartPagesHaveDistinctIdentityAndLastSupportReturnsToPrimary() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let primary = state.primaryTerminalID
        let first = try XCTUnwrap(state.openSupport(.startPage, title: "New tab"))
        let second = try XCTUnwrap(state.openSupport(.startPage, title: "New tab"))
        XCTAssertNotEqual(first, second)
        state.updateSupport(first, target: .browser(url: "https://example.com"), title: "Example")
        state.closeSupport(second)
        XCTAssertEqual(state.selected?.support?.selectedTabID, first)
        state.closeSupport(first)
        XCTAssertEqual(state.primaryTerminalID, primary)
        XCTAssertEqual(state.selected?.support?.resolvedFullWidthSelection, .primary)
        try state.validate()
    }
    func testV7MigrationBacksUpAndPreservesStableThreadState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("workspace.sqlite").path
        _ = try WorkspaceDatabase(path: path)
        var old = WorkspaceState(); old.version = 7
        let id = old.newWorkspace(directory: "/tmp"); old.renameWorkspace(id, "Alias")
        old.openSupport(.file(path: "README.md"), title: "README.md")
        old.hideWorkspace(id)
        let queue = try DatabaseQueue(path: path)
        let payload = try JSONEncoder().encode(old)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'workspace-v8'")
            try db.execute(sql: "INSERT INTO workspace_snapshot VALUES (1,7,?)", arguments: [payload])
        }
        let database = try WorkspaceDatabase(path: path)
        let loaded = try await database.load()
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.version, 8)
        let workspace = try XCTUnwrap(restored.workspaces.first { $0.id == id })
        XCTAssertEqual(workspace.title, "Alias"); XCTAssertEqual(workspace.viewClosed, false)
        XCTAssertEqual(workspace.support, old.workspaces.first { $0.id == id }?.support)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.contains("pre-v8") })
    }
    func testMarkdownEscapesSourceAndRendersSemanticTablesAndCode() throws {
        let html = try MarkdownDocument.html("# Heading\n\n| A | B |\n| - | - |\n| one | two |\n\n```html\n<script>alert(1)</script>\n```\n\n[bad](javascript:alert(1))")
        XCTAssertTrue(html.contains("<h1>Heading</h1>")); XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<th>A</th>")); XCTAssertTrue(html.contains("<pre>"))
        XCTAssertTrue(html.contains("&lt;script&gt;")); XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("href=\"javascript:"))
    }
    func testSubmittedAddressDistinguishesSearchFromNavigation() {
        XCTAssertEqual(BrowserAddress.submitted("localhost:3000"), "http://localhost:3000")
        XCTAssertTrue(BrowserAddress.submitted("a search & question")?.contains("duckduckgo.com") == true)
        XCTAssertNil(BrowserAddress.submitted("javascript:alert(1)"))
    }
}
