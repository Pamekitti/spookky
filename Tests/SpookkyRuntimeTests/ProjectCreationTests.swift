import XCTest
import SpookkyCore
import SpookkyGit
import SpookkyWorkspace
import SpookkyPersistence

actor InterruptedSave: WorkspacePersistence {
    var saved: WorkspaceState?
    var count = 0
    let failAt: Int
    init(_ failAt: Int) { self.failAt = failAt }
    func load() async throws -> WorkspaceState? { saved }
    func save(_ state: WorkspaceState) async throws {
        count += 1
        if count >= failAt { throw LaunchError.command("Receipt write interrupted") }
        saved = state
    }
}
private struct RefuseClone: GitCommandExecutor {
    func execute(_ arguments: [String]) async throws -> GitResult {
        GitResult(status: 128, error: "Authentication requires a terminal. Use your Git credential helper and retry.")
    }
}
final class ProjectCreationTests: XCTestCase {
    func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-m2-project-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path
    }
    @MainActor func testCreatePlainAndGitAndNeverOverwrite() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(), coordinator = LocationCoordinator(store: store)
        for initialize in [false, true] {
            var draft = ProjectCreationDraft(parentPath: root.path); draft.name = initialize ? "Git café's 日本語" : "Plain café's 日本語"; draft.initializeGit = initialize
            let request = try LocationCoordinator.projectRequest(draft)
            let location = try await coordinator.start(request)
            XCTAssertEqual(location?.isGit, initialize)
            XCTAssertEqual(coordinator.operation(request.id)?.status, .complete)
            XCTAssertTrue(store.state.workspaces.isEmpty)
            do { _ = try await coordinator.start(LocationCoordinator.projectRequest(draft)); XCTFail("Existing directory must be rejected") } catch { }
        }
        XCTAssertEqual(store.state.projects.count, 2)
    }
    @MainActor func testLocalBareCloneAndFailedAuthenticationRetainDestination() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git")
        let executor = NativeGitExecutor()
        _ = try await executor.execute(["init", "--bare", remote.path]).checked()
        let store = WorkspaceStore(), coordinator = LocationCoordinator(store: store)
        var draft = ProjectCreationDraft(parentPath: root.path); draft.mode = .clone; draft.name = "clone"; draft.repositoryURL = remote.path
        let location = try await coordinator.start(LocationCoordinator.projectRequest(draft))
        XCTAssertTrue(location!.isGit); XCTAssertEqual(store.state.projects.count, 1)
        draft.name = "blocked"
        let request = try LocationCoordinator.projectRequest(draft)
        let failing = LocationCoordinator(store: store, git: GitRepository(executor: RefuseClone()))
        do { _ = try await failing.start(request); XCTFail("Authentication should fail") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.destination))
        XCTAssertEqual(failing.operation(request.id)?.receipts.last?.phase, .reserved)
        XCTAssertEqual(failing.operation(request.id)?.status, .failed)
    }
    @MainActor func testInterruptionAfterEachCreateSideEffectNeverRepeats() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for failure in 2...4 {
            let persistence = InterruptedSave(failure)
            let store = WorkspaceStore(persistence: persistence), coordinator = LocationCoordinator(store: store)
            let request = LocationRequest(kind: .create, destination: root.appendingPathComponent("phase-\(failure)").path)
            do { _ = try await coordinator.start(request); XCTFail("Receipt should fail") } catch { }
            XCTAssertTrue(FileManager.default.fileExists(atPath: request.destination))
            let restored = WorkspaceStore(state: (try await persistence.load())!)
            let recovery = LocationCoordinator(store: restored)
            _ = try await recovery.reconcile(request.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: request.destination))
            if failure == 2 { XCTAssertEqual(recovery.operation(request.id)?.status, .uncertain); XCTAssertTrue(restored.state.projects.isEmpty) }
            else { XCTAssertEqual(restored.state.projects.count, 1) }
        }
    }
    func testNamesAndSecretBearingURLsAreRejected() throws {
        var draft = ProjectCreationDraft(parentPath: "/tmp"); draft.name = "../escape"
        XCTAssertThrowsError(try LocationCoordinator.projectRequest(draft))
        draft.name = "safe"; draft.mode = .clone; draft.repositoryURL = "https://user:secret@example.test/repo.git"
        XCTAssertThrowsError(try LocationCoordinator.projectRequest(draft))
    }
}
