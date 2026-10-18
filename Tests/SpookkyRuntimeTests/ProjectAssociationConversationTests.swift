import XCTest
import SpookkyCore
@testable import SpookkyWorkspace

private actor PrimaryAssociationProbe {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released: Bool
    private(set) var writes: [ConversationID] = []
    private(set) var directories: [String] = []
    init(paused: Bool = false) { released = !paused }
    func run(_ launch: LaunchSpec, _ id: ConversationID, _ resolution: ProjectAssociationResolution,
             _ current: @escaping @Sendable () async -> Bool) async -> ProviderProjectAssociation {
        started = true; startWaiter?.resume(); startWaiter = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        if await current() { writes.append(id); directories.append(launch.directory) }
        return ProviderProjectAssociation(sessionID: id.sessionID, projectID: "provider-project", status: .associated, message: "Fixture association")
    }
    func waitForStart() async { if !started { await withCheckedContinuation { startWaiter = $0 } } }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}

@MainActor final class ProjectAssociationConversationTests: XCTestCase {
    private struct Primary {
        let workspaceID: UUID
        let tabID: UUID
        let spec: LaunchSpec
        let event: AgentEvent
        var id: ConversationID { ConversationID(provider: .codex, sessionID: event.sessionID!) }
    }
    private func fixture() throws -> WorkspaceLocation {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-primary-association-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return WorkspaceLocation(path: url.standardizedFileURL.resolvingSymlinksInPath().path)
    }
    private func primary(_ session: String, state: inout WorkspaceState, location: WorkspaceLocation, project: UUID) throws -> Primary {
        let workspace = state.newWorkspace(location: location, projectID: project), tab = state.primaryTerminalID!
        state.editDraft(tab, tool: .codex)
        let spec = try LaunchSpec(tool: .codex, executable: "/fixture/codex", directory: location.path)
        state.apply(.preparing, to: tab); state.bindWorkspace(workspace); state.apply(.intent(spec, .none), to: tab)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: tab)
        let event = AgentEvent(bindingID: spec.operationID, invocationID: UUID(), secret: UUID(), provider: .codex,
                               kind: .working, sessionID: session)
        XCTAssertEqual(state.recordAgentEvent(event), tab)
        return Primary(workspaceID: workspace, tabID: tab, spec: spec, event: event)
    }
    func testSameCheckoutConversationsAssociateIndependentlyOfSupportingFocus() async throws {
        let location = try fixture(); defer { try? FileManager.default.removeItem(atPath: location.path) }
        var state = WorkspaceState(); let project = state.registerProject(location)
        let first = try primary("first", state: &state, location: location, project: project)
        let support = state.newTab(workspaceID: first.workspaceID)!
        let second = try primary("second", state: &state, location: location, project: project)
        state.selectWorkspace(first.workspaceID); state.selectTab(support)
        let store = WorkspaceStore(state: state), probe = PrimaryAssociationProbe()
        let coordinator = ProjectAssociationCoordinator(store: store, perform: { await probe.run($0, $1, $2, $3) })
        coordinator.observe(first.event, tabID: first.tabID); coordinator.observe(second.event, tabID: second.tabID)
        await coordinator.waitUntilIdle()
        XCTAssertEqual(store.state.workspaces.count, 2)
        XCTAssertEqual(store.state.selectedTab?.id, support)
        for primary in [first, second] {
            let workspace = store.state.workspace(for: primary.id)
            XCTAssertEqual(workspace?.currentProjectAssociation?.conversationID, primary.id)
            XCTAssertEqual(workspace?.primaryTerminal?.launch?.directory, location.path)
            XCTAssertEqual(workspace?.primaryTerminal?.binding?.directory, location.path)
        }
        let writes = await probe.writes, directories = await probe.directories
        XCTAssertEqual(Set(writes), [first.id, second.id]); XCTAssertEqual(directories, [location.path, location.path])
        XCTAssertNil(store.state.tab(support)?.projectAssociation)
    }
    func testHiddenViewRetainsAssociationWithoutChangingSelectionOrBinding() async throws {
        let location = try fixture(); defer { try? FileManager.default.removeItem(atPath: location.path) }
        var state = WorkspaceState(); let project = state.registerProject(location)
        let first = try primary("first", state: &state, location: location, project: project)
        let second = try primary("second", state: &state, location: location, project: project)
        let before = state.tab(first.tabID)?.binding
        let store = WorkspaceStore(state: state), probe = PrimaryAssociationProbe(paused: true)
        let coordinator = ProjectAssociationCoordinator(store: store, perform: { await probe.run($0, $1, $2, $3) })
        coordinator.observe(first.event, tabID: first.tabID); await probe.waitForStart()
        store.update { $0.hideWorkspace(first.workspaceID) }
        await probe.release(); await coordinator.waitUntilIdle()
        XCTAssertEqual(store.state.workspace(for: first.id)?.currentProjectAssociation?.status, .associated)
        XCTAssertEqual(store.state.workspace(for: first.id)?.viewClosed, true)
        XCTAssertEqual(store.state.selectedWorkspaceID, second.workspaceID)
        XCTAssertEqual(store.state.tab(first.tabID)?.binding, before)
    }
    func testLateResultFromPreviousInvocationCannotWriteOrAttach() async throws {
        let location = try fixture(); defer { try? FileManager.default.removeItem(atPath: location.path) }
        var state = WorkspaceState(); let project = state.registerProject(location)
        let first = try primary("first", state: &state, location: location, project: project)
        let store = WorkspaceStore(state: state), probe = PrimaryAssociationProbe(paused: true)
        let coordinator = ProjectAssociationCoordinator(store: store, perform: { await probe.run($0, $1, $2, $3) })
        coordinator.observe(first.event, tabID: first.tabID); await probe.waitForStart()
        let changed = AgentEvent(bindingID: first.spec.operationID, invocationID: UUID(), secret: UUID(), provider: .codex,
                                 kind: .working, sessionID: first.id.sessionID)
        store.update { _ = $0.recordAgentEvent(changed) }
        await probe.release(); await coordinator.waitUntilIdle()
        let writes = await probe.writes; XCTAssertTrue(writes.isEmpty)
        XCTAssertNil(store.state.workspace(for: first.id)?.currentProjectAssociation)
    }
    func testSupportingShellChildrenAndAmbiguousIdentityCannotOwnAssignment() throws {
        let location = try fixture(); defer { try? FileManager.default.removeItem(atPath: location.path) }
        var state = WorkspaceState(); let project = state.registerProject(location)
        let first = try primary("first", state: &state, location: location, project: project)
        let support = state.newTab(workspaceID: first.workspaceID)!
        let shell = try LaunchSpec(tool: .shell, executable: "/bin/zsh", directory: location.path)
        state.apply(.preparing, to: support); state.apply(.intent(shell, .none), to: support)
        state.apply(.observed(SessionBinding(spec: shell), dead: false, exitCode: nil, prompt: nil), to: support)
        let event = AgentEvent(bindingID: shell.operationID, invocationID: UUID(), secret: UUID(), provider: .codex,
                               kind: .working, sessionID: "manual-shell-session")
        _ = state.recordAgentEvent(event)
        XCTAssertEqual(state.workspaces.first { $0.id == first.workspaceID }?.conversationID, first.id)
        XCTAssertNil(ProjectAssociationCoordinator.candidate(event, tabID: support, state: state))
        let child = AgentEvent(bindingID: first.spec.operationID, invocationID: first.event.invocationID, secret: UUID(),
                               provider: .codex, kind: .childStarted, sessionID: "child", childID: "child")
        XCTAssertNil(ProjectAssociationCoordinator.candidate(child, tabID: first.tabID, state: state))
        let duplicate = try primary("first", state: &state, location: location, project: project)
        XCTAssertTrue(state.workspace(for: first.id)?.conversationOwnershipAmbiguous == true)
        XCTAssertNil(ProjectAssociationCoordinator.candidate(first.event, tabID: first.tabID, state: state))
        XCTAssertNil(ProjectAssociationCoordinator.candidate(duplicate.event, tabID: duplicate.tabID, state: state))
    }
    func testMigrationKeepsReceiptsWithEachOriginalAgentTerminal() throws {
        let location = try fixture(); defer { try? FileManager.default.removeItem(atPath: location.path) }
        var state = WorkspaceState(); state.version = 5
        let project = state.registerProject(location)
        let first = try primary("first", state: &state, location: location, project: project)
        state.associateConversation(first.id, workspaceID: first.workspaceID)
        let secondTab = state.newTab()!
        state.editDraft(secondTab, tool: .codex)
        let spec = try LaunchSpec(tool: .codex, executable: "/fixture/codex", directory: location.path)
        state.apply(.preparing, to: secondTab); state.apply(.intent(spec, .none), to: secondTab)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: secondTab)
        let secondEvent = AgentEvent(bindingID: spec.operationID, invocationID: UUID(), secret: UUID(), provider: .codex,
                                     kind: .working, sessionID: "second")
        _ = state.recordAgentEvent(secondEvent)
        let receipt = ProviderProjectAssociation(sessionID: "first", projectID: "provider-project", status: .associated, message: "Fixture")
        state.recordProjectAssociation(receipt, workspaceID: first.workspaceID, primaryTerminalID: first.tabID,
                                       invocationID: first.event.invocationID, operationID: first.spec.operationID)
        state.migrateConversationWorkspaces()
        XCTAssertEqual(state.workspaces.count, 2)
        XCTAssertEqual(state.workspace(for: first.id)?.primaryTerminalID, first.tabID)
        XCTAssertEqual(state.workspace(for: first.id)?.currentProjectAssociation, receipt)
        XCTAssertNil(state.workspace(for: ConversationID(provider: .codex, sessionID: "second"))?.currentProjectAssociation)
    }
}
