import XCTest
import SpookkyCore
import SpookkyRuntime
@testable import SpookkyWorkspace

private actor FixtureRuntime: SessionRuntime {
    var creates = 0
    var bindings: [SessionBinding] = []
    private var specs: [LaunchSpec] = []
    private var createObserver: CheckedContinuation<Void, Never>?
    func launchedSpecs() -> [LaunchSpec] { specs }
    func waitForCreate() async {
        if creates > 0 { return }
        await withCheckedContinuation { createObserver = $0 }
    }
    enum Mode {
        case normal, missingExecutable, uncertainLaunch, unavailable, partialShutdown, ended, missingFolder
    }
    private var mode = Mode.normal
    func configure(_ value: Mode) { mode = value }
    func count() -> Int { creates }
    func create(_ spec: LaunchSpec) async throws -> SessionBinding {
        creates += 1; specs.append(spec)
        createObserver?.resume(); createObserver = nil
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
private actor GatedLaunchResolver: ExecutableResolver {
    private var waiting: CheckedContinuation<LaunchSpec, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var pending: LaunchSpec?
    private var calls = 0
    func count() -> Int { calls }
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        calls += 1
        pending = try LaunchSpec(tool: tool, executable: "/bin/cat", directory: directory, initialPrompt: tool == .shell ? nil : prompt)
        return await withCheckedContinuation { waiting = $0; observer?.resume(); observer = nil }
    }
    func entered() async {
        if waiting != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() {
        guard let pending else { return }
        waiting?.resume(returning: pending); waiting = nil
    }
}
private struct UnexpectedLaunchResolver: ExecutableResolver {
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        throw LaunchError.invalid("A prepared continuation must not resolve its provider again.")
    }
}
private actor FailedPersistence: WorkspacePersistence {
    func load() async throws -> WorkspaceState? { nil }
    func save(_ state: WorkspaceState) async throws { throw LaunchError.invalid("Disk full") }
}

@MainActor final class CoordinatorTests: XCTestCase {
    func testModelSelectionIsFrozenAndReattachmentDoesNotRelaunch() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.showLanding(homeDirectory: "/tmp") }
        let id = try XCTUnwrap(store.state.primaryTerminalID)
        store.update {
            $0.editDraft(id, tool: .codex, prompt: "Only once")
            $0.editModelSelection(id, selection: AgentModelSelection(model: "selected", effort: "high"))
        }
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        await coordinator.launch(id)
        let frozen = try XCTUnwrap(store.state.tab(id)?.launch)
        XCTAssertTrue(frozen.arguments.contains("--model=selected"))
        store.update { $0.editModelSelection(id, selection: AgentModelSelection(model: "different")) }
        await coordinator.reconcile(id); await coordinator.launch(id)
        XCTAssertEqual(store.state.tab(id)?.launch, frozen)
        let count = await runtime.count(); XCTAssertEqual(count, 1)
    }
    func testConcurrentStartingPromptsNameWorkspaceOnce() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.newWorkspace(directory: "/tmp") }
        let first = try XCTUnwrap(store.state.selectedTab?.id)
        store.update { $0.editDraft(first, tool: .codex, prompt: "Fix login timeout"); $0.newTab() }
        let second = try XCTUnwrap(store.state.selectedTab?.id)
        store.update { $0.editDraft(second, tool: .claude, prompt: "Repair file previews") }
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        async let a: Void = coordinator.launch(first)
        async let b: Void = coordinator.launch(second)
        _ = await (a, b)
        let title = try XCTUnwrap(store.state.selected?.title)
        XCTAssertTrue(["Fix login timeout", "Repair file previews"].contains(title))
        XCTAssertEqual(store.state.selected?.automaticTitle, .prompt)
        let count = await runtime.count(); XCTAssertEqual(count, 2)
        await coordinator.reconcile(first); await coordinator.reconcile(second)
        XCTAssertEqual(store.state.selected?.title, title)
        store.update { $0.newTab(); $0.editDraft($0.selectedTab!.id, tool: .codex, prompt: "A third task") }
        await coordinator.launch(store.state.selectedTab!.id)
        XCTAssertEqual(store.state.selected?.title, title)
    }
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
    func testPreparedContinuationPreservesExactNativeResumeAndAttachArguments() async throws {
        let session = "11111111-1111-4111-8111-111111111111", directory = "/tmp/original checkout/subdir"
        for (provider, arguments) in [(SessionTool.codex, ["resume", session, "-C", directory]),
                                      (.codex, ["resume", session]), (.claude, ["--resume", session]),
                                      (.claude, ["attach", "background-42"])] {
            let store = WorkspaceStore(), runtime = FixtureRuntime()
            store.update { $0.newWorkspace(directory: "/tmp/original checkout") }
            let id = try XCTUnwrap(store.state.selectedTab?.id)
            let item = ConversationMetadata(id: ConversationID(provider: provider, sessionID: session), title: nil,
                                            directory: directory, updatedAt: Date())
            let prepared = try LaunchSpec(tool: provider, executable: "/tmp/native-provider", arguments: arguments,
                                          directory: directory, environment: ["PATH": "/tmp/provider-bin"])
            let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: UnexpectedLaunchResolver())
            await coordinator.resume(id, conversation: item, prepared: prepared)
            let specs = await runtime.launchedSpecs()
            XCTAssertEqual(specs, [prepared])
            XCTAssertEqual(store.state.tab(id)?.promptDelivery, PromptDelivery.none)
            XCTAssertEqual(store.state.selected?.directory, "/tmp/original checkout")
            await coordinator.resume(id, conversation: item, prepared: prepared)
            let count = await runtime.count(); XCTAssertEqual(count, 1)
        }
    }
    func testPreparedContinuationRejectsOtherIDsFoldersPromptsAndPermissionOverrides() async throws {
        let session = "11111111-1111-4111-8111-111111111111"
        let badSpecs: [LaunchSpec] = [
            try LaunchSpec(tool: .claude, executable: "/bin/cat", arguments: ["--resume", session], directory: "/tmp"),
            try LaunchSpec(tool: .codex, executable: "/bin/cat", arguments: ["resume", session], directory: "/elsewhere"),
            try LaunchSpec(tool: .codex, executable: "/bin/cat", arguments: ["resume", "22222222-2222-4222-8222-222222222222"], directory: "/tmp"),
            try LaunchSpec(tool: .codex, executable: "/bin/cat", arguments: ["resume", session, "new prompt"], directory: "/tmp"),
            try LaunchSpec(tool: .codex, executable: "/bin/cat", arguments: ["resume", session, "--dangerously-bypass-approvals-and-sandbox"], directory: "/tmp")
        ]
        for prepared in badSpecs {
            let store = WorkspaceStore(), runtime = FixtureRuntime()
            store.update { $0.newWorkspace(directory: "/tmp") }
            let id = try XCTUnwrap(store.state.selectedTab?.id)
            let item = ConversationMetadata(id: ConversationID(provider: .codex, sessionID: session), title: nil, directory: "/tmp", updatedAt: Date())
            await LaunchCoordinator(store: store, runtime: runtime, resolver: UnexpectedLaunchResolver()).resume(id, conversation: item, prepared: prepared)
            let count = await runtime.count(); XCTAssertEqual(count, 0)
            XCTAssertEqual(store.state.tab(id)?.status, .failed)
            XCTAssertNil(store.state.tab(id)?.launch)
        }
    }
    func testConcurrentResumeReservesOnePreflightAndCreatesOneProcess() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime(), resolver = GatedLaunchResolver()
        store.update { $0.newWorkspace(directory: "/tmp") }
        let id = try XCTUnwrap(store.state.selectedTab?.id)
        let item = ConversationMetadata(id: ConversationID(provider: .codex, sessionID: "11111111-1111-4111-8111-111111111111"),
                                        title: nil, directory: "/tmp", updatedAt: Date())
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: resolver)
        let first = Task { await coordinator.resume(id, conversation: item) }
        await resolver.entered()
        XCTAssertTrue(coordinator.isBusy(id))
        await coordinator.resume(id, conversation: item)
        await resolver.release(); await first.value
        let resolutions = await resolver.count(), creates = await runtime.count()
        XCTAssertEqual(resolutions, 1); XCTAssertEqual(creates, 1)
    }
    func testCancelledLandingPreflightKeepsItsDraftAndDoesNotPromoteOrLaunch() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime(), resolver = GatedLaunchResolver()
        store.update { $0.showLanding(homeDirectory: "/tmp"); $0.editDraft($0.primaryTerminalID!, tool: .codex, prompt: "Keep this landing draft") }
        let id = try XCTUnwrap(store.state.primaryTerminalID), before = store.state
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: resolver)
        let operation = Task { await coordinator.launch(id) }
        await resolver.entered()
        XCTAssertTrue(store.state.selected?.isLanding == true)
        operation.cancel(); await resolver.release(); await operation.value
        XCTAssertEqual(store.state, before)
        let count = await runtime.count(); XCTAssertEqual(count, 0)
    }
    func testLandingAgentPromotesAtIntentAndCancellationAfterCreateStillRecordsReceipt() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.showLanding(homeDirectory: "/tmp"); $0.editDraft($0.primaryTerminalID!, tool: .claude, prompt: "Retain this instruction") }
        let id = try XCTUnwrap(store.state.primaryTerminalID), workspaceID = try XCTUnwrap(store.state.selectedWorkspaceID)
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver())
        let operation = Task { await coordinator.launch(id) }
        await runtime.waitForCreate()
        XCTAssertFalse(store.state.selected?.isLanding == true)
        XCTAssertNotNil(store.state.tab(id)?.launch)
        operation.cancel(); await operation.value
        XCTAssertEqual(store.state.tab(id)?.status, .running)
        XCTAssertNotNil(store.state.tab(id)?.binding)
        XCTAssertEqual(store.state.tab(id)?.promptDelivery, .suppliedToProcess)
        XCTAssertEqual(store.state.tab(id)?.draft.prompt, "Retain this instruction")
        await coordinator.launch(id)
        let count = await runtime.count(); XCTAssertEqual(count, 1)
        store.update { $0.showLanding(homeDirectory: "/tmp") }
        XCTAssertNotEqual(store.state.selectedWorkspaceID, workspaceID)
        XCTAssertEqual(store.state.selectedTab?.draft.prompt, "")
    }
    func testSupportingShellKeepsLandingAgentDraftUnpromoted() async throws {
        let store = WorkspaceStore(), runtime = FixtureRuntime()
        store.update { $0.showLanding(homeDirectory: "/tmp"); $0.editDraft($0.primaryTerminalID!, tool: .codex, prompt: "Agent draft") }
        let primary = try XCTUnwrap(store.state.primaryTerminalID)
        store.update { $0.newTab() }
        let shell = try XCTUnwrap(store.state.selectedTab?.id)
        await LaunchCoordinator(store: store, runtime: runtime, resolver: FixtureResolver()).launch(shell, tool: .shell)
        XCTAssertTrue(store.state.selected?.isLanding == true)
        XCTAssertEqual(store.state.tab(primary)?.draft.prompt, "Agent draft")
        XCTAssertNil(store.state.tab(primary)?.launch)
        XCTAssertEqual(store.state.tab(shell)?.status, .running)
    }

}
