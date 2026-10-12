import XCTest
import SpookkyCore
import SpookkyRuntime
@testable import SpookkyWorkspace

private actor FixtureRuntime: SessionRuntime {
    var creates = 0
    var bindings: [SessionBinding] = []
    enum Mode {
        case normal, missingExecutable, uncertainLaunch, unavailable, partialShutdown, ended, missingFolder
    }
    private var mode = Mode.normal
    func configure(_ value: Mode) { mode = value }
    func count() -> Int { creates }
    func create(_ spec: LaunchSpec) async throws -> SessionBinding {
        creates += 1
        try await Task.sleep(for: .milliseconds(30))
        if mode == .missingExecutable { throw LaunchError.invalid("Missing executable") }
        if mode == .missingFolder { throw LaunchError.folderUnavailable(spec.directory) }
        let binding = SessionBinding(spec: spec, phase: mode == .uncertainLaunch ? .starting : .attachedRuntime)
        bindings.append(binding)
        if mode == .uncertainLaunch { throw LaunchError.uncertainLaunch }
        return binding
    }
    func inspect(_ binding: SessionBinding) async throws -> SessionObservation? {
        if mode == .uncertainLaunch { return nil }
        if mode == .unavailable { throw LaunchError.command("Fixture runtime unavailable") }
        return bindings.contains { $0.id == binding.id } ? SessionObservation(binding: binding, processID: 1, dead: mode == .ended, exitCode: mode == .ended ? 7 : nil, clients: 0) : nil
    }
    func list() async throws -> [SessionBinding] { bindings }
    func attachmentArguments(_ binding: SessionBinding) async throws -> [String] { [] }
    func terminate(_ binding: SessionBinding) async throws {
        if mode == .partialShutdown && bindings.count == 1 { throw LaunchError.command("Fixture termination failure") }
        bindings.removeAll { $0.id == binding.id }
    }
}
private struct FixtureResolver: ExecutableResolver {
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try LaunchSpec(tool: tool, executable: "/bin/cat", directory: directory, initialPrompt: tool == .shell ? nil : prompt)
    }
}
private actor FailedPersistence: WorkspacePersistence {
    func load() async throws -> WorkspaceState? { nil }
    func save(_ state: WorkspaceState) async throws { throw LaunchError.invalid("Disk full") }
}

@MainActor final class CoordinatorTests: XCTestCase {
    func testRepeatedLaunchAndWorkspaceSwitch() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.newWorkspace(directory: "/tmp") }
        let tab = try XCTUnwrap(store.state.selectedTab?.id)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        let first = Task { await coordinator.launch(tab, tool: .shell) }
        await Task.yield()
        await coordinator.launch(tab, tool: .shell)
        store.update { $0.newWorkspace(directory: "/other") }
        let selected = store.state.selectedWorkspaceID
        await first.value
        XCTAssertEqual(store.state.selectedWorkspaceID, selected)
        XCTAssertEqual(store.state.tab(tab)?.status, .running)
        let count = await runtime.count(); XCTAssertEqual(count, 1)
    }
    func testPrelaunchFailureAllowsChangingProvider() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.newWorkspace(directory: "/tmp") }
        let id = try XCTUnwrap(store.state.selectedTab?.id)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        await runtime.configure(.missingExecutable)
        await coordinator.launch(id, tool: .codex)
        XCTAssertTrue(store.state.tab(id)!.isEditable)
        store.update { $0.editDraft(id, tool: .claude, prompt: "Unicode 日本語") }
        await runtime.configure(.normal)
        await coordinator.launch(id)
        XCTAssertEqual(store.state.tab(id)?.launch?.tool, .claude)
        XCTAssertEqual(store.state.tab(id)?.launch?.arguments, ["--", "Unicode 日本語"])
    }
    func testUncertainRetryDoesNotCreateSecondProcess() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.newWorkspace(directory: "/tmp") }
        let id = try XCTUnwrap(store.state.selectedTab?.id)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        await runtime.configure(.uncertainLaunch)
        await coordinator.launch(id)
        XCTAssertEqual(store.state.tab(id)?.status, .uncertain)
        await coordinator.launch(id)
        let count = await runtime.count(); XCTAssertEqual(count, 1)
        await runtime.configure(.normal)
        await coordinator.reconcile(id)
        XCTAssertEqual(store.state.tab(id)?.status, .running)
    }
    func testSaveFailurePreventsProcessStart() async throws {
        let store = WorkspaceStore(persistence: FailedPersistence()), runtime = FixtureRuntime()
        store.update { $0.newWorkspace(directory: "/tmp") }
        let id = try XCTUnwrap(store.state.selectedTab?.id)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        store.update { $0.editDraft(id, tool: .codex, prompt: "Retain 日本語\nsecond line") }
        await coordinator.launch(id)
        let count = await runtime.count(); XCTAssertEqual(count, 0)
        XCTAssertNotNil(store.saveError)
        XCTAssertEqual(store.state.tab(id)?.draft.prompt, "Retain 日本語\nsecond line")
        XCTAssertEqual(store.state.tab(id)?.status, .failed)
    }
    func testUnavailableRuntimeRecoversWithoutLaunchOrPromptResend() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.newWorkspace(directory: "/tmp") }
        let id = try XCTUnwrap(store.state.selectedTab?.id)
        store.update { $0.editDraft(id, tool: .codex, prompt: "Keep 日本語\nsecond line") }
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        await coordinator.launch(id)
        let request = store.state.tab(id)?.launch
        await runtime.configure(.unavailable)
        await coordinator.reconcile(id)
        XCTAssertEqual(store.state.tab(id)?.status, .unavailable)
        XCTAssertEqual(store.state.tab(id)?.launch, request)
        await coordinator.launch(id)
        await runtime.configure(.normal)
        await coordinator.reconcile(id)
        XCTAssertEqual(store.state.tab(id)?.status, .running)
        XCTAssertEqual(store.state.tab(id)?.promptDelivery, .suppliedToProcess)
        XCTAssertEqual(store.state.tab(id)?.draft.prompt, "Keep 日本語\nsecond line")
        let count = await runtime.count(); XCTAssertEqual(count, 1)
    }
    func testRuntimeFailureDoesNotChangeNewSelection() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.newWorkspace(directory: "/tmp") }
        let id = try XCTUnwrap(store.state.selectedTab?.id)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        await coordinator.launch(id)
        store.update { $0.newWorkspace(directory: "/other") }
        let selected = store.state.selectedWorkspaceID
        await runtime.configure(.unavailable)
        await coordinator.reconcile(id)
        XCTAssertEqual(store.state.selectedWorkspaceID, selected)
        XCTAssertEqual(store.state.tab(id)?.status, .unavailable)
    }
    func testEndedProcessKeepsExitEvidenceAndDoesNotRelaunch() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.newWorkspace(directory: "/tmp") }
        let id = try XCTUnwrap(store.state.selectedTab?.id)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        await coordinator.launch(id)
        await runtime.configure(.ended)
        await coordinator.reconcile(id)
        XCTAssertEqual(store.state.tab(id)?.status, .ended)
        XCTAssertEqual(store.state.tab(id)?.exitCode, 7)
        await coordinator.launch(id)
        let count = await runtime.count(); XCTAssertEqual(count, 1)
    }
    func testMissingFolderRetainsPromptAndRequestedDirectory() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.newWorkspace(directory: "/missing/fixture"); $0.editDraft($0.selectedTab!.id, tool: .claude, prompt: "Keep my draft") }
        let id = try XCTUnwrap(store.state.selectedTab?.id)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        await runtime.configure(.missingFolder)
        await coordinator.launch(id)
        XCTAssertEqual(store.state.tab(id)?.status, .failed)
        XCTAssertEqual(store.state.tab(id)?.failure?.recovery, .locateFolder)
        XCTAssertEqual(store.state.tab(id)?.draft.prompt, "Keep my draft")
        XCTAssertEqual(store.state.selected?.directory, "/missing/fixture")
    }
    func testMissingFolderWithLivePrivateServerOffersLocateAndKeepsDraft() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-polish-test-" + UUID().uuidString.prefix(8))
        let runtime = try TmuxRuntime(executable: PackagedRuntime.tmux(),
            helper: FileManager.default.currentDirectoryPath + "/.build/debug/spookky-launch", root: root)
        let socket = await runtime.socket
        defer {
            _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: root)
        }
        let live = try await runtime.create(LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp"))
        let liveObservation = try await runtime.inspect(live)
        let process = try XCTUnwrap(liveObservation).processID
        let missing = root.appendingPathComponent("moved folder 世界").path
        let store = WorkspaceStore()
        store.update { $0.newWorkspace(directory: missing); $0.editDraft($0.selectedTab!.id, tool: .claude, prompt: "Retain this unsent draft") }
        let id = try XCTUnwrap(store.state.selectedTab?.id)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        await coordinator.launch(id)
        XCTAssertEqual(store.state.tab(id)?.status, .failed)
        XCTAssertEqual(store.state.tab(id)?.failure?.recovery, .locateFolder)
        XCTAssertNil(store.state.tab(id)?.launch)
        XCTAssertNil(store.state.tab(id)?.binding)
        XCTAssertEqual(store.state.tab(id)?.draft.prompt, "Retain this unsent draft")
        XCTAssertEqual(store.state.selected?.directory, missing)
        let retained = try await runtime.inspect(live)
        XCTAssertEqual(retained?.processID, process)
        try await runtime.terminate(live)
    }

    func testPrivateOwnerLossBecomesEndedWithoutRestart() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-m4-test-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TmuxRuntime(executable: PackagedRuntime.tmux(),
            helper: FileManager.default.currentDirectoryPath + "/.build/debug/spookky-launch", root: root)
        let store = WorkspaceStore()
        store.update { $0.newWorkspace(directory: "/tmp") }
        let id = try XCTUnwrap(store.state.selectedTab?.id)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        await coordinator.launch(id)
        XCTAssertEqual(store.state.tab(id)?.status, .running)
        let result = try await ProcessRunner.asyncRun(PackagedRuntime.tmux(), ["-S", root.appendingPathComponent("socket").path, "kill-server"])
        XCTAssertEqual(result.status, 0)
        await coordinator.reconcile(id)
        XCTAssertEqual(store.state.tab(id)?.status, .ended)
        await coordinator.launch(id)
        XCTAssertNil(store.state.tab(id)?.binding)
        XCTAssertEqual(store.state.tab(id)?.status, .ended)
        let check = try await ProcessRunner.asyncRun(PackagedRuntime.tmux(), ["-S", root.appendingPathComponent("socket").path, "list-sessions"])
        XCTAssertNotEqual(check.status, 0)
    }
    func testSplitSelectionAndRemoval() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let first = try XCTUnwrap(state.selectedTab?.id)
        let second = try XCTUnwrap(state.newTab())
        state.setSplit(first: first, second: second)
        let third = try XCTUnwrap(state.newTab())
        XCTAssertEqual(state.visibleTabIDs, [first, third])
        state.closeTab(first)
        XCTAssertNil(state.selected?.split)
        XCTAssertEqual(state.selectedTab?.id, third)
        try state.validate()
    }
    func testInterruptedPreparationRestoresEditableDraft() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let id = try XCTUnwrap(state.selectedTab?.id)
        state.editDraft(id, tool: .codex, prompt: "Keep me")
        state.apply(.preparing, to: id)
        state.restoreInterruptedDrafts()
        XCTAssertEqual(state.tab(id)?.status, .draft)
        XCTAssertEqual(state.tab(id)?.draft.prompt, "Keep me")
    }
    func testPartialShutdownRetainsRunningEntry() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.newWorkspace(directory: "/tmp") }
        let first = try XCTUnwrap(store.state.selectedTab?.id)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        await coordinator.launch(first)
        store.update { $0.newTab() }; let second = try XCTUnwrap(store.state.selectedTab?.id)
        await coordinator.launch(second)
        await runtime.configure(.partialShutdown)
        try await coordinator.terminate(first)
        do { try await coordinator.terminate(second); XCTFail("Second termination should fail") } catch { }
        XCTAssertEqual(store.state.tab(first)?.status, .ended)
        XCTAssertEqual(store.state.tab(second)?.status, .running)
        XCTAssertNotNil(store.state.tab(second)?.binding)
        XCTAssertEqual(store.state.selected?.tabs.count, 2)
        await coordinator.launch(first)
        let count = await runtime.count(); XCTAssertEqual(count, 2)
    }
    func testMissingRuntimeRestoresEndedStateWithoutRetry() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.newWorkspace(directory: "/tmp") }
        let id = try XCTUnwrap(store.state.selectedTab?.id)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        await coordinator.launch(id)
        let binding = try XCTUnwrap(store.state.tab(id)?.binding)
        try await runtime.terminate(binding)
        await coordinator.reconcile(id)
        XCTAssertEqual(store.state.tab(id)?.status, .ended)
        XCTAssertNil(store.state.tab(id)?.binding)
        await coordinator.reconcile(id)
        await coordinator.launch(id)
        XCTAssertEqual(store.state.tab(id)?.status, .ended)
        let count = await runtime.count(); XCTAssertEqual(count, 1)
    }
}
