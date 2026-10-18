import XCTest
import GRDB
import SpookkyCore
import SpookkyGit
import SpookkyWorkspace
import SpookkyPersistence

private actor ConcurrencyProbe {
    var active = 0
    var maximum = 0
    func enter() { active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
}
private actor RejectLocationSave: WorkspacePersistence {
    func load() async throws -> WorkspaceState? { nil }
    func save(_ state: WorkspaceState) async throws { throw LaunchError.command("Fixture write failure") }
}
private actor DiscoveryProbeExecutor: GitCommandExecutor {
    let path: String
    private var active = 0
    private(set) var maximum = 0
    init(path: String) { self.path = path }
    func execute(_ arguments: [String]) async throws -> GitResult {
        if arguments.contains("--show-toplevel") { return GitResult(status: 0, output: path + "\n") }
        active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(30))
        return GitResult(status: 0, output: (arguments.contains("symbolic-ref") ? "dev" : path + "/.git") + "\n")
    }
}

final class GitFoundationTests: XCTestCase {
    func testDiscoveryOverlapsIndependentReadsWithinSchedulerLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-discovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.resolvingSymlinksInPath().path
        let executor = DiscoveryProbeExecutor(path: path)
        let location = try await GitRepository(executor: executor, scheduler: GitScheduler()).discover(root)
        let maximum = await executor.maximum
        XCTAssertEqual(maximum, 2)
        XCTAssertEqual(location.path, path); XCTAssertEqual(location.scopePath, path)
        XCTAssertEqual(location.checkoutIdentity, path + "/.git")
        XCTAssertEqual(location.commonRepository, path + "/.git"); XCTAssertEqual(location.branch, "dev")
    }
    func testSchedulerLimitsReadsAndSerializesWrites() async throws {
        let scheduler = GitScheduler(), reads = ConcurrencyProbe(), writes = ConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await scheduler.read { await reads.enter(); try await Task.sleep(for: .milliseconds(15)); await reads.leave() } }
                group.addTask { try await scheduler.write(repository: "same") { await writes.enter(); try await Task.sleep(for: .milliseconds(15)); await writes.leave() } }
            }
            try await group.waitForAll()
        }
        let maximumReads = await reads.maximum, maximumWrites = await writes.maximum
        XCTAssertEqual(maximumReads, 2); XCTAssertEqual(maximumWrites, 1)
    }
    func testOutputIsBoundedAndCancellationStopsOwnedCommand() async throws {
        let executor = NativeGitExecutor(timeout: 5, outputLimit: 128)
        let output = try await executor.execute(["-c", "alias.fixture=!printf '%010000d' 0", "fixture"])
        XCTAssertEqual(output.output.utf8.count, 128); XCTAssertTrue(output.truncated)
        XCTAssertThrowsError(try output.checked())
        let task = Task { try await executor.execute(["-c", "alias.fixture=!sleep 30", "fixture"]) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError { }
    }
    func testVersionOneMigrationPreservesStateAndBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-m2-db-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite").path
        var old = WorkspaceState(); old.version = 1
        let location = WorkspaceLocation(path: "/tmp/日本語", checkoutIdentity: "/tmp/日本語/.git", branch: "dev")
        let project = old.registerProject(location); old.newWorkspace(location: location, projectID: project)
        let first = old.selectedTab!.id; old.editDraft(first, tool: .codex, prompt: "Unicode café\nsecond line")
        let second = old.newTab()!; old.setSplit(first: first, second: second)
        let queue = try DatabaseQueue(path: path)
        let payload = try JSONEncoder().encode(old)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE workspace_snapshot (id INTEGER PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('workspace-v1')")
            try db.execute(sql: "INSERT INTO workspace_snapshot VALUES (1, 1, ?)", arguments: [payload])
        }
        let database = try WorkspaceDatabase(path: path)
        let loaded = try await database.load()
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.version, 7); XCTAssertEqual(Set(restored.workspaces.flatMap(\.tabs).map(\.id)), Set(old.workspaces.flatMap(\.tabs).map(\.id)))
        for tab in old.workspaces.flatMap(\.tabs) { XCTAssertEqual(restored.tab(tab.id), tab) }
        XCTAssertEqual(restored.projects, old.projects); XCTAssertEqual(restored.locations?.checkouts.count, 1)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.contains("pre-v6") && $0.hasSuffix("sqlite") })
        let backupQueue = try DatabaseQueue(path: root.appendingPathComponent(backup).path)
        let version = try await backupQueue.read { try Int.fetchOne($0, sql: "SELECT version FROM workspace_snapshot") }
        XCTAssertEqual(version, 1)
    }
    @MainActor func testIntentSaveFailurePreventsFolderCreation() async throws {
        let parent = FileManager.default.temporaryDirectory
        let draft = ProjectCreationDraft(parentPath: parent.path)
        var named = draft; named.name = "spookky-m2-not-created-" + UUID().uuidString
        let request = try LocationCoordinator.projectRequest(named)
        let store = WorkspaceStore(persistence: RejectLocationSave())
        let coordinator = LocationCoordinator(store: store)
        do { _ = try await coordinator.start(request); XCTFail("Save should fail") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.destination))
        XCTAssertEqual(store.state.locations?.operations.count, 1)
    }
    @MainActor func testOldOperationCannotRebindChangedWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-m2-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: false)
        var state = WorkspaceState(); let workspace = state.newWorkspace(directory: old.path)
        let request = LocationRequest(kind: .worktree, destination: old.path, workspaceID: workspace, sourcePath: old.path, commonRepository: old.appendingPathComponent(".git").path, source: "HEAD", branch: "dev")
        var operation = LocationOperation(request); operation.receipts = [LocationReceipt(.filesystemComplete, location: WorkspaceLocation(path: old.path))]
        state.recordOperation(operation)
        state.setLocation(WorkspaceLocation(path: new.path), projectID: nil, workspaceID: workspace)
        let store = WorkspaceStore(state: state)
        _ = try await LocationCoordinator(store: store).reconcile(request.id)
        XCTAssertEqual(store.state.selected?.directory, new.path)
        XCTAssertNil(store.state.selected?.anchor)
        XCTAssertNil(store.state.selected?.locationOperationID)
    }
    @MainActor func testInterruptedIntentDoesNotRepeatAndCompletedReceiptCanRegister() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-m2-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = LocationRequest(kind: .create, destination: root.appendingPathComponent("not-created").path)
        var state = WorkspaceState(); state.recordOperation(LocationOperation(request))
        let store = WorkspaceStore(state: state), coordinator = LocationCoordinator(store: store)
        _ = try await coordinator.reconcile(request.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.destination))
        XCTAssertEqual(coordinator.operation(request.id)?.status, .uncertain)
        let completed = LocationRequest(kind: .create, destination: root.appendingPathComponent("complete").path)
        try FileManager.default.createDirectory(atPath: completed.destination, withIntermediateDirectories: false)
        var operation = LocationOperation(completed)
        operation.receipts = [LocationReceipt(.reserved), LocationReceipt(.filesystemComplete, location: WorkspaceLocation(path: completed.destination))]
        store.update { $0.recordOperation(operation) }
        _ = try await coordinator.reconcile(completed.id)
        XCTAssertEqual(store.state.projects.count, 1)
        XCTAssertEqual(coordinator.operation(completed.id)?.status, .complete)
    }

}

extension GitFoundationTests {
    @MainActor func testExecutionJournalDetectsLiveGitAndCancelsOnlyItsGroup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-m2-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let operationID = UUID()
        let context = GitExecutionContext(root: root, operationID: operationID)
        let executor = NativeGitExecutor(timeout: 5)
        let first = Task { try await executor.execute(["-c", "alias.fixture=!sleep 30", "fixture"], context: context) }
        let second = Task { try await executor.execute(["-c", "alias.fixture=!sleep 0.5", "fixture"], context: GitExecutionContext(root: root, operationID: UUID())) }
        var observed = false
        for _ in 0..<100 {
            if (try? GitExecutionJournal.hasLiveCommands(root: root, operationID: operationID)) == true { observed = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(observed)
        let request = LocationRequest(id: operationID, kind: .clone, destination: root.appendingPathComponent("not-created").path, repositoryURL: "fixture")
        var state = WorkspaceState(); state.recordOperation(LocationOperation(request))
        let store = WorkspaceStore(state: state)
        let coordinator = LocationCoordinator(store: store, operationRoot: root)
        _ = try await coordinator.reconcile(operationID)
        XCTAssertEqual(coordinator.operation(operationID)?.status, .running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.destination))
        try GitExecutionJournal.cancel(root: root, operationID: operationID)
        let stopped = try await first.value, untouched = try await second.value
        XCTAssertNotEqual(stopped.status, 0); XCTAssertEqual(untouched.status, 0)
        XCTAssertFalse(try GitExecutionJournal.hasLiveCommands(root: root, operationID: operationID))
    }
}

extension GitFoundationTests {
    func testVersionTwoMigrationRetainsDraftAndFileSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite").path
        var old = WorkspaceState(); old.version = 2; old.newWorkspace(directory: "/tmp")
        old.editDraft(old.selectedTab!.id, tool: .codex, prompt: "Keep this draft\n世界")
        let payload = try JSONEncoder().encode(old)
        let queue = try DatabaseQueue(path: path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE workspace_snapshot (id INTEGER PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('workspace-v1'), ('workspace-v2')")
            try db.execute(sql: "INSERT INTO workspace_snapshot VALUES (1, 2, ?)", arguments: [payload])
        }
        let db = try WorkspaceDatabase(path: path), state = try await db.load()
        XCTAssertEqual(state?.version, 7); XCTAssertEqual(state?.workspaces.flatMap(\.tabs), old.workspaces.flatMap(\.tabs))
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.contains("pre-v6") && $0.hasSuffix("sqlite") })
        let preserved = try DatabaseQueue(path: root.appendingPathComponent(backup).path)
        let bytes = try await preserved.read { try Data.fetchOne($0, sql: "SELECT payload FROM workspace_snapshot") }
        XCTAssertEqual(bytes, payload)
    }
}
