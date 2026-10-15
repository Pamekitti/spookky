import XCTest
@testable import SpookkyCore

final class WorkspaceTests: XCTestCase {
    func testWorkspaceAndTabSwitchingPreservesDraftAndScope() throws {
        var state = WorkspaceState()
        let first = state.newWorkspace(directory: "/tmp/first")
        let draft = try XCTUnwrap(state.selectedTab?.id)
        state.editDraft(draft, tool: .claude, prompt: "Explain café 日本語")
        state.newTab()
        let shell = try XCTUnwrap(state.selectedTab?.id)
        let spec = try LaunchSpec(operationID: shell, tool: .shell, executable: "/bin/zsh", directory: "/tmp/first")
        state.apply(.preparing, to: shell)
        state.apply(.intent(spec, .none), to: shell)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: shell)
        state.changeDirectory("/tmp/wrong")
        XCTAssertEqual(state.selected?.directory, "/tmp/first")
        state.newWorkspace(directory: "/tmp/second")
        state.selectWorkspace(first)
        state.selectTab(draft)
        XCTAssertEqual(state.selectedTab?.draft.prompt, "Explain café 日本語")
        XCTAssertEqual(state.selectedTab?.draft.tool, .claude)
        state.selectTab(shell)
        XCTAssertEqual(state.selectedTab?.binding?.id, shell)
    }

    func testClosingInactiveEntriesDoesNotStealSelection() throws {
        var state = WorkspaceState()
        let first = state.newWorkspace(directory: "/tmp/a")
        let second = state.newWorkspace(directory: "/tmp/a")
        XCTAssertNotEqual(first, second)
        let activeTab = try XCTUnwrap(state.selectedTab?.id)
        state.newTab()
        let secondTab = try XCTUnwrap(state.selectedTab?.id)
        state.closeTab(activeTab)
        XCTAssertEqual(state.selectedTab?.id, secondTab)
        state.closeWorkspace(first)
        XCTAssertEqual(state.selectedWorkspaceID, second)
        state.closeTab(secondTab)
        XCTAssertTrue(state.workspaces.isEmpty)
        XCTAssertNil(state.selectedWorkspaceID)
        XCTAssertNil(state.selectedTab)
    }

    func testClosingLastTabSelectsAnotherWorkspaceAndPreservesItsDraft() throws {
        var state = WorkspaceState()
        let first = state.newWorkspace(directory: "/tmp/a")
        let retained = try XCTUnwrap(state.selectedTab?.id)
        state.editDraft(retained, tool: .codex, prompt: "Keep this draft")
        state.newWorkspace(directory: "/tmp/b")
        let closing = try XCTUnwrap(state.selectedTab?.id)

        state.closeTab(closing)

        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.selectedWorkspaceID, first)
        XCTAssertEqual(state.selectedTab?.id, retained)
        XCTAssertEqual(state.selectedTab?.draft.prompt, "Keep this draft")
    }

    func testClosingLastInactiveTabPreservesActiveWorkspace() throws {
        var state = WorkspaceState()
        state.newWorkspace(directory: "/tmp/a")
        let inactive = try XCTUnwrap(state.selectedTab?.id)
        let active = state.newWorkspace(directory: "/tmp/b")
        let selected = try XCTUnwrap(state.selectedTab?.id)

        state.closeTab(inactive)

        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.selectedWorkspaceID, active)
        XCTAssertEqual(state.selectedTab?.id, selected)
    }

    func testLaunchIntentSurvivesProviderDraftChanges() throws {
        var state = WorkspaceState()
        state.newWorkspace(directory: "/tmp")
        let id = try XCTUnwrap(state.selectedTab?.id)
        let launch = try LaunchSpec(tool: .codex, executable: "/tmp/codex", directory: "/tmp", initialPrompt: "Keep as data")
        state.apply(.preparing, to: id)
        state.apply(.intent(launch, .pending), to: id)
        state.editDraft(id, tool: .claude, prompt: "Another draft")
        XCTAssertEqual(state.selectedTab?.launch, launch)
        XCTAssertEqual(state.selectedTab?.launch?.arguments, ["--", "Keep as data"])
        state.newTab()
        XCTAssertNil(state.selectedTab?.launch)
    }
}
