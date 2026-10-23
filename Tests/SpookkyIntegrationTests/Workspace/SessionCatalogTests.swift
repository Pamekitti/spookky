import XCTest
import SpookkyCore
import SpookkyRuntime
@testable import SpookkyWorkspace

final class SessionCatalogTests: XCTestCase {
    private let first = "00000000-0000-4000-8000-000000000001"
    private let second = "00000000-0000-4000-8000-000000000002"
    private func temporary() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/spookky-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testProviderCollisionAndDuplicateReconciliation() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let old = ConversationMetadata(id: ConversationID(provider: .codex, sessionID: first), title: "Old", directory: root.path, updatedAt: .distantPast)
        let renamed = ConversationMetadata(id: old.id, title: "Renamed", directory: root.path, updatedAt: Date())
        let claude = ConversationMetadata(id: ConversationID(provider: .claude, sessionID: first), title: "Different provider", directory: root.path, updatedAt: Date())
        let result = SessionCatalog.reconcile([renamed, old, claude])
        XCTAssertEqual(result.conversations.count, 2)
        XCTAssertEqual(result.conversations.first { $0.id == old.id }?.title, "Renamed")
        let conflicting = ConversationMetadata(id: old.id, title: "Conflict", directory: root.appendingPathComponent("other").path, updatedAt: Date())
        XCTAssertEqual(SessionCatalog.reconcile([old, conflicting]).conversations.first?.availability, .historyUnavailable)
    }
    func testMissingFolderAndPathBoundaryAreHonest() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let a = ConversationMetadata(id: ConversationID(provider: .codex, sessionID: first), title: "Café 日本語", directory: root.path, updatedAt: Date())
        let b = ConversationMetadata(id: ConversationID(provider: .codex, sessionID: second), title: nil, directory: root.path + "-other", updatedAt: Date())
        let result = SessionCatalog.reconcile([a,b])
        XCTAssertEqual(result.conversations.first { $0.id == b.id }?.availability, .folderUnavailable)
        XCTAssertEqual(SessionCatalog.matching(result.conversations, directories: [root.path], search: "café").map(\.id), [a.id])
        XCTAssertEqual(SessionCatalog.matching(result.conversations, directories: [root.path]).count, 1)
    }
    func testCodexMetadataUsesNameAndExactCwdWithoutPreview() throws {
        let row: [String: Any] = ["id": first, "cwd": "/tmp/fixture worktree/subdir", "name": "Renamed locally", "preview": "PRIVATE PROMPT MUST NOT BE A TITLE", "updatedAt": 123.0, "source": "appServer", "projectId": "provider-project"]
        let item = try XCTUnwrap(CodexHistoryReader.metadata(row))
        XCTAssertEqual(item.title, "Renamed locally")
        XCTAssertEqual(item.directory, "/tmp/fixture worktree/subdir")
        XCTAssertEqual(item.providerProjectID, "provider-project")
        var unnamed = row; unnamed.removeValue(forKey: "name")
        XCTAssertNil(CodexHistoryReader.metadata(unnamed)?.title)
        unnamed["id"] = "--last"; XCTAssertNil(CodexHistoryReader.metadata(unnamed))
    }
    func testClaudeIncrementalRefreshRenameDeleteAndLargeTranscript() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let bucket = root.appendingPathComponent("projects/encoded")
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        let file = bucket.appendingPathComponent(first + ".jsonl")
        let cwd = root.appendingPathComponent("checkout"); try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        func line(_ value: [String: Any]) throws -> Data { var d = try JSONSerialization.data(withJSONObject: value); d.append(10); return d }
        var data = try line(["type": "user", "sessionId": first, "cwd": cwd.path, "message": ["content": "private fixture text"]])
        data.append(Data(repeating: 32, count: 2_000_000)); data.append(10)
        data.append(try line(["type": "custom-title", "sessionId": first, "customTitle": "Original title"]))
        try data.write(to: file)
        var reader = ClaudeHistoryReader()
        XCTAssertEqual(reader.read(root: root.appendingPathComponent("projects")).conversations.first?.title, "Original title")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: line(["type": "custom-title", "sessionId": first, "customTitle": "Renamed title"]))
        try handle.close()
        let renamed = reader.read(root: root.appendingPathComponent("projects"))
        XCTAssertEqual(renamed.conversations.first?.title, "Renamed title")
        XCTAssertEqual(renamed.conversations.first?.directory, cwd.path)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(reader.read(root: root.appendingPathComponent("projects")).conversations.isEmpty)
        XCTAssertTrue(reader.cache.isEmpty)
    }
    func testMalformedClaudeMetadataIsReportedWithoutPromptFallback() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let bucket = root.appendingPathComponent("bucket"); try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        try Data("malformed\n".utf8).write(to: bucket.appendingPathComponent(first + ".jsonl"))
        var reader = ClaudeHistoryReader(); let result = reader.read(root: root)
        XCTAssertTrue(result.conversations.isEmpty); XCTAssertFalse(result.issues.isEmpty)
    }
}

private struct HistoryResolver: ExecutableResolver {
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try LaunchSpec(tool: tool, executable: "/bin/cat", directory: directory)
    }
}
private actor HistoryRuntime: SessionRuntime {
    var specs: [LaunchSpec] = []
    func launches() -> [LaunchSpec] { specs }
    func create(_ spec: LaunchSpec) async throws -> SessionBinding { specs.append(spec); return SessionBinding(spec: spec) }
    func inspect(_ binding: SessionBinding) async throws -> SessionObservation? { nil }
    func list() async throws -> [SessionBinding] { [] }
    func attachmentArguments(_ binding: SessionBinding) async throws -> [String] { [] }
    func terminate(_ binding: SessionBinding) async throws {}
}
@MainActor final class HistoryResumeTests: XCTestCase {
    func testExactResumeDoesNotSendPromptOrChangeWorkspaceAnchor() async throws {
        let runtime = HistoryRuntime(), store = WorkspaceStore()
        store.update { $0.newWorkspace(directory: "/tmp/fixture-checkout") }
        let tab = try XCTUnwrap(store.state.selectedTab?.id)
        let item = ConversationMetadata(id: ConversationID(provider: .codex, sessionID: "00000000-0000-4000-8000-000000000001"), title: "Resume", directory: "/tmp/fixture-checkout/subdir", updatedAt: Date())
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: HistoryResolver())
        await coordinator.resume(tab, conversation: item)
        let specs = await runtime.launches()
        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs.first?.arguments, ["resume", item.id.sessionID, "--cd", item.directory])
        XCTAssertEqual(specs.first?.directory, item.directory)
        XCTAssertEqual(store.state.selected?.directory, "/tmp/fixture-checkout")
        XCTAssertEqual(store.state.selectedTab?.promptDelivery, PromptDelivery.none)
        await coordinator.resume(tab, conversation: item)
        let count = await runtime.launches().count; XCTAssertEqual(count, 1)
    }
    func testResumePreservesDraftAndRejectsUnavailableOrInvalidIDs() async throws {
        let runtime = HistoryRuntime(), store = WorkspaceStore()
        store.update { $0.newWorkspace(directory: "/tmp"); $0.editDraft($0.selectedTab!.id, tool: .codex, prompt: "Unsent draft") }
        let tab = try XCTUnwrap(store.state.selectedTab?.id)
        let item = ConversationMetadata(id: ConversationID(provider: .codex, sessionID: "--last"), title: nil, directory: "/tmp", updatedAt: Date())
        await LaunchCoordinator(store: store, runtime: runtime, resolver: HistoryResolver()).resume(tab, conversation: item)
        XCTAssertEqual(store.state.selectedTab?.draft.prompt, "Unsent draft")
        let count = await runtime.launches().count; XCTAssertEqual(count, 0)
    }
}

extension SessionCatalogTests {
}

extension HistoryResumeTests {
    func testExplicitEndedResumeRetainsDraftWithoutResendingOriginalPrompt() async throws {
        let runtime = HistoryRuntime(), store = WorkspaceStore()
        store.update { $0.newWorkspace(directory: "/tmp"); $0.editDraft($0.selectedTab!.id, tool: .codex, prompt: "Original delivered instruction") }
        let tab = try XCTUnwrap(store.state.selectedTab?.id)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: HistoryResolver())
        await coordinator.launch(tab)
        let binding = try XCTUnwrap(store.state.tab(tab)?.binding)
        store.update { $0.apply(.observed(binding, dead: true, exitCode: 0, prompt: .suppliedToProcess), to: tab) }
        let item = ConversationMetadata(id: ConversationID(provider: .codex, sessionID: "00000000-0000-4000-8000-000000000001"), title: "Saved", directory: "/tmp", updatedAt: Date())
        await coordinator.resume(tab, conversation: item)
        let specs = await runtime.launches()
        XCTAssertEqual(specs.count, 2)
        XCTAssertEqual(specs.last?.arguments, ["resume", item.id.sessionID, "--cd", item.directory])
        XCTAssertEqual(store.state.tab(tab)?.draft.prompt, "Original delivered instruction")
        XCTAssertEqual(store.state.tab(tab)?.promptDelivery, PromptDelivery.none)
        await coordinator.resume(tab, conversation: item)
        let count = await runtime.launches().count; XCTAssertEqual(count, 2)
    }
}
