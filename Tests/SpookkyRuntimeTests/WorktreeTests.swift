import XCTest
import SpookkyCore
import SpookkyGit
import SpookkyWorkspace
import SpookkyRuntime

private actor EmptyOwnedRuntime: SessionRuntime {
    func list() async throws -> [SessionBinding] { [] }
    func inspect(_ binding: SessionBinding) async throws -> SessionObservation? { nil }
    func create(_ spec: LaunchSpec) async throws -> SessionBinding { throw LaunchError.invalid("Fixture does not launch") }
    func attachmentArguments(_ binding: SessionBinding) async throws -> [String] { [] }
    func terminate(_ binding: SessionBinding) async throws { }
}
private struct MissingProvider: ExecutableResolver {
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec { throw LaunchError.invalid("Provider unavailable fixture") }
}
private struct OfflineFetch: GitCommandExecutor {
    let native = NativeGitExecutor()
    func execute(_ arguments: [String]) async throws -> GitResult {
        if arguments.contains("fetch") { return GitResult(status: 128, error: "Offline fixture") }
        return try await native.execute(arguments)
    }
}
private struct FailWorktreeOnce: GitCommandExecutor {
    let latch: FailureLatch
    let native = NativeGitExecutor()
    func execute(_ arguments: [String]) async throws -> GitResult {
        if arguments.contains("worktree"), arguments.contains("add"), await latch.fail() { return GitResult(status: 1, error: "Fixture failure before worktree add") }
        return try await native.execute(arguments)
    }
}
private actor FailureLatch { var first = true; func fail() -> Bool { defer { first = false }; return first } }

private struct GitFixture {
    let root: URL
    let repo: URL
    let remote: URL
    let git = GitRepository()
    static func make() async throws -> GitFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-m2-worktree-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = GitFixture(root: root, repo: root.appendingPathComponent("repo café's 日本語"), remote: root.appendingPathComponent("remote.git"))
        _ = try await fixture.git.executor.execute(["init", "--initial-branch=dev", fixture.repo.path]).checked()
        _ = try await fixture.git.command(fixture.repo.path, ["config", "user.name", "Spookky Fixture"]).checked()
        _ = try await fixture.git.command(fixture.repo.path, ["config", "user.email", "fixture@example.invalid"]).checked()
        try FileManager.default.createDirectory(at: fixture.repo.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        try Data("initial\n".utf8).write(to: fixture.repo.appendingPathComponent("subdir/file.txt"))
        _ = try await fixture.git.command(fixture.repo.path, ["add", "--", "subdir/file.txt"]).checked()
        _ = try await fixture.git.command(fixture.repo.path, ["commit", "-m", "Fixture initial commit"]).checked()
        _ = try await fixture.git.executor.execute(["init", "--bare", fixture.remote.path]).checked()
        _ = try await fixture.git.command(fixture.repo.path, ["remote", "add", "origin", fixture.remote.path]).checked()
        _ = try await fixture.git.command(fixture.repo.path, ["push", "-u", "origin", "dev"]).checked()
        _ = try await fixture.git.command(fixture.remote.path, ["symbolic-ref", "HEAD", "refs/heads/dev"]).checked()
        _ = try await fixture.git.command(fixture.repo.path, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/dev"]).checked()
        return fixture
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    @MainActor func store(source: String = "HEAD", branch: String? = nil, subdirectory: Bool = false) async throws -> WorkspaceStore {
        let location = try await git.discover(subdirectory ? repo.appendingPathComponent("subdir") : repo)
        var state = WorkspaceState(); let project = state.registerProject(location)
        let workspace = state.newWorkspace(location: location, projectID: project)
        var draft = LocationDraft(); draft.mode = .worktree; draft.source = source
        draft.destination = root.appendingPathComponent("worktree-" + workspace.uuidString.prefix(8)).path
        if let branch { draft.branchMode = .custom; draft.branch = branch }
        state.editLocation(draft, workspaceID: workspace)
        return WorkspaceStore(state: state)
    }
}

final class WorktreeTests: XCTestCase {
    @MainActor func testHeadLocalRemoteAndSubdirectoryPreserveDirtySource() async throws {
        let fixture = try await GitFixture.make(); defer { fixture.cleanup() }
        try Data("dirty source\n".utf8).write(to: fixture.repo.appendingPathComponent("subdir/file.txt"))
        let before = try await fixture.git.command(fixture.repo.path, ["status", "--porcelain", "-z"]).checked()
        for source in ["HEAD", "dev", "origin/dev"] {
            let store = try await fixture.store(source: source, subdirectory: true)
            let coordinator = LocationCoordinator(store: store)
            let location = try await coordinator.prepare(workspaceID: store.state.selectedWorkspaceID!)
            XCTAssertTrue(location.path.hasSuffix("/subdir")); XCTAssertNotEqual(location.scopePath, fixture.repo.path)
            XCTAssertNotNil(store.state.selected?.anchor)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: location.path).appendingPathComponent("file.txt")), Data("initial\n".utf8))
            let id = store.state.selected!.locationOperationID!
            XCTAssertEqual(coordinator.operation(id)?.status, .complete)
            XCTAssertNotNil(store.state.locations?.checkouts.first { $0.location.scopePath == location.scopePath }?.createdBy)
        }
        let after = try await fixture.git.command(fixture.repo.path, ["status", "--porcelain", "-z"]).checked()
        XCTAssertEqual(before, after)
        let branch = try await fixture.git.command(fixture.repo.path, ["symbolic-ref", "--short", "HEAD"]).checked()
        XCTAssertEqual(branch.trimmingCharacters(in: .newlines), "dev")
    }
    @MainActor func testMissingExternalWorktreeDoesNotBlockLocal() async throws {
        let fixture = try await GitFixture.make(); defer { fixture.cleanup() }
        let external = fixture.root.appendingPathComponent("moved-external")
        _ = try await fixture.git.command(fixture.repo.path, ["worktree", "add", "-b", "moved", external.path, "HEAD"]).checked()
        try FileManager.default.moveItem(at: external, to: fixture.root.appendingPathComponent("retained-moved-files"))
        let local = try await fixture.git.discover(fixture.repo)
        let snapshot = try await fixture.git.snapshot(local)
        XCTAssertNotNil(snapshot.head)
        XCTAssertEqual(snapshot.checkouts.filter { !$0.available }.count, 1)
        XCTAssertTrue(snapshot.checkouts.contains { $0.path == local.scopePath && $0.available })
    }
    @MainActor func testExistingBranchReusesExternalCheckout() async throws {
        let fixture = try await GitFixture.make(); defer { fixture.cleanup() }
        let external = fixture.root.appendingPathComponent("external")
        _ = try await fixture.git.command(fixture.repo.path, ["worktree", "add", "-b", "feature", external.path, "HEAD"]).checked()
        let store = try await fixture.store()
        var draft = store.state.selected!.locationDraft!; draft.branchMode = .existing; draft.branch = "feature"
        store.update { $0.editLocation(draft, workspaceID: $0.selectedWorkspaceID!) }
        let coordinator = LocationCoordinator(store: store)
        let location = try await coordinator.prepare(workspaceID: store.state.selectedWorkspaceID!)
        XCTAssertEqual(location.scopePath, external.path)
        XCTAssertNil(store.state.locations?.checkouts.first { $0.location.scopePath == external.path }?.createdBy)
        let originalProject = store.state.projects.first!.id
        store.update { state in
            XCTAssertEqual(state.registerProject(location), originalProject)
            let original = state.locations!.checkouts.first { $0.location.scopePath == external.path }!
            state.recordCheckout(WorkspaceLocation(path: external.appendingPathComponent("subdir").path, scopePath: external.path,
                checkoutIdentity: location.checkoutIdentity, branch: location.branch, commonRepository: location.commonRepository))
            let refreshed = state.locations!.checkouts.first { $0.location.scopePath == external.path }!
            XCTAssertEqual(refreshed.id, original.id); XCTAssertEqual(refreshed.location.id, original.location.id)
            XCTAssertEqual(refreshed.location.path, external.path)
        }
        let snapshot = try await fixture.git.snapshot(location); XCTAssertEqual(snapshot.checkouts.count, 2)
    }
    @MainActor func testOfflineCachedSourceAndReservedRetry() async throws {
        let fixture = try await GitFixture.make(); defer { fixture.cleanup() }
        let store = try await fixture.store(source: "origin/dev", branch: "custom/日本語")
        let offline = LocationCoordinator(store: store, git: GitRepository(executor: OfflineFetch()))
        do { _ = try await offline.prepare(workspaceID: store.state.selectedWorkspaceID!); XCTFail("Fetch should fail") } catch { XCTAssertTrue(error.localizedDescription.contains("cached")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.state.selected!.locationDraft!.destination))
        let displayedCommit = store.state.locations!.operations.last!.cachedCommit!
        try Data("new cached tip\n".utf8).write(to: fixture.repo.appendingPathComponent("subdir/file.txt"))
        _ = try await fixture.git.command(fixture.repo.path, ["add", "subdir/file.txt"]).checked()
        _ = try await fixture.git.command(fixture.repo.path, ["commit", "-m", "Move cached ref after failure"]).checked()
        _ = try await fixture.git.command(fixture.repo.path, ["update-ref", "refs/remotes/origin/dev", "HEAD"]).checked()
        var draft = store.state.selected!.locationDraft!; draft.useCachedSource = true
        store.update { $0.editLocation(draft, workspaceID: $0.selectedWorkspaceID!) }
        let result = try await offline.prepare(workspaceID: store.state.selectedWorkspaceID!)
        XCTAssertEqual(result.branch, "custom/日本語")
        let actualCommit = try await fixture.git.resolve(result.scopePath, reference: "HEAD")
        XCTAssertEqual(actualCommit, displayedCommit)
        let retryStore = try await fixture.store()
        let retry = LocationCoordinator(store: retryStore, git: GitRepository(executor: FailWorktreeOnce(latch: FailureLatch())))
        do { _ = try await retry.prepare(workspaceID: retryStore.state.selectedWorkspaceID!); XCTFail("Add should fail once") } catch { }
        let operation = retryStore.state.selected!.locationOperationID!
        let location = try await retry.prepare(workspaceID: retryStore.state.selectedWorkspaceID!)
        XCTAssertEqual(retryStore.state.selected!.locationOperationID, operation)
        XCTAssertEqual(retry.operation(operation)?.status, .complete)
        XCTAssertTrue(location.isGit)
    }
    @MainActor func testConcurrentPreparationAndMissingProviderRetainOneCheckout() async throws {
        let fixture = try await GitFixture.make(); defer { fixture.cleanup() }
        let store = try await fixture.store()
        let coordinator = LocationCoordinator(store: store)
        let id = store.state.selectedWorkspaceID!
        async let first = coordinator.prepare(workspaceID: id)
        async let second = coordinator.prepare(workspaceID: id)
        let results = try await (first, second)
        XCTAssertEqual(results.0, results.1); XCTAssertEqual(store.state.locations?.operations.count, 1)
        let launches = LaunchCoordinator(store: store, runtime: EmptyOwnedRuntime(), resolver: MissingProvider())
        let tab = store.state.selectedTab!.id
        store.update { $0.editDraft(tab, tool: .codex, prompt: "retained prompt") }
        await launches.launch(tab)
        XCTAssertEqual(store.state.tab(tab)?.status, .failed)
        XCTAssertEqual(store.state.tab(tab)?.draft.prompt, "retained prompt")
        let retry = try await coordinator.prepare(workspaceID: id)
        XCTAssertEqual(retry, results.0); XCTAssertEqual(store.state.locations?.operations.count, 1)
    }
    @MainActor func testDeletionBlocksDirtyUnpushedAndKeepsBranchOnSuccess() async throws {
        let fixture = try await GitFixture.make(); defer { fixture.cleanup() }
        let store = try await fixture.store(branch: "spookky/delete-me")
        let coordinator = LocationCoordinator(store: store, runtime: EmptyOwnedRuntime())
        let location = try await coordinator.prepare(workspaceID: store.state.selectedWorkspaceID!)
        let record = store.state.locations!.checkouts.first { $0.location.scopePath == location.scopePath }!
        let request = try coordinator.deletionRequest(record)
        let file = URL(fileURLWithPath: location.scopePath).appendingPathComponent("untracked.txt")
        try Data("retain".utf8).write(to: file)
        do { try await coordinator.checkDeletion(request); XCTFail("Dirty deletion must fail") } catch { }
        try FileManager.default.removeItem(at: file)
        do { try await coordinator.checkDeletion(request); XCTFail("Missing upstream must fail") } catch { }
        _ = try await fixture.git.command(location.scopePath, ["push", "-u", "origin", "spookky/delete-me"]).checked()
        try await coordinator.checkDeletion(request)
        _ = try await coordinator.start(request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.scopePath))
        let branch = try await fixture.git.command(fixture.repo.path, ["show-ref", "--verify", "refs/heads/spookky/delete-me"])
        XCTAssertEqual(branch.status, 0)
    }
}

private struct MatrixResolver: ExecutableResolver {
    let executable: String
    let output: String
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try LaunchSpec(tool: tool, executable: executable, arguments: [output], directory: directory, initialPrompt: tool == .shell ? nil : prompt)
    }
}
extension WorktreeTests {
    @MainActor func testS01ThroughS12LaunchMatrixWithLiteralProviderArguments() async throws {
        let fixture = try await GitFixture.make(); defer { fixture.cleanup() }
        let root = URL(fileURLWithPath: "/tmp/spookky-m2-matrix-" + UUID().uuidString.prefix(8))
        try PrivateFiles.directory(root)
        let executable = root.appendingPathComponent("capture")
        try "#!/bin/zsh -f\nout=$1; shift\n/usr/bin/printf '%s\\0' \"$@\" > \"$out\"\npwd > \"$out.cwd\"\n/usr/bin/touch \"$out.done\"\nexec /bin/cat\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = try TmuxRuntime(executable: PackagedRuntime.tmux(), helper: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/spookky-launch").path, root: root.appendingPathComponent("rt"))
        let socket = await runtime.socket
        defer { _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"]); try? FileManager.default.removeItem(at: root) }
        let plain = fixture.root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
        let unborn = fixture.root.appendingPathComponent("unborn")
        _ = try await fixture.git.executor.execute(["init", unborn.path]).checked()
        let external = fixture.root.appendingPathComponent("external-matrix")
        _ = try await fixture.git.command(fixture.repo.path, ["worktree", "add", "-b", "external-matrix", external.path, "HEAD"]).checked()
        _ = try await fixture.git.command(fixture.repo.path, ["branch", "existing-matrix"]).checked()
        for scenario in 1...12 {
            let store: WorkspaceStore
            switch scenario {
            case 1, 2, 4, 5, 7, 12:
                let folder = scenario == 4 ? unborn : scenario == 5 || scenario == 12 ? fixture.repo : scenario == 7 ? external : plain
                let location = try await fixture.git.discover(folder)
                var state = WorkspaceState()
                let project: UUID? = scenario == 1 ? nil : state.registerProject(location)
                state.newWorkspace(location: location, projectID: project)
                if scenario == 12 { state.bindWorkspace(state.selectedWorkspaceID!); _ = state.newTab() }
                store = WorkspaceStore(state: state)
            case 3, 6:
                store = WorkspaceStore()
                let coordinator = LocationCoordinator(store: store)
                var draft = ProjectCreationDraft(parentPath: fixture.root.path)
                draft.name = "scenario-\(scenario)"; draft.mode = scenario == 6 ? .clone : .create; draft.repositoryURL = fixture.remote.path
                let location = try await coordinator.start(LocationCoordinator.projectRequest(draft))!
                store.update { $0.newWorkspace(location: location, projectID: $0.projects.last!.id) }
            default:
                store = try await fixture.store(source: scenario == 10 ? "origin/dev" : scenario == 9 ? "dev" : "HEAD")
                if scenario == 11 {
                    var draft = store.state.selected!.locationDraft!; draft.branchMode = .existing; draft.branch = "existing-matrix"
                    store.update { $0.editLocation(draft, workspaceID: $0.selectedWorkspaceID!) }
                }
                _ = try await LocationCoordinator(store: store).prepare(workspaceID: store.state.selectedWorkspaceID!)
            }
            let prompt = "café's 日本語\n$(touch MUST_NOT_EXIST) --option"
            for (index, entry) in [(SessionTool.shell, ""), (.codex, ""), (.codex, prompt), (.claude, ""), (.claude, prompt)].enumerated() {
                let output = root.appendingPathComponent("s\(scenario)-\(index)")
                let tab = store.state.selectedTab!.id
                store.update { $0.editDraft(tab, tool: entry.0, prompt: entry.1) }
                let launch = LaunchCoordinator(store: store, runtime: runtime, resolver: MatrixResolver(executable: executable.path, output: output.path))
                await launch.launch(tab)
                let binding = try XCTUnwrap(store.state.tab(tab)?.binding, "S\(scenario) launch failed")
                for _ in 0..<100 { if FileManager.default.fileExists(atPath: output.path + ".done") { break }; try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(try Data(contentsOf: output), entry.1.isEmpty ? Data([0]) : Data(("--\0" + entry.1 + "\0").utf8), "S\(scenario) literal arguments")
                let cwd = try String(contentsOfFile: output.path + ".cwd", encoding: .utf8).trimmingCharacters(in: .newlines)
                XCTAssertEqual(cwd, store.state.selected!.directory, "S\(scenario) directory")
                let before = try await runtime.inspect(binding); await launch.reconcile(tab); await launch.launch(tab)
                let after = try await runtime.inspect(binding); XCTAssertEqual(before?.processID, after?.processID)
                try await launch.terminate(tab)
                store.update { $0.closeTab(tab) }
            }
        }
    }
}

extension WorktreeTests {
    @MainActor func testInterruptedWorktreeReceiptsRetainFilesAndNeverLaunch() async throws {
        let fixture = try await GitFixture.make(); defer { fixture.cleanup() }
        for failure in 2...5 {
            let initial = try await fixture.store()
            let persistence = InterruptedSave(failure)
            let store = WorkspaceStore(state: initial.state, persistence: persistence)
            let coordinator = LocationCoordinator(store: store, operationRoot: fixture.root.appendingPathComponent("operations"))
            let workspace = store.state.selectedWorkspaceID!
            let destination = store.state.selected!.locationDraft!.destination
            do { _ = try await coordinator.prepare(workspaceID: workspace); XCTFail("Save must fail at phase \(failure)") } catch { }
            let saved = try await persistence.load()!
            let restored = WorkspaceStore(state: saved)
            let recovery = LocationCoordinator(store: restored, operationRoot: fixture.root.appendingPathComponent("operations"))
            await recovery.reconcileAll()
            XCTAssertNil(restored.state.selectedTab?.binding)
            if failure >= 4 {
                XCTAssertTrue(FileManager.default.fileExists(atPath: destination))
                XCTAssertEqual(restored.state.selected!.anchor?.scopePath, destination)
                let record = restored.state.locations!.checkouts.first { $0.location.scopePath == destination }!
                XCTAssertEqual(record.createdBy != nil, failure == 5)
            } else { XCTAssertNil(restored.state.selected!.anchor) }
        }
    }
    @MainActor func testBranchCollisionUnbornAndLockedWorktreeStaySafe() async throws {
        let fixture = try await GitFixture.make(); defer { fixture.cleanup() }
        let store = try await fixture.store(branch: "dev")
        let coordinator = LocationCoordinator(store: store)
        do { _ = try await coordinator.prepare(workspaceID: store.state.selectedWorkspaceID!); XCTFail("Branch collision must fail") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.state.selected!.locationDraft!.destination))
        let unborn = fixture.root.appendingPathComponent("empty")
        _ = try await fixture.git.executor.execute(["init", unborn.path]).checked()
        let emptyLocation = try await fixture.git.discover(unborn)
        var state = WorkspaceState(); let project = state.registerProject(emptyLocation)
        let id = state.newWorkspace(location: emptyLocation, projectID: project)
        var draft = LocationDraft(); draft.mode = .worktree; state.editLocation(draft, workspaceID: id)
        do { _ = try await LocationCoordinator(store: WorkspaceStore(state: state)).prepare(workspaceID: id); XCTFail("Unborn worktree must fail") } catch { }
        let safeStore = try await fixture.store()
        let safe = LocationCoordinator(store: safeStore, runtime: EmptyOwnedRuntime())
        let location = try await safe.prepare(workspaceID: safeStore.state.selectedWorkspaceID!)
        let record = safeStore.state.locations!.checkouts.first { $0.location.scopePath == location.scopePath }!
        _ = try await fixture.git.command(fixture.repo.path, ["worktree", "lock", "--", location.scopePath]).checked()
        do { try await safe.checkDeletion(safe.deletionRequest(record)); XCTFail("Locked worktree must remain") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.scopePath))
    }
}
