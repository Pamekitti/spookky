import XCTest
import SpookkyCore
import SpookkyGit
import SpookkyPersistence
@testable import SpookkyWorkspace

private struct CatalogNoGit: GitCommandExecutor {
    var isAvailable: Bool { false }
    func execute(_ arguments: [String]) async throws -> GitResult { throw LaunchError.invalid("Unexpected Git call") }
}
final class ConversationCatalogReconcilerTests: XCTestCase {
    func testHundredsOfSavedConversationsAreLazyStableAndFullySearchable() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/spookky-history-reconcile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = WorkspaceState()
        let project = state.registerProject(WorkspaceLocation(path: root.path))
        state.newWorkspace(directory: root.path)
        let selected = state.selectedWorkspaceID, originalTool = state.lastTool
        state.setProjectCollapsed(project, true)
        let items = (0..<600).map { i in
            ConversationMetadata(id: ConversationID(provider: i == 599 ? .claude : .codex,
                sessionID: String(format: "00000000-0000-4000-8000-%012d", i == 599 ? 0 : i)),
                title: "Saved \(i)", directory: root.path, updatedAt: Date(timeIntervalSince1970: Double(i)))
        }
        let resolver = ProjectAssociationResolver(git: GitRepository(executor: CatalogNoGit()))
        let batch = try await resolver.resolveBatch(directories: Array(Set(items.map(\.directory))), projects: state.projects)
        XCTAssertEqual(batch.uniqueDirectoryCount, 1)
        let start = ProcessInfo.processInfo.systemUptime
        ConversationCatalogReconciler.apply(SessionCatalogSnapshot(conversations: items), batch: batch, to: &state)
        print("600-history reconciliation milliseconds=\(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))")
        XCTAssertEqual(state.selectedWorkspaceID, selected); XCTAssertEqual(state.lastTool, originalTool)
        XCTAssertEqual(state.projects.first?.isCollapsed, true)
        let saved = state.workspaces.filter { $0.conversationID != nil }
        XCTAssertEqual(saved.count, 600)
        XCTAssertTrue(saved.allSatisfy { $0.viewClosed == true && $0.primaryTerminal?.binding == nil && $0.primaryTerminal?.launch == nil })
        XCTAssertEqual(ConversationSidebarPage(state: state).workspaces.count, 1)
        let searchPage = ConversationSidebarPage(state: state, query: "Saved")
        XCTAssertLessThanOrEqual(searchPage.workspaces.count, 50)
        XCTAssertEqual(searchPage.matchingCount, 600)
        XCTAssertGreaterThan(searchPage.remaining, 500)
        XCTAssertEqual(state.projects.first?.isCollapsed, true)
        let oldest = try XCTUnwrap(saved.first { $0.conversationID == items[0].id })
        XCTAssertEqual(ConversationSidebarPage(state: state, query: items[0].id.sessionID).workspaces.count, 2) // separate provider collision stays distinct
        XCTAssertEqual(ConversationSidebarPage(state: state, query: "Saved 0").workspaces.map(\.id), [oldest.id])
        state.selectWorkspace(oldest.id)
        state.renameWorkspace(oldest.id, "Local alias")
        state.openSupport(.browser(url: "about:blank"), title: "Keep form", workspaceID: oldest.id)
        state.editDraft(oldest.primaryTerminalID!, prompt: "Keep unsent draft")
        state.hideWorkspace(oldest.id)
        let retained = state.workspaces.first { $0.id == oldest.id }!
        let ids = Set(saved.map(\.id))
        let nilTitle = ConversationMetadata(id: items[0].id, title: nil, directory: root.path, updatedAt: Date())
        ConversationCatalogReconciler.apply(SessionCatalogSnapshot(conversations: [nilTitle], truncated: true), batch: batch, to: &state)
        XCTAssertEqual(Set(state.workspaces.filter { $0.conversationID != nil }.map(\.id)), ids)
        let refreshed = state.workspaces.first { $0.id == oldest.id }!
        XCTAssertEqual(refreshed.title, "Local alias"); XCTAssertEqual(refreshed.viewClosed, true)
        XCTAssertEqual(refreshed.primaryTerminal?.draft, retained.primaryTerminal?.draft)
        XCTAssertEqual(refreshed.support, retained.support); XCTAssertEqual(refreshed.catalogMetadata?.title, items[0].title)
        XCTAssertTrue(state.workspaces.filter { $0.conversationID != nil }.allSatisfy { $0.catalogMetadata?.availability == .local })
        ConversationCatalogReconciler.apply(SessionCatalogSnapshot(conversations: [], issues: [SessionCatalogIssue(.codex, "Unavailable"), SessionCatalogIssue(.claude, "Unavailable")]), batch: batch, to: &state)
        XCTAssertEqual(state.workspaces.first { $0.id == oldest.id }?.catalogMetadata?.availability, .local)
        let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.workspaces.first { $0.id == oldest.id }?.catalogMetadata?.title, items[0].title)
        try restored.validate()
    }
    func testCompleteMissingHistoryIsRetainedAsUnavailable() async throws {
        let resolver = ProjectAssociationResolver(git: GitRepository(executor: CatalogNoGit()))
        var state = WorkspaceState()
        let item = ConversationMetadata(id: ConversationID(provider: .codex, sessionID: UUID().uuidString), title: "Known title", directory: "/tmp", updatedAt: Date())
        let batch = try await resolver.resolveBatch(directories: [item.directory], projects: [])
        ConversationCatalogReconciler.apply(SessionCatalogSnapshot(conversations: [item]), batch: batch, to: &state)
        let id = state.workspaces[0].id
        ConversationCatalogReconciler.apply(SessionCatalogSnapshot(conversations: []), batch: batch, to: &state)
        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.workspaces[0].id, id)
        XCTAssertEqual(state.workspaces[0].catalogMetadata?.availability, .historyUnavailable)
    }
    func testClaudeTitleSurvivesPartialWindowsThenAcceptsRename() throws {
        let root = URL(fileURLWithPath: "/private/tmp/spookky-growing-history-" + UUID().uuidString)
        let bucket = root.appendingPathComponent("bucket")
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "00000000-0000-4000-8000-000000000001", file = bucket.appendingPathComponent("00000000-0000-4000-8000-000000000001.jsonl")
        func record(_ value: [String: Any]) throws -> Data { var data = try JSONSerialization.data(withJSONObject: value); data.append(10); return data }
        var bytes = try record(["type": "user", "sessionId": id, "cwd": root.path])
        bytes.append(Data(repeating: 32, count: 100_000)); bytes.append(10)
        bytes.append(try record(["type": "custom-title", "sessionId": id, "customTitle": "Known rename"]))
        try bytes.write(to: file)
        var reader = ClaudeHistoryReader()
        XCTAssertEqual(reader.read(root: root).conversations.first?.title, "Known rename")
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 32, count: 100_000)); try handle.write(contentsOf: Data([10]))
        XCTAssertEqual(reader.read(root: root).conversations.first?.title, "Known rename")
        try handle.write(contentsOf: record(["type": "custom-title", "sessionId": id, "customTitle": "New rename"]))
        XCTAssertEqual(reader.read(root: root).conversations.first?.title, "New rename")
    }
}
