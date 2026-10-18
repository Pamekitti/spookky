import XCTest
@testable import SpookkyCore

final class WorkspaceSelectionTests: XCTestCase {
    func testFullPrimarySelectionRetainsRightPaneAndSplitExpansionSelectsSupport() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let primary = try XCTUnwrap(state.primaryTerminalID)
        let shell = try XCTUnwrap(state.newTab())
        state.setSupportingLayout(.split, fraction: 0.68)
        XCTAssertEqual(state.visibleTabIDs, [primary, shell])
        state.setSupportingLayout(.fullWidth)
        XCTAssertEqual(state.visibleTabIDs, [shell])
        state.selectPrimaryContent()
        XCTAssertEqual(state.selected?.support?.layout, .fullWidth)
        XCTAssertEqual(state.selected?.support?.selectedTabID, shell)
        XCTAssertEqual(state.selected?.support?.resolvedFullWidthSelection, .primary)
        XCTAssertEqual(state.selectedTab?.id, primary)
        XCTAssertEqual(state.visibleTabIDs, [primary])
        state.setSupportingLayout(.split)
        XCTAssertEqual(state.visibleTabIDs, [primary, shell])
        XCTAssertEqual(state.selected?.support?.fraction, 0.68)
        state.selectPrimaryContent()
        XCTAssertEqual(state.selected?.support?.selectedTabID, shell)
        XCTAssertEqual(state.visibleTabIDs, [primary, shell])
        state.setSupportingLayout(.fullWidth)
        XCTAssertEqual(state.selected?.support?.resolvedFullWidthSelection, .support(shell))
        XCTAssertEqual(state.selectedTab?.id, shell)
        XCTAssertEqual(state.visibleTabIDs, [shell])
        try state.validate()
    }

    func testFullNonterminalTargetsHideTerminalsAndShellSelectionRestoresBackingID() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let primary = try XCTUnwrap(state.primaryTerminalID), shell = try XCTUnwrap(state.newTab())
        state.setSupportingLayout(.fullWidth)
        for target in [SupportingTarget.file(path: "source.swift"), .browser(url: "about:blank"), .artifact(path: "/tmp/report.pdf"), .changes] {
            let supportID = try XCTUnwrap(state.openSupport(target, title: "Support"))
            XCTAssertEqual(state.selected?.support?.layout, .fullWidth)
            XCTAssertEqual(state.selected?.support?.fullWidthSelection, .support(supportID))
            XCTAssertEqual(state.visibleTabIDs, [])
            state.selectPrimaryContent()
            XCTAssertEqual(state.visibleTabIDs, [primary])
            state.selectSupport(supportID)
            XCTAssertEqual(state.visibleTabIDs, [])
        }
        state.selectSupport(shell)
        XCTAssertEqual(state.selectedTab?.id, shell)
        XCTAssertEqual(state.visibleTabIDs, [shell])
        state.selectTab(primary)
        XCTAssertEqual(state.selected?.support?.resolvedFullWidthSelection, .primary)
        state.selectTab(shell)
        XCTAssertEqual(state.selected?.support?.resolvedFullWidthSelection, .support(shell))
        XCTAssertEqual(state.visibleTabIDs, [shell])
        state.setSupportingLayout(.collapsed)
        XCTAssertEqual(state.visibleTabIDs, [primary])
        state.hideWorkspace(state.selectedWorkspaceID!)
        XCTAssertEqual(state.visibleTabIDs, [])
        try state.validate()
    }

    func testNewSupportingTerminalKeepsFullLayoutAndSelectsItself() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        state.setSupportingLayout(.fullWidth)
        state.selectPrimaryContent()
        let shell = try XCTUnwrap(state.newTab())
        XCTAssertEqual(state.selected?.support?.layout, .fullWidth)
        XCTAssertEqual(state.selected?.support?.resolvedFullWidthSelection, .support(shell))
        XCTAssertEqual(state.visibleTabIDs, [shell])
        try state.validate()
    }

    func testClosingSelectedSupportChoosesNearestLeftOtherwiseNext() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let primary = try XCTUnwrap(state.primaryTerminalID)
        let first = state.openSupport(.browser(url: "about:blank"), title: "First")!
        let second = state.openSupport(.browser(url: "about:blank"), title: "Second")!
        let third = state.openSupport(.browser(url: "about:blank"), title: "Third")!
        let fourth = state.openSupport(.browser(url: "about:blank"), title: "Fourth")!
        state.setSupportingLayout(.fullWidth)
        state.selectSupport(third); state.closeSupport(third)
        XCTAssertEqual(state.selected?.support?.selectedTabID, second)
        XCTAssertEqual(state.selected?.support?.resolvedFullWidthSelection, .support(second))
        state.closeSupport(first)
        XCTAssertEqual(state.selected?.support?.selectedTabID, second)
        state.closeSupport(second)
        XCTAssertEqual(state.selected?.support?.selectedTabID, fourth)
        XCTAssertEqual(state.selected?.support?.resolvedFullWidthSelection, .support(fourth))
        state.closeSupport(fourth)
        XCTAssertEqual(state.selected?.support?.layout, .collapsed)
        XCTAssertEqual(state.selected?.support?.resolvedFullWidthSelection, .primary)
        XCTAssertEqual(state.selectedTab?.id, primary)
        XCTAssertEqual(state.visibleTabIDs, [primary])
        try state.validate()
    }

    func testClosingInactiveSupportPreservesFullPrimaryAndRemainingRightSelection() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let first = state.openSupport(.browser(url: "about:blank"), title: "First")!
        let second = state.openSupport(.browser(url: "about:blank"), title: "Second")!
        let third = state.openSupport(.browser(url: "about:blank"), title: "Third")!
        state.selectSupport(second); state.setSupportingLayout(.fullWidth); state.selectPrimaryContent()
        state.closeSupport(third)
        XCTAssertEqual(state.selected?.support?.selectedTabID, second)
        XCTAssertEqual(state.selected?.support?.layout, .fullWidth)
        XCTAssertEqual(state.selected?.support?.fullWidthSelection, .primary)
        XCTAssertEqual(state.visibleTabIDs, [state.primaryTerminalID!])
        state.closeSupport(second)
        XCTAssertEqual(state.selected?.support?.selectedTabID, first)
        XCTAssertEqual(state.selected?.support?.fullWidthSelection, .primary)
        try state.validate()
    }

    func testOldV6FullSnapshotsDecodeToSelectedSupportOrPrimaryWithoutChangingDrafts() throws {
        for withSupport in [false, true] {
            var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
            let primary = state.primaryTerminalID!
            state.editDraft(primary, tool: .shell, prompt: "Retain shell draft 日本語")
            let shell = withSupport ? state.newTab() : nil
            state.setSupportingLayout(.fullWidth)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
            object.removeValue(forKey: "lastAgentTool")
            var workspaces = object["workspaces"] as! [[String: Any]]
            var panel = workspaces[0]["support"] as! [String: Any]
            panel.removeValue(forKey: "fullWidthSelection")
            workspaces[0]["support"] = panel; object["workspaces"] = workspaces
            let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertNil(restored.selected?.support?.fullWidthSelection)
            XCTAssertEqual(restored.selected?.support?.resolvedFullWidthSelection, shell.map { .support($0) } ?? .primary)
            XCTAssertEqual(restored.visibleTabIDs, [shell ?? primary])
            XCTAssertEqual(restored.tab(primary)?.draft, state.tab(primary)?.draft)
            XCTAssertNil(restored.lastAgentTool)
            try restored.validate()
        }
    }

    func testFullSelectionRoundTripAndInvalidSupportReference() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let support = state.openSupport(.browser(url: "about:blank"), title: "Browser")!
        state.setSupportingLayout(.fullWidth)
        for selection in [FullWidthSelection.primary, .support(support)] {
            state.workspaces[0].support?.fullWidthSelection = selection
            let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(restored.selected?.support?.fullWidthSelection, selection)
            XCTAssertEqual(restored, state)
            try restored.validate()
        }
        state.workspaces[0].support?.fullWidthSelection = .support(UUID())
        XCTAssertThrowsError(try state.validate())
    }

    func testSelectionAndClosurePreserveBackingRecordsAndUnsentDrafts() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let primary = state.primaryTerminalID!
        state.editDraft(primary, tool: .claude, prompt: "Unsent launch draft\n$(literal)")
        let spec = try LaunchSpec(tool: .claude, executable: "/bin/cat", directory: "/tmp", initialPrompt: "Original receipt")
        state.apply(.preparing, to: primary); state.apply(.intent(spec, .pending), to: primary)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: .suppliedToProcess), to: primary)
        let shell = state.newTab()!
        state.editDraft(shell, tool: .shell, prompt: "Supporting draft")
        let records = state.selected!.tabs
        state.setSupportingLayout(.fullWidth)
        state.selectPrimaryContent(); state.selectSupport(shell)
        state.closeSupport(shell)
        XCTAssertEqual(state.selected?.tabs, records)
        XCTAssertEqual(state.tab(primary)?.launch, spec)
        XCTAssertEqual(state.tab(primary)?.promptDelivery, .suppliedToProcess)
        XCTAssertEqual(state.selected?.retainedSupportingTerminals.map(\.id), [shell])
        try state.validate()
    }

    func testRemovingBackingRecordRepairsReopenedSupportingViewReference() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let shell = state.newTab()!
        state.closeSupport(shell)
        let reopened = state.openSupport(.terminal(tabID: shell), title: "Reopened")!
        XCTAssertNotEqual(reopened, shell)
        state.setSupportingLayout(.fullWidth)
        state.closeTab(shell)
        XCTAssertEqual(state.selected?.support?.fullWidthSelection, .primary)
        XCTAssertEqual(state.visibleTabIDs, [state.primaryTerminalID!])
        try state.validate()
    }

    func testMovingSupportingAgentRepairsFullViewWhilePreservingItsDraft() throws {
        var state = WorkspaceState(); let source = state.newWorkspace(directory: "/tmp")
        let agent = state.newTab()!
        state.editDraft(agent, tool: .claude, prompt: "Independent draft")
        state.setSupportingLayout(.fullWidth)
        let record = state.tab(agent)
        state.separateAgentTerminal(agent)
        XCTAssertEqual(state.tab(agent), record)
        state.selectWorkspace(source)
        XCTAssertEqual(state.selected?.support?.resolvedFullWidthSelection, .primary)
        XCTAssertEqual(state.selected?.support?.layout, .collapsed)
        try state.validate()
    }

    func testLegacyTabAndSplitVisibilityIgnoresNewFullViewSelection() throws {
        var state = WorkspaceState(); state.version = 5; state.newWorkspace(directory: "/tmp")
        let first = state.selectedTab!.id, second = state.newTab()!, third = state.newTab()!
        state.setSplit(first: first, second: second)
        state.selectTab(third)
        XCTAssertEqual(state.visibleTabIDs, [first, third])
        state.collapseSplit()
        XCTAssertEqual(state.visibleTabIDs, [third])
        try state.validate()
    }
}

final class AgentToolPreferenceTests: XCTestCase {
    func testNewWorkspaceUsesAgentPreferenceAndPreservesLegacyStartupBehavior() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        XCTAssertEqual(state.selectedTab?.draft.tool, .codex)
        state.lastTool = .claude
        state.newWorkspace(directory: "/tmp")
        XCTAssertEqual(state.selectedTab?.draft.tool, .claude)
        state.lastAgentTool = .codex; state.lastTool = .shell
        state.newWorkspace(directory: "/tmp")
        XCTAssertEqual(state.selectedTab?.draft.tool, .codex)
        state.lastAgentTool = .claude; state.lastTool = .codex
        state.newWorkspace(directory: "/tmp")
        XCTAssertEqual(state.selectedTab?.draft.tool, .claude)
        state.version = 5; state.lastTool = .shell
        state.newWorkspace(directory: "/tmp")
        XCTAssertEqual(state.selectedTab?.draft.tool, .shell)
        try state.validate()
    }

    func testShellSelectionAndLaunchDoNotEraseLastAgentPreferenceOrAnotherDraft() throws {
        var state = WorkspaceState(); let first = state.newWorkspace(directory: "/tmp")
        let draft = state.primaryTerminalID!
        state.editDraft(draft, tool: .claude, prompt: "Keep Claude draft")
        let before = state.tab(draft)
        state.newWorkspace(directory: "/tmp")
        let shell = state.primaryTerminalID!
        state.editDraft(shell, tool: .shell)
        XCTAssertEqual(state.lastAgentTool, .claude)
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        state.apply(.preparing, to: shell); state.apply(.intent(spec, .none), to: shell)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: shell)
        state.newWorkspace(directory: "/tmp")
        XCTAssertEqual(state.selectedTab?.draft.tool, .claude)
        XCTAssertEqual(state.tab(draft), before)
        state.selectWorkspace(first)
        XCTAssertEqual(state.selectedTab?.draft.prompt, "Keep Claude draft")
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state)).lastAgentTool, .claude)
        try state.validate()
    }

    func testPreferenceChangesOnlyForEditableAgentSelectionsAndRejectsShellPreference() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let tab = state.primaryTerminalID!
        state.editDraft(tab, tool: .claude)
        state.editDraft(tab, prompt: "Only text")
        XCTAssertEqual(state.lastAgentTool, .claude)
        let spec = try LaunchSpec(tool: .claude, executable: "/bin/cat", directory: "/tmp")
        state.apply(.preparing, to: tab); state.apply(.intent(spec, .none), to: tab)
        state.editDraft(tab, tool: .codex)
        XCTAssertEqual(state.lastAgentTool, .claude)
        state.lastAgentTool = .shell
        XCTAssertThrowsError(try state.validate())
    }

    func testMigratedShellDraftRemainsShellWhileNextWorkspaceDefaultsToCodex() throws {
        var state = WorkspaceState(); state.version = 5
        state.newWorkspace(directory: "/tmp")
        let original = state.selectedTab!
        state.migrateConversationWorkspaces()
        XCTAssertEqual(state.tab(original.id), original)
        state.newWorkspace(directory: "/tmp")
        XCTAssertEqual(state.selectedTab?.draft.tool, .codex)
        XCTAssertEqual(state.tab(original.id), original)
        try state.validate()
    }
}
