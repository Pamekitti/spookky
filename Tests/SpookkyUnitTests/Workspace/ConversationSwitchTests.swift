import XCTest
@testable import SpookkyCore

final class ConversationSwitchTests: XCTestCase {
    let a = ConversationID(provider: .codex, sessionID: "00000000-0000-4000-8000-000000000001")
    let b = ConversationID(provider: .codex, sessionID: "00000000-0000-4000-8000-000000000002")
    func running() throws -> (WorkspaceState, UUID, UUID, LaunchSpec) {
        var state = WorkspaceState()
        let workspace = state.ensureConversationWorkspace(a, location: WorkspaceLocation(path: "/tmp"))
        let terminal = state.primaryTerminalID!
        let spec = try LaunchSpec(tool: .codex, executable: "/bin/cat", directory: "/tmp")
        state.editDraft(terminal, prompt: "A launch draft")
        state.renameWorkspace(workspace, "A alias")
        state.bindWorkspace(workspace)
        state.apply(.preparing, to: terminal); state.apply(.intent(spec, .none), to: terminal)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: terminal)
        state.recordAgentEvent(event(spec, a))
        state.setProviderTitle("A provider title", conversationID: a)
        state.openSupport(.browser(url: "about:blank"), title: "A form")
        state.recordCatalogMetadata(ConversationMetadata(id: a, title: "A provider title", directory: "/tmp", updatedAt: Date()), workspaceID: workspace, projectID: nil)
        return (state, workspace, terminal, spec)
    }
    func event(_ spec: LaunchSpec, _ id: ConversationID, kind: AgentEventKind = .attached) -> AgentEvent {
        AgentEvent(bindingID: spec.operationID, invocationID: spec.operationID, secret: UUID(), provider: id.provider, kind: kind, sessionID: id.sessionID)
    }
    func testSwitchPreservesOldConversationAndMovesOnlyLiveTerminal() throws {
        var (state, workspace, terminal, spec) = try running()
        let old = state.workspace(for: a)!, receipt = state.tab(terminal)!.binding
        state.updateTab(terminal) { $0.activity?.state = .finished; $0.activity?.manualUnread = true; $0.activity?.preview = "A preview" }
        XCTAssertEqual(state.recordAgentEvent(event(spec, b), followTerminal: true), terminal)
        let saved = try XCTUnwrap(state.workspace(for: a)), current = try XCTUnwrap(state.workspace(for: b))
        XCTAssertEqual(saved.id, workspace); XCTAssertEqual(saved.support, old.support)
        XCTAssertEqual(saved.displayTitle, "A alias"); XCTAssertEqual(saved.catalogMetadata?.id, a)
        XCTAssertEqual(saved.primaryTerminal?.draft.prompt, "A launch draft")
        XCTAssertNil(saved.primaryTerminal?.binding); XCTAssertNil(saved.primaryTerminal?.launch)
        XCTAssertEqual(saved.primaryTerminal?.providerTitle?.title, "A provider title")
        XCTAssertEqual(current.primaryTerminalID, terminal); XCTAssertEqual(current.primaryTerminal?.binding, receipt)
        XCTAssertEqual(current.primaryTerminal?.launch, spec); XCTAssertEqual(current.primaryTerminal?.draft.prompt, "")
        XCTAssertEqual(current.primaryTerminal?.activity?.displayState, .idle)
        XCTAssertEqual(current.primaryTerminal?.activity?.unread, false); XCTAssertNil(current.primaryTerminal?.activity?.preview)
        XCTAssertEqual(current.support?.tabs.count, 0); XCTAssertEqual(state.selectedWorkspaceID, current.id)
        XCTAssertEqual(state.workspaces.flatMap(\.tabs).filter { $0.binding?.id == spec.operationID }.count, 1)
        let count = state.workspaces.count
        state.recordAgentEvent(event(spec, b)); XCTAssertEqual(state.workspaces.count, count)
        state.setProviderTitle("A renamed", conversationID: a); state.setProviderTitle("B renamed", conversationID: b)
        XCTAssertEqual(state.workspace(for: a)?.primaryTerminal?.providerTitle?.title, "A renamed")
        XCTAssertEqual(state.workspace(for: b)?.displayTitle, "B renamed")
        try state.validate()
        let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
    }
    func testBackgroundSwitchKeepsSupportingSelectionAndReusesSavedDestination() throws {
        var (state, workspace, terminal, spec) = try running()
        let destination = state.ensureConversationWorkspace(b, location: WorkspaceLocation(path: "/tmp"), select: false)
        state.openSupport(.artifact(path: "/tmp/report.html"), title: "B artifact", workspaceID: destination)
        state.renameWorkspace(destination, "B alias")
        let before = state.workspace(for: a)!, retained = state.workspace(for: b)!.support
        state.recordAgentEvent(event(spec, b))
        XCTAssertEqual(state.selectedWorkspaceID, workspace)
        XCTAssertEqual(state.workspace(for: a)?.support, before.support)
        XCTAssertEqual(state.workspace(for: b)?.id, destination)
        XCTAssertEqual(state.workspace(for: b)?.support, retained)
        XCTAssertEqual(state.workspace(for: b)?.viewClosed, true)
        XCTAssertEqual(state.workspace(for: b)?.displayTitle, "B alias")
        XCTAssertEqual(state.workspace(for: b)?.primaryTerminalID, terminal)
        XCTAssertEqual(state.workspace(for: b)?.anchor, before.anchor)
        XCTAssertEqual(state.workspaces.count, 2); try state.validate()
    }
    func testSavedDestinationDraftGetsARecoverableIndependentEntry() throws {
        var (state, _, terminal, spec) = try running()
        let destination = state.ensureConversationWorkspace(b, location: WorkspaceLocation(path: "/tmp"), select: false)
        let draft = state.workspace(for: b)!.primaryTerminalID!
        state.editDraft(draft, tool: .codex, prompt: "B unsent draft")
        let first = state.openSupport(.browser(url: "about:blank"), title: "B first", workspaceID: destination)!
        state.openSupport(.artifact(path: "/tmp/report.html"), title: "B second", workspaceID: destination)
        state.selectSupport(first, workspaceID: destination)
        var support = state.workspace(for: b)?.support
        support?.fullWidthSelection = .primary
        state.recordAgentEvent(event(spec, b), followTerminal: true)
        XCTAssertEqual(state.workspace(for: b)?.id, destination)
        XCTAssertEqual(state.workspace(for: b)?.primaryTerminalID, terminal)
        XCTAssertEqual(state.tab(draft)?.draft.prompt, "B unsent draft")
        XCTAssertNil(state.workspace(containing: draft)?.conversationID)
        XCTAssertEqual(state.workspace(containing: draft)?.primaryTerminalID, draft)
        XCTAssertEqual(state.workspace(for: b)?.support, support)
        XCTAssertEqual(state.tab(terminal)?.draft.prompt, "")
        try state.validate()
    }
    func testForegroundSwitchKeepsDestinationFullLayoutAndRetainedSupportSelection() throws {
        var (state, _, terminal, spec) = try running()
        let destination = state.ensureConversationWorkspace(b, location: WorkspaceLocation(path: "/tmp"), select: false)
        let draft = state.workspace(for: b)!.primaryTerminalID!
        state.editDraft(draft, tool: .codex, prompt: "Retained B draft")
        let first = state.openSupport(.browser(url: "about:blank"), title: "B form", workspaceID: destination)!
        state.openSupport(.artifact(path: "/tmp/report.html"), title: "B artifact", workspaceID: destination)
        state.selectSupport(first, workspaceID: destination)
        state.setSupportingLayout(.fullWidth, fraction: 0.67, workspaceID: destination)
        var expected = try XCTUnwrap(state.workspace(for: b)?.support)
        expected.fullWidthSelection = .primary
        XCTAssertEqual(state.recordAgentEvent(event(spec, b), followTerminal: true), terminal)
        XCTAssertEqual(state.selectedWorkspaceID, destination)
        XCTAssertEqual(state.selected?.support, expected)
        XCTAssertEqual(state.selectedTab?.id, terminal)
        XCTAssertEqual(state.visibleTabIDs, [terminal])
        XCTAssertEqual(state.tab(draft)?.draft.prompt, "Retained B draft")
        let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.selected?.support, expected)
        XCTAssertEqual(restored.visibleTabIDs, [terminal])
        try restored.validate()
    }

    func testExistingOwnerAndConflictingScopeStayExplicitAndKeepBothBindings() throws {
        for otherDirectory in ["/tmp", "/tmp/other"] {
            var (state, _, terminal, spec) = try running()
            state.ensureConversationWorkspace(b, location: WorkspaceLocation(path: otherDirectory), select: false)
            let other = state.workspace(for: b)!.primaryTerminalID!
            let otherSpec = try LaunchSpec(tool: .codex, executable: "/bin/cat", directory: otherDirectory)
            state.apply(.preparing, to: other); state.apply(.intent(otherSpec, .none), to: other)
            state.recordAgentEvent(event(spec, b))
            let duplicates = state.workspaces.filter { $0.conversationID == b }
            XCTAssertEqual(duplicates.count, 2); XCTAssertTrue(duplicates.allSatisfy { $0.conversationOwnershipAmbiguous == true })
            XCTAssertEqual(state.tab(terminal)?.binding?.id, spec.operationID)
            XCTAssertEqual(state.tab(other)?.launch, otherSpec)
            try state.validate()
        }
    }
    func testPrimitiveAssociationCannotReplaceEstablishedIdentityAndInvalidEventDoesNotMove() throws {
        var (state, workspace, _, spec) = try running()
        let before = state
        state.associateConversation(b, workspaceID: workspace)
        XCTAssertEqual(state, before)
        XCTAssertNil(state.recordAgentEvent(event(spec, b, kind: .working)))
        XCTAssertEqual(state, before)
        var child = event(spec, b); child.childID = "child"
        state.recordAgentEvent(child)
        XCTAssertEqual(state.workspace(for: a)?.id, workspace); XCTAssertNil(state.workspace(for: b))
    }
    func testUnpreparedDestinationWorktreeDraftIsNeverConsumed() throws {
        var (state, _, terminal, spec) = try running()
        let destination = state.ensureConversationWorkspace(b, location: WorkspaceLocation(path: "/tmp"), select: false)
        let index = state.workspaces.firstIndex { $0.id == destination }!
        var draft = LocationDraft(); draft.mode = .worktree; draft.branch = "planned"; draft.destination = "/tmp/planned"
        state.workspaces[index].locationDraft = draft
        let old = state.workspaces[index]
        state.recordAgentEvent(event(spec, b))
        let retained = state.workspaces.first { $0.id == destination }!
        XCTAssertEqual(retained.locationDraft, draft); XCTAssertEqual(retained.primaryTerminal, old.primaryTerminal)
        XCTAssertNotEqual(state.workspace(containing: terminal)?.id, destination)
        XCTAssertEqual(retained.conversationOwnershipAmbiguous, true)
        try state.validate()
    }
}
