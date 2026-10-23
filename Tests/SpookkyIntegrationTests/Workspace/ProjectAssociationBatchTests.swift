import SpookkyTestSupport
import XCTest
import SpookkyCore
import SpookkyGit
import SpookkyRuntime
import SpookkyWorkspace

private actor AssociationDiscoveryProbe: GitCommandExecutor {
    var locations: [String: WorkspaceLocation]
    let delay: Duration
    let delays: [String: Duration]
    private var calls: [String: Int] = [:]
    private var commands = 0
    private var active = 0
    private var maximum = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    init(_ locations: [WorkspaceLocation], delay: Duration = .zero, delays: [String: Duration] = [:]) {
        self.locations = Dictionary(uniqueKeysWithValues: locations.map { ($0.path, $0) }); self.delay = delay; self.delays = delays
    }
    func execute(_ arguments: [String]) async throws -> GitResult {
        let path = arguments[1]
        commands += 1
        if arguments.contains("--show-toplevel") { calls[path, default: 0] += 1 }
        active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        let waiting = startWaiters; startWaiters.removeAll(); waiting.forEach { $0.resume() }
        try await Task.sleep(for: delays[path] ?? delay)
        try Task.checkCancellation()
        guard let location = locations[path] else { return GitResult(status: 128, error: "not a git repository") }
        let output: String
        if arguments.contains("--show-toplevel") { output = location.scopePath }
        else if arguments.contains("--absolute-git-dir") { output = location.checkoutIdentity! }
        else if arguments.contains("--git-common-dir") { output = location.commonRepository! }
        else { output = "main" }
        return GitResult(status: 0, output: output + "\n")
    }
    func waitForStart() async {
        if commands > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func observedCalls() -> [String: Int] { calls }
    func totalCommands() -> Int { commands }
    func maximumCommands() -> Int { maximum }
    func set(_ location: WorkspaceLocation) { locations[location.path] = location }
}

private actor AssociationNativeGitProbe: GitCommandExecutor {
    private let executor = NativeGitExecutor(timeout: 2, outputLimit: 32_768)
    private var commands = 0
    func execute(_ arguments: [String]) async throws -> GitResult {
        commands += 1
        return try await executor.execute(arguments)
    }
    func totalCommands() -> Int { commands }
}

private actor AssociationReadGate {
    private var held: [CheckedContinuation<Void, Never>] = []
    private var observer: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { continuation in
            held.append(continuation)
            if held.count == 2 { observer?.resume(); observer = nil }
        }
    }
    func waitForBoth() async {
        if held.count == 2 { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { let current = held; held.removeAll(); current.forEach { $0.resume() } }
}

final class ProjectAssociationBatchTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-association-batch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }
    private func directory(_ root: URL, _ name: String, common: String? = nil, scope: String? = nil) throws -> WorkspaceLocation {
        let path = root.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return WorkspaceLocation(path: path, scopePath: scope, checkoutIdentity: path + "/.git",
                                 commonRepository: common ?? path + "/.git")
    }
    func testHundredsOfRowsReuseProjectAndCanonicalDirectoryDiscovery() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let roots = try (0..<8).map { try directory(root, "repo-\($0)") }
        let projects = roots.map { Project(name: "repo", location: $0) }
        let one = try directory(root, "generated-one", common: roots[0].commonRepository)
        let two = try directory(root, "generated-two/src", common: roots[0].commonRepository, scope: root.appendingPathComponent("generated-two").path)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: one.path))
        let cwd = [roots[0].path, one.path, two.path, alias.path]
        let rows = (0..<600).map { cwd[$0 % cwd.count] }
        let probe = AssociationDiscoveryProbe(roots + [one, two])
        let resolver = ProjectAssociationResolver(git: GitRepository(executor: probe, scheduler: GitScheduler()))
        let snapshot = try await resolver.resolveBatch(directories: rows, projects: projects)
        XCTAssertEqual(snapshot.uniqueDirectoryCount, 10)
        for path in rows {
            let result = snapshot.resolution(for: path)
            XCTAssertEqual(result.status, .matched); XCTAssertEqual(result.projectID, projects[0].id)
            XCTAssertEqual(result.location?.path, URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path)
            XCTAssertEqual(result.key, roots[0].projectAssociationKey)
        }
        XCTAssertEqual(snapshot.resolution(for: two.path).location?.scopePath, two.scopePath)
        XCTAssertNotEqual(snapshot.resolution(for: one.path).location?.checkoutIdentity, snapshot.resolution(for: two.path).location?.checkoutIdentity)
        let counts = await probe.observedCalls(), commands = await probe.totalCommands(), maximum = await probe.maximumCommands()
        XCTAssertEqual(counts.count, 10); XCTAssertTrue(counts.values.allSatisfy { $0 == 1 })
        XCTAssertEqual(commands, 40); XCTAssertLessThanOrEqual(maximum, 2)
        for path in rows { _ = snapshot.resolution(for: path, preferredProjectID: projects[0].id) }
        let afterLookup = await probe.totalCommands(); XCTAssertEqual(afterLookup, commands)
    }
    func testNativeGitBatchKeepsSameNamedRepositoriesAndWorktreeSubdirectoryDistinct() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try directory(root, "one/repo"), two = try directory(root, "two/repo")
        func git(_ path: String, _ arguments: [String]) throws {
            try TestGit.run(path, arguments)
        }
        for path in [one.path, two.path] {
            try git(path, ["init", "-b", "main"])
            try git(path, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"])
            try git(path, ["remote", "add", "origin", "https://example.invalid/same-repository"])
        }
        let checkout = root.appendingPathComponent("generated"), sub = checkout.appendingPathComponent("src")
        try git(one.path, ["worktree", "add", "-b", "topic", checkout.path])
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let projects = [Project(name: "repo", location: one), Project(name: "repo", location: two)]
        let paths = (0..<300).map { [one.path, two.path, sub.path][$0 % 3] }
        let probe = AssociationNativeGitProbe()
        let snapshot = try await ProjectAssociationResolver(git: GitRepository(executor: probe, scheduler: GitScheduler()))
            .resolveBatch(directories: paths, projects: projects)
        XCTAssertEqual(snapshot.resolution(for: one.path).projectID, projects[0].id)
        XCTAssertEqual(snapshot.resolution(for: two.path).projectID, projects[1].id)
        let linked = snapshot.resolution(for: sub.path)
        XCTAssertEqual(linked.projectID, projects[0].id); XCTAssertEqual(linked.location?.path, sub.path)
        XCTAssertEqual(linked.location?.scopePath, checkout.path); XCTAssertEqual(linked.projectRoot, one.path)
        XCTAssertNotEqual(linked.location?.checkoutIdentity, snapshot.resolution(for: one.path).location?.checkoutIdentity)
        let commands = await probe.totalCommands(); XCTAssertEqual(commands, 12)
    }
    func testMissingAmbiguousUnrelatedAndPlainFoldersStayExplicit() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try directory(root, "a/repo"), two = try directory(root, "b/repo")
        let plain = try directory(root, "plain/repo"), unregistered = try directory(root, "unregistered")
        let missing = root.appendingPathComponent("missing").path
        let projects = [Project(name: "repo", location: one), Project(name: "repo", location: one),
                        Project(name: "repo", location: two), Project(name: "repo", location: WorkspaceLocation(path: plain.path)),
                        Project(name: "missing", location: WorkspaceLocation(path: missing))]
        let probe = AssociationDiscoveryProbe([one, two, unregistered])
        let resolver = ProjectAssociationResolver(git: GitRepository(executor: probe, scheduler: GitScheduler()))
        let snapshot = try await resolver.resolveBatch(directories: [one.path, two.path, plain.path, unregistered.path, missing, missing, "relative", "/tmp/invalid\0path"], projects: projects)
        XCTAssertEqual(snapshot.resolution(for: one.path).status, .ambiguous)
        XCTAssertEqual(snapshot.resolution(for: one.path, preferredProjectID: projects[1].id).projectID, projects[1].id)
        XCTAssertEqual(snapshot.resolution(for: two.path).projectID, projects[2].id)
        XCTAssertEqual(snapshot.resolution(for: two.path, preferredProjectID: projects[0].id).status, .unavailable)
        XCTAssertEqual(snapshot.resolution(for: plain.path).projectID, projects[3].id)
        XCTAssertEqual(snapshot.resolution(for: plain.path).key?.kind, .folder)
        XCTAssertEqual(snapshot.resolution(for: unregistered.path).status, .unregistered)
        XCTAssertEqual(snapshot.resolution(for: two.path, preferredProjectID: projects[4].id).status, .unavailable)
        for path in [missing, "relative", "/tmp/invalid\0path", "/not-in-refresh"] { XCTAssertEqual(snapshot.resolution(for: path).status, .unavailable) }
        let counts = await probe.observedCalls()
        XCTAssertEqual(counts[one.path], 1); XCTAssertEqual(counts[plain.path], 1); XCTAssertNil(counts[missing])
    }
    func testFreshRefreshAndActionResolveNeverReuseDisplaySnapshot() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try directory(root, "one"), two = try directory(root, "two"), saved = try directory(root, "saved", common: root.appendingPathComponent("one/.git").path)
        let projects = [Project(name: "repo", location: one), Project(name: "repo", location: two)]
        let probe = AssociationDiscoveryProbe([one, two, saved])
        let resolver = ProjectAssociationResolver(git: GitRepository(executor: probe, scheduler: GitScheduler()))
        let first = try await resolver.resolveBatch(directories: [saved.path], projects: projects)
        XCTAssertEqual(first.resolution(for: saved.path).projectID, projects[0].id)
        try FileManager.default.removeItem(atPath: saved.path)
        let missing = await resolver.resolve(directory: saved.path, projects: projects, preferredProjectID: projects[0].id)
        XCTAssertEqual(missing.status, .unavailable)
        try FileManager.default.createDirectory(atPath: saved.path, withIntermediateDirectories: true)
        var replaced = saved; replaced.commonRepository = two.commonRepository
        await probe.set(replaced)
        let action = await resolver.resolve(directory: saved.path, projects: projects, preferredProjectID: projects[0].id)
        XCTAssertEqual(action.status, .unavailable)
        let second = try await resolver.resolveBatch(directories: [saved.path], projects: projects)
        XCTAssertEqual(second.resolution(for: saved.path).projectID, projects[1].id)
        XCTAssertEqual(first.resolution(for: saved.path).projectID, projects[0].id)
        XCTAssertNotEqual(first.id, second.id)
        let counts = await probe.observedCalls(); XCTAssertEqual(counts[saved.path], 3)
    }
    func testInputAndUniqueDirectoryLimitsRejectIncompleteRefreshes() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try directory(root, "one"), two = try directory(root, "two")
        let projects = [Project(name: "one", location: one), Project(name: "two", location: two)]
        let probe = AssociationDiscoveryProbe([one, two])
        let resolver = ProjectAssociationResolver(git: GitRepository(executor: probe, scheduler: GitScheduler()))
        let cases: [(ProjectAssociationBatchLimits, [String], ProjectAssociationBatchError)] = [
            (ProjectAssociationBatchLimits(maximumProjects: 1), [], .tooManyProjects),
            (ProjectAssociationBatchLimits(maximumDirectories: 1), [one.path], .tooManyDirectories),
            (ProjectAssociationBatchLimits(maximumRequests: 1), [one.path, one.path], .tooManyRequests),
            (ProjectAssociationBatchLimits(timeout: .zero), [], .invalidLimits)]
        for (limits, paths, expected) in cases {
            do { _ = try await resolver.resolveBatch(directories: paths, projects: projects, limits: limits); XCTFail("Expected refresh limit") }
            catch let error as ProjectAssociationBatchError { XCTAssertEqual(error, expected) }
        }
        let commands = await probe.totalCommands(); XCTAssertEqual(commands, 0)
    }
    func testCancellationStopsInFlightDiscoveryAndReturnsNoPartialSnapshot() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try directory(root, "one"), probe = AssociationDiscoveryProbe([one], delay: .seconds(30))
        let resolver = ProjectAssociationResolver(git: GitRepository(executor: probe, scheduler: GitScheduler()))
        let task = Task { try await resolver.resolveBatch(directories: [one.path], projects: []) }
        await probe.waitForStart()
        let start = ContinuousClock.now; task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let commands = await probe.totalCommands(); XCTAssertEqual(commands, 1)
    }
    func testDeadlineCancelsDiscoveryRatherThanWaitingForCommandDelay() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try directory(root, "one"), probe = AssociationDiscoveryProbe([one], delay: .seconds(30))
        let resolver = ProjectAssociationResolver(git: GitRepository(executor: probe, scheduler: GitScheduler()))
        let start = ContinuousClock.now
        let snapshot = try await resolver.resolveBatch(directories: [one.path], projects: [], limits: ProjectAssociationBatchLimits(timeout: .milliseconds(50)))
        XCTAssertTrue(snapshot.truncated)
        XCTAssertEqual(snapshot.resolution(for: one.path).status, .unavailable)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }
    func testDeadlineAlsoCancelsReadQueuedBehindBusyScheduler() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try directory(root, "one"), scheduler = GitScheduler(), gate = AssociationReadGate()
        let first = Task { try await scheduler.read { await gate.hold() } }
        let second = Task { try await scheduler.read { await gate.hold() } }
        await gate.waitForBoth()
        let fallbackRelease = Task { try? await Task.sleep(for: .seconds(2)); await gate.release() }
        let probe = AssociationDiscoveryProbe([one])
        let resolver = ProjectAssociationResolver(git: GitRepository(executor: probe, scheduler: scheduler))
        let start = ContinuousClock.now
        let snapshot = try await resolver.resolveBatch(directories: [one.path], projects: [], limits: ProjectAssociationBatchLimits(timeout: .milliseconds(50)))
        XCTAssertTrue(snapshot.truncated)
        XCTAssertEqual(snapshot.resolution(for: one.path).status, .unavailable)
        await gate.release(); fallbackRelease.cancel()
        _ = try await first.value; _ = try await second.value
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let commands = await probe.totalCommands(); XCTAssertEqual(commands, 0)
        let subsequent = try await resolver.resolveBatch(directories: [one.path], projects: [])
        XCTAssertEqual(subsequent.resolution(for: one.path).status, .unregistered)
    }
    func testCancellationRemovesQueuedWritersAndDestinations() async throws {
        let scheduler = GitScheduler(), gate = AssociationReadGate()
        let heldWriter = Task { try await scheduler.write(repository: "fixture") { await gate.hold() } }
        let heldDestination = Task { try await scheduler.destination("/fixture") { await gate.hold() } }
        await gate.waitForBoth()
        let fallbackRelease = Task { try? await Task.sleep(for: .seconds(2)); await gate.release() }
        let writer = Task { try await scheduler.write(repository: "fixture") { 1 } }
        let destination = Task { try await scheduler.destination("/fixture") { 2 } }
        await Task.yield()
        let start = ContinuousClock.now; writer.cancel(); destination.cancel()
        for task in [writer, destination] {
            do { _ = try await task.value; XCTFail("Queued mutations must stay cancelled") } catch is CancellationError { }
        }
        await gate.release(); fallbackRelease.cancel()
        _ = try await heldWriter.value; _ = try await heldDestination.value
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let next = try await scheduler.write(repository: "fixture") { 3 }
        XCTAssertEqual(next, 3)
    }

    func testDeadlineKeepsResolvedProjectsAndEveryHistoryRow() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let known = try directory(root, "project"), slow = try directory(root, "slow")
        var state = WorkspaceState()
        let projectID = state.registerProject(known)
        let probe = AssociationDiscoveryProbe([known, slow], delays: [slow.path: .seconds(30)])
        let resolver = ProjectAssociationResolver(git: GitRepository(executor: probe, scheduler: GitScheduler()))
        let batch = try await resolver.resolveBatch(directories: [known.path, slow.path], projects: state.projects,
            limits: ProjectAssociationBatchLimits(timeout: .milliseconds(100)))
        XCTAssertTrue(batch.truncated)
        XCTAssertEqual(batch.resolution(for: known.path).projectID, projectID)
        XCTAssertEqual(batch.resolution(for: slow.path).status, .unavailable)
        let entries = [known, slow].map { location in
            ConversationMetadata(id: ConversationID(provider: .codex, sessionID: UUID().uuidString), title: "Saved",
                directory: location.path, updatedAt: Date())
        }
        ConversationCatalogReconciler.apply(SessionCatalogSnapshot(conversations: entries), batch: batch, to: &state)
        XCTAssertEqual(state.workspace(for: entries[0].id)?.projectID, projectID)
        XCTAssertNotNil(state.workspace(for: entries[1].id))
        let maximum = await probe.maximumCommands(); XCTAssertLessThanOrEqual(maximum, 2)
    }

}
