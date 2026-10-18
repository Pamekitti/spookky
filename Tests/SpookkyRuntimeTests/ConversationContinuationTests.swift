import XCTest
@testable import SpookkyCore
import SpookkyRuntime
@testable import SpookkyWorkspace

private struct ContinuationResolver: ExecutableResolver {
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try LaunchSpec(tool: tool, executable: "/bin/echo", directory: directory)
    }
}
private actor ContinuationGate {
    private var parked: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { parked = $0; observer?.resume(); observer = nil }
    }
    func entered() async {
        if parked != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { parked?.resume(); parked = nil }
}
private actor ContinuationRuntime: SessionRuntime {
    var creates = 0, stops = 0, inspections = 0
    var dead = false
    func markDead() { dead = true }
    func counts() -> [Int] { [creates, stops, inspections] }
    func create(_ spec: LaunchSpec) async throws -> SessionBinding { creates += 1; return SessionBinding(spec: spec) }
    func terminate(_ binding: SessionBinding) async throws { stops += 1 }
    func inspect(_ binding: SessionBinding) async throws -> SessionObservation? {
        inspections += 1
        return SessionObservation(binding: binding, processID: 4242, dead: dead, exitCode: dead ? 0 : nil, clients: 1)
    }
    func list() async throws -> [SessionBinding] { [] }
    func attachmentArguments(_ binding: SessionBinding) async throws -> [String] { [] }
}

@MainActor final class ConversationContinuationTests: XCTestCase {
    private let identity = ConversationID(provider: .codex, sessionID: "11111111-1111-4111-8111-111111111111")
    private let capabilities = ProviderContinuationCapabilities(provider: .codex, version: "codex-cli 0.162.1", help: "app", resumeHelp: "[SESSION_ID] --cd", remoteHelp: "start pair")

    private func fixture(live: Bool = true) throws -> WorkspaceStore {
        var state = WorkspaceState()
        let workspace = state.ensureConversationWorkspace(identity, location: WorkspaceLocation(path: "/tmp/original/checkout"))
        let primary = try XCTUnwrap(state.primaryTerminalID)
        state.editDraft(primary, tool: .codex, prompt: "retained primary launch draft")
        if live {
            let spec = try LaunchSpec(tool: .codex, executable: "/tmp/codex", directory: "/tmp/original/checkout")
            state.bindWorkspace(workspace)
            state.apply(.preparing, to: primary)
            state.apply(.intent(spec, .none), to: primary)
            state.apply(.observed(SessionBinding(spec: spec, phase: .attachedRuntime), dead: false, exitCode: nil, prompt: PromptDelivery.none), to: primary)
        }
        let shell = try XCTUnwrap(state.newTab(startDirectory: "/tmp/supporting/shell"))
        state.editDraft(shell, tool: .shell, prompt: "retained supporting draft")
        _ = state.openSupport(.terminal(tabID: shell), title: "Supporting shell")
        return WorkspaceStore(state: state)
    }
    private func coordinator(_ store: WorkspaceStore, gate: ContinuationGate? = nil) -> ConversationContinuationCoordinator {
        let capabilities = capabilities
        return ConversationContinuationCoordinator(store: store, resolver: ContinuationResolver(), probe: { _ in
            if let gate { await gate.pause() }
            return capabilities
        }, ownership: { _, _ in .init(route: .unknown, explanation: "Fixture external ownership is unknown.") })
    }

    func testPrimaryTargetDoesNotFollowSupportingShellFileBrowserOrArtifact() throws {
        let store = try fixture(), coordinator = coordinator(store)
        let workspace = try XCTUnwrap(store.state.selected), target = try coordinator.capture(workspaceID: workspace.id)
        XCTAssertEqual(target.terminalID, workspace.primaryTerminalID)
        XCTAssertEqual(target.conversationID, identity)
        XCTAssertEqual(target.directory, "/tmp/original/checkout")
        XCTAssertNotEqual(target.terminalID, store.state.selectedTab?.id)
        for support in [SupportingTarget.file(path: "fixture.swift"), .browser(url: "http://localhost:8080/form"), .artifact(path: "fixture.pdf")] {
            store.update { $0.openSupport(support, title: "Support"); $0.setSupportingLayout(.fullWidth) }
            XCTAssertEqual(try coordinator.capture(workspaceID: workspace.id), target)
        }
    }
    func testMetadataCwdOverridesCheckoutGroupingAndSupportScope() throws {
        let store = try fixture(live: false), coordinator = coordinator(store)
        let workspace = try XCTUnwrap(store.state.selectedWorkspaceID)
        coordinator.metadata = { id in ConversationMetadata(id: id, title: nil, directory: "/tmp/provider/original/subdirectory", updatedAt: Date()) }
        XCTAssertEqual(try coordinator.capture(workspaceID: workspace).directory, "/tmp/provider/original/subdirectory")
    }
    func testSavedEntryWithoutBindingStaysGuidedAndPreservesAllDrafts() async throws {
        let store = try fixture(live: false), coordinator = coordinator(store), before = store.state
        let target = try coordinator.capture(workspaceID: XCTUnwrap(store.state.selectedWorkspaceID))
        let prepared = try await coordinator.prepare(target)
        let presentation = try XCTUnwrap(prepared)
        XCTAssertNil(presentation.target.binding)
        XCTAssertEqual(presentation.ownership?.route, .unknown)
        XCTAssertTrue(presentation.guide.desktop.contains("no verified live Codex prompt"))
        XCTAssertTrue(presentation.guide.returnToTerminal.contains(identity.sessionID))
        XCTAssertTrue(presentation.guide.remote.contains("No remote route has been enabled"))
        XCTAssertTrue(presentation.guide.returnToTerminal.contains("No surviving primary binding"))
        XCTAssertEqual(store.state, before)
    }
    func testCancellationDuringProbeDoesNotMutateStateOrLaunch() async throws {
        let store = try fixture(), gate = ContinuationGate(), coordinator = coordinator(store, gate: gate), before = store.state
        let target = try coordinator.capture(workspaceID: XCTUnwrap(store.state.selectedWorkspaceID))
        let operation = Task { try await coordinator.prepare(target) }
        await gate.entered(); operation.cancel(); await gate.release()
        do { _ = try await operation.value; XCTFail("Cancellation should be explicit") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(store.state, before)
    }
    func testChangedPrimaryIdentityDuringProbeDropsThePresentation() async throws {
        let store = try fixture(), gate = ContinuationGate(), coordinator = coordinator(store, gate: gate)
        let target = try coordinator.capture(workspaceID: XCTUnwrap(store.state.selectedWorkspaceID))
        let operation = Task { try await coordinator.prepare(target) }
        await gate.entered()
        store.update { state in
            let index = state.workspaces.firstIndex { $0.id == target.workspaceID }!
            state.workspaces[index].conversationID = ConversationID(provider: .claude, sessionID: "22222222-2222-4222-8222-222222222222")
        }
        let changed = store.state
        await gate.release()
        let presentation = try await operation.value
        XCTAssertNil(presentation)
        XCTAssertEqual(store.state, changed)
    }
    func testPrimaryTerminalChangeDuringProbeDropsThePresentation() async throws {
        let store = try fixture(), gate = ContinuationGate(), coordinator = coordinator(store, gate: gate)
        let target = try coordinator.capture(workspaceID: XCTUnwrap(store.state.selectedWorkspaceID))
        let operation = Task { try await coordinator.prepare(target) }
        await gate.entered()
        let other = try XCTUnwrap(store.state.selected?.tabs.first { $0.id != target.terminalID }?.id)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.state)) as? [String: Any])
        var workspaces = try XCTUnwrap(object["workspaces"] as? [[String: Any]])
        workspaces[0]["primaryTerminalID"] = other.uuidString
        workspaces[0]["selectedTabID"] = other.uuidString
        workspaces[0]["support"] = ["tabs": [], "layout": "collapsed", "fraction": 0.5]
        object["workspaces"] = workspaces
        let changed = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: object))
        try changed.validate()
        store.update { $0 = changed }
        await gate.release()
        let presentation = try await operation.value
        XCTAssertNil(presentation)
        XCTAssertEqual(store.state, changed)
    }
    func testClosingWorkspaceDuringProbeDoesNotReopenItsView() async throws {
        let store = try fixture(), gate = ContinuationGate(), coordinator = coordinator(store, gate: gate)
        let target = try coordinator.capture(workspaceID: XCTUnwrap(store.state.selectedWorkspaceID))
        let operation = Task { try await coordinator.prepare(target) }
        await gate.entered()
        store.update { $0.hideWorkspace(target.workspaceID) }
        let closed = store.state
        await gate.release()
        let presentation = try await operation.value
        XCTAssertNil(presentation)
        XCTAssertEqual(store.state, closed)
        XCTAssertEqual(store.state.workspaces.first?.viewClosed, true)
    }
    func testUnavailableSavedHistoryStaysVisibleAsAGuidedWarning() async throws {
        let store = try fixture(live: false), coordinator = coordinator(store)
        coordinator.metadata = { id in ConversationMetadata(id: id, title: nil, directory: "/tmp/missing/provider-folder", updatedAt: Date(), availability: .folderUnavailable) }
        let target = try coordinator.capture(workspaceID: XCTUnwrap(store.state.selectedWorkspaceID)), before = store.state
        let prepared = try await coordinator.prepare(target)
        XCTAssertTrue(prepared?.warning?.contains("saved folder or history is unavailable") == true)
        XCTAssertNil(prepared?.target.binding)
        XCTAssertEqual(store.state, before)
    }
    func testProbeFailurePreservesDraftsSupportingStateAndKnownBinding() async throws {
        let store = try fixture(), before = store.state
        let coordinator = ConversationContinuationCoordinator(store: store, resolver: ContinuationResolver(),
            probe: { _ in throw LaunchError.command("Disposable provider probe failed") })
        let target = try coordinator.capture(workspaceID: XCTUnwrap(store.state.selectedWorkspaceID))
        do { _ = try await coordinator.prepare(target); XCTFail("Expected a probe failure") } catch {}
        XCTAssertEqual(store.state, before)
    }
    func testChangedBindingAndMetadataInvalidateCapturedTarget() throws {
        let store = try fixture(), coordinator = coordinator(store)
        let target = try coordinator.capture(workspaceID: XCTUnwrap(store.state.selectedWorkspaceID))
        coordinator.metadata = { id in ConversationMetadata(id: id, title: nil, directory: "/tmp/provider/new-cwd", updatedAt: Date()) }
        XCTAssertFalse(coordinator.isCurrent(target))
        coordinator.metadata = nil
        let spec = try LaunchSpec(tool: .codex, executable: "/tmp/codex", directory: target.directory)
        store.update { $0.updateTab(target.terminalID) { $0.binding = SessionBinding(spec: spec); $0.launch = spec } }
        XCTAssertFalse(coordinator.isCurrent(target))
    }
    func testUnsupportedProviderVersionOffersNoSimulatedDesktopOrRemoteSuccess() async throws {
        let store = try fixture(live: false)
        let coordinator = ConversationContinuationCoordinator(store: store, resolver: ContinuationResolver(),
            probe: { _ in ProviderContinuationCapabilities(provider: .codex, version: "unknown", help: "") },
            ownership: { _, _ in .init(route: .unknown, explanation: "Unverified provider version") })
        let target = try coordinator.capture(workspaceID: XCTUnwrap(store.state.selectedWorkspaceID))
        let prepared = try await coordinator.prepare(target)
        let presentation = try XCTUnwrap(prepared)
        XCTAssertNil(presentation.capabilities.desktopCommand)
        XCTAssertNil(presentation.capabilities.remoteCommand)
        XCTAssertFalse(presentation.ownership?.canInvokeNativeResume ?? true)
        XCTAssertFalse(presentation.guide.desktop.contains("/app"))
        XCTAssertTrue(presentation.guide.remote.contains("No remote route has been enabled"))
    }
    func testReconnectOnlyInspectsTheCapturedPrimaryAndKeepsSupportDrafts() async throws {
        let store = try fixture(), runtime = ContinuationRuntime(), coordinator = coordinator(store)
        let launches = LaunchCoordinator(store: store, runtime: runtime, resolver: ContinuationResolver())
        let target = try coordinator.capture(workspaceID: XCTUnwrap(store.state.selectedWorkspaceID)), before = store.state
        let connected = await coordinator.reconnect(target, using: launches)
        XCTAssertTrue(connected)
        XCTAssertEqual(store.state, before)
        let counts = await runtime.counts(); XCTAssertEqual(counts, [0, 0, 1])
        await runtime.markDead()
        let afterExit = await coordinator.reconnect(target, using: launches)
        XCTAssertFalse(afterExit)
        let later = await runtime.counts(); XCTAssertEqual(later, [0, 0, 2])
        XCTAssertEqual(store.state.selected?.support, before.selected?.support)
        XCTAssertEqual(store.state.tab(target.terminalID)?.draft, before.tab(target.terminalID)?.draft)
    }
}
