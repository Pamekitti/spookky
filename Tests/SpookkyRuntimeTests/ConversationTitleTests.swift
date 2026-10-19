import XCTest
import GRDB
@testable import SpookkyCore
import SpookkyPersistence

final class ConversationTitleTests: XCTestCase {
    private let sessionA = "00000000-0000-4000-8000-000000000001"
    private let sessionB = "00000000-0000-4000-8000-000000000002"
    private func conversation(_ state: inout WorkspaceState, provider: SessionTool = .codex, session: String, title: String) -> UUID {
        let id = ConversationID(provider: provider, sessionID: session)
        let workspace = state.ensureConversationWorkspace(id, location: WorkspaceLocation(path: "/tmp/checkout"))
        state.setProviderTitle(title, conversationID: id)
        return workspace
    }
    func testCanonicalIdentityAndFoundationSetterDriveRowTitle() {
        var state = WorkspaceState()
        let workspace = conversation(&state, session: sessionA, title: "Current title")
        let original = state.selected!.title
        state.updateConversationTitle(provider: .claude, sessionID: sessionA, title: "Wrong provider")
        state.updateConversationTitle(provider: .codex, sessionID: sessionB, title: "Wrong conversation")
        XCTAssertEqual(state.selected?.displayTitle, "Current title")
        state.setProviderTitle("External rename", conversationID: ConversationID(provider: .codex, sessionID: sessionA))
        XCTAssertEqual(state.selected?.displayTitle, "External rename")
        XCTAssertEqual(state.selected?.title, original)
        XCTAssertEqual(state.selected?.displayProvider, .codex)
        state.setProviderTitle(nil, conversationID: ConversationID(provider: .codex, sessionID: sessionA))
        XCTAssertEqual(state.selected?.displayTitle, original)
        XCTAssertEqual(state.selectedWorkspaceID, workspace)
    }
    func testSupportingSelectionTitlesAndActivityDoNotReplacePrimaryIdentity() throws {
        var state = WorkspaceState(); conversation(&state, session: sessionA, title: "Primary conversation")
        let primary = state.primaryTerminalID!
        let shell = state.newTab()!
        state.renameTab(shell, "Tools shell")
        state.updateTab(primary) { $0.activity = AgentActivity(invocationID: UUID(), provider: .codex); $0.activity?.state = .working }
        state.updateTab(shell) { $0.activity = AgentActivity(invocationID: UUID(), provider: .claude); $0.activity?.state = .needsInput }
        let targets: [SupportingTarget] = [.file(path: "src/example.swift"), .changes, .browser(url: "about:blank"), .artifact(path: "/tmp/report.pdf"), .terminal(tabID: shell)]
        for target in targets {
            let id = try XCTUnwrap(state.openSupport(target, title: target == .terminal(tabID: shell) ? "Tools shell" : "Content"))
            state.selectSupport(id)
            XCTAssertEqual(state.selected?.displayTitle, "Primary conversation")
            XCTAssertEqual(state.selected?.displayProvider, .codex)
            XCTAssertEqual(state.selected?.activityState, .working)
            XCTAssertFalse(state.selected!.needsAttention)
            XCTAssertEqual(state.primaryTerminalID, primary)
        }
        state.closeSupport(state.selected!.support!.selectedTabID!)
        XCTAssertEqual(state.selected?.displayTitle, "Primary conversation")
        XCTAssertNotNil(state.tab(shell))
    }
    func testSameCheckoutConversationsHaveIndependentProviderTitles() {
        var state = WorkspaceState()
        let first = conversation(&state, session: sessionA, title: "Codex conversation")
        let second = conversation(&state, provider: .claude, session: sessionB, title: "Claude conversation")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(state.workspaces[0].directory, state.workspaces[1].directory)
        state.newTab(); state.openSupport(.browser(url: "about:blank"), title: "Preview")
        state.setProviderTitle("Codex renamed", conversationID: ConversationID(provider: .codex, sessionID: sessionA))
        XCTAssertEqual(state.workspaces[0].displayTitle, "Codex renamed")
        XCTAssertEqual(state.workspaces[1].displayTitle, "Claude conversation")
    }
    func testWorkspaceAndMigratedPrimaryAliasesSurviveDatabaseRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = WorkspaceState(); let first = conversation(&state, session: sessionA, title: "Provider title")
        state.renameTab(state.primaryTerminalID!, "Migrated terminal alias")
        XCTAssertEqual(state.selected?.displayTitle, "Migrated terminal alias")
        state.renameWorkspace(first, "Workspace alias")
        let second = conversation(&state, provider: .claude, session: sessionB, title: "Claude provider")
        state.renameTab(state.primaryTerminalID!, "Primary alias")
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        try await database.save(state)
        let loaded = try await database.load(); var restored = try XCTUnwrap(loaded)
        restored.restoreAgentActivity()
        restored.setProviderTitle("New provider title", conversationID: ConversationID(provider: .codex, sessionID: sessionA))
        restored.setProviderTitle("New Claude title", conversationID: ConversationID(provider: .claude, sessionID: sessionB))
        XCTAssertEqual(restored.workspaces.first { $0.id == first }?.displayTitle, "Workspace alias")
        XCTAssertEqual(restored.workspaces.first { $0.id == second }?.displayTitle, "Primary alias")
        XCTAssertEqual(restored.workspaces.map(\.directory), state.workspaces.map(\.directory))
    }
    func testRefreshChangesOnlyPrimaryDisplayCacheAndRetainsClosedViewAndDrafts() throws {
        var state = WorkspaceState(); let workspace = conversation(&state, session: sessionA, title: "Before")
        let primary = state.primaryTerminalID!, shell = state.newTab()!
        state.editDraft(shell, prompt: "Unsent 日本語\nline two")
        state.openSupport(.browser(url: "http://localhost:3000"), title: "Form preview")
        state.hideWorkspace(workspace)
        let before = state
        state.setProviderTitle("After", conversationID: ConversationID(provider: .codex, sessionID: sessionA))
        var expected = before
        expected.updateTab(primary) { $0.providerTitle = ProviderConversationTitle(provider: .codex, sessionID: sessionA, title: "After") }
        XCTAssertEqual(state, expected)
        XCTAssertEqual(state.workspaces[0].viewClosed, true)
        XCTAssertEqual(state.tab(shell)?.draft.prompt, "Unsent 日本語\nline two")
    }
    func testAssociationUsesWorkspacePrimaryAndDoesNotCreateRuntimeActivity() throws {
        var state = WorkspaceState(); let workspace = state.newWorkspace(directory: "/tmp")
        let primary = state.primaryTerminalID!, shell = state.newTab()!
        state.associateConversation(provider: .claude, sessionID: sessionA, title: "Saved conversation", workspaceID: workspace)
        XCTAssertEqual(state.selected?.conversationID, ConversationID(provider: .claude, sessionID: sessionA))
        XCTAssertEqual(state.selected?.displayTitle, "Saved conversation")
        XCTAssertEqual(state.selected?.displayProvider, .claude)
        XCTAssertNotNil(state.tab(primary)?.providerTitle)
        XCTAssertNil(state.tab(shell)?.providerTitle)
        XCTAssertNil(state.tab(primary)?.binding); XCTAssertNil(state.tab(primary)?.activity)
        XCTAssertEqual(state.selectedTab?.id, shell)
        state.associateConversation(provider: .codex, sessionID: sessionB, title: "Wrong association", workspaceID: workspace)
        XCTAssertEqual(state.selected?.displayTitle, "Saved conversation")
        try state.validate()
    }
    func testObservedIdentityChangeRejectsOldCacheAndUpdates() throws {
        var state = WorkspaceState(); conversation(&state, session: sessionA, title: "Old title")
        let primary = state.primaryTerminalID!
        let spec = try LaunchSpec(tool: .codex, executable: "/bin/cat", directory: "/tmp")
        state.apply(.preparing, to: primary); state.apply(.intent(spec, .none), to: primary)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: primary)
        state.recordAgentEvent(AgentEvent(bindingID: spec.operationID, invocationID: spec.operationID, secret: UUID(), provider: .codex, kind: .attached, sessionID: sessionB), followTerminal: true)
        XCTAssertNil(state.tab(primary)?.providerTitle)
        XCTAssertEqual(state.selected?.conversationID?.sessionID, sessionB)
        state.updateConversationTitle(provider: .codex, sessionID: sessionA, title: "Stale title")
        XCTAssertNotEqual(state.selected?.displayTitle, "Stale title")
        state.updateConversationTitle(provider: .codex, sessionID: sessionB, title: "New title")
        XCTAssertEqual(state.selected?.displayTitle, "New title")
    }
    func testOptionalCacheDecodesAndVersionFiveMigrationKeepsEveryAliasAndBinding() throws {
        var state = WorkspaceState(); state.version = 5
        let original = state.newWorkspace(directory: "/tmp")
        state.renameWorkspace(original, "Workspace alias")
        let first = state.primaryTerminalID!
        state.editDraft(first, tool: .codex)
        state.updateTab(first) {
            $0.activity = AgentActivity(invocationID: UUID(), provider: .codex); $0.activity?.sessionID = sessionA
            $0.providerTitle = ProviderConversationTitle(provider: .codex, sessionID: sessionA, title: "Cached title")
        }
        let second = state.newTab()!; state.editDraft(second, tool: .claude, prompt: "Keep draft"); state.renameTab(second, "Terminal alias")
        let backing = state.workspaces.flatMap(\.tabs)
        var migrated = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        migrated.migrateConversationWorkspaces(); try migrated.validate()
        XCTAssertEqual(Set(migrated.workspaces.flatMap(\.tabs).map(\.id)), Set(backing.map(\.id)))
        for tab in backing { XCTAssertEqual(migrated.tab(tab.id), tab) }
        XCTAssertTrue(migrated.workspaces.allSatisfy { $0.displayTitle == "Workspace alias" })
        let modern = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(WorkspaceState()))
        XCTAssertEqual(modern.version, 8)
    }
    func testHideReopenAndSupportCloseKeepPrimaryPresentationAndReceipts() throws {
        var state = WorkspaceState(); let workspace = conversation(&state, session: sessionA, title: "Retained title")
        let primary = state.primaryTerminalID!, spec = try LaunchSpec(tool: .codex, executable: "/bin/cat", directory: "/tmp")
        state.apply(.preparing, to: primary); state.apply(.intent(spec, .none), to: primary)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: primary)
        let browser = state.openSupport(.browser(url: "about:blank"), title: "Browser")!
        let before = state.tab(primary)
        state.hideWorkspace(workspace); state.selectWorkspace(workspace); state.closeSupport(browser)
        XCTAssertEqual(state.tab(primary), before)
        XCTAssertEqual(state.selected?.displayTitle, "Retained title")
        XCTAssertEqual(state.selected?.displayProvider, .codex)
    }
    func testProviderValidationTitleBoundsAndContentTypeNames() {
        var state = WorkspaceState(); let workspace = state.newWorkspace(directory: "/tmp")
        for (provider, session) in [(SessionTool.shell, sessionA), (.codex, "not-a-uuid"), (.claude, ""), (.claude, "bad\nID")] {
            state.associateConversation(provider: provider, sessionID: session, title: "Ignore", workspaceID: workspace)
        }
        XCTAssertNil(state.selected?.conversationID)
        state.associateConversation(provider: .codex, sessionID: sessionA, title: " Multi\nline\t title ", workspaceID: workspace)
        XCTAssertEqual(state.selected?.displayTitle, "Multi line title")
        state.setProviderTitle(String(repeating: "界", count: 1000), conversationID: ConversationID(provider: .codex, sessionID: sessionA))
        XCTAssertEqual(state.selected?.displayTitle.count, 256)
        state.setProviderTitle("a" + String(repeating: "\u{0301}", count: 10000), conversationID: ConversationID(provider: .codex, sessionID: sessionA))
        XCTAssertLessThanOrEqual(state.selected!.displayTitle.unicodeScalars.count, 2048)
        XCTAssertEqual(SupportingTab(target: .file(path: "src/app.swift"), title: "Old").displayTitle, "app.swift")
        XCTAssertEqual(SupportingTab(target: .artifact(path: "/tmp/report.pdf"), title: "Old").displayTitle, "report.pdf")
        for alias in ["New tab", "Codex", "Claude Code"] {
            XCTAssertEqual(SupportingTab(target: .terminal(tabID: UUID()), title: alias).displayTitle, alias)
        }
        state.newTab()
        XCTAssertEqual(state.selected?.support?.selected?.displayTitle, "Terminal")
        XCTAssertEqual(SupportingTab(target: .browser(url: "about:blank"), title: "Preview form").displayTitle, "Preview form")
    }
}

extension ConversationTitleTests {
    func testGenericProviderIdentifierDoesNotReplaceDescriptiveTitle() {
        var state = WorkspaceState()
        let id = ConversationID(provider: .claude, sessionID: sessionA)
        let workspace = state.ensureConversationWorkspace(id, location: WorkspaceLocation(path: "/tmp/checkout"))
        let index = state.workspaces.firstIndex { $0.id == workspace }!
        state.workspaces[index].title = "Taskboard filters"
        state.setProviderTitle("Claude Code " + String(sessionA.prefix(8)), conversationID: id)
        XCTAssertEqual(state.workspace(for: id)?.displayTitle, "Taskboard filters")
        state.setProviderTitle("Search and status filters", conversationID: id)
        state.setProviderTitle("Claude Code " + String(sessionA.prefix(8)), conversationID: id)
        XCTAssertEqual(state.workspace(for: id)?.displayTitle, "Search and status filters")
    }

    func testRunningIdentityAbsorbsOnlyEmptyCatalogPlaceholder() throws {
        var state = WorkspaceState()
        let id = ConversationID(provider: .codex, sessionID: sessionA)
        let old = state.ensureConversationWorkspace(id, location: WorkspaceLocation(path: "/tmp/checkout"))
        state.recordCatalogMetadata(ConversationMetadata(id: id, title: "Saved title", directory: "/tmp/checkout", updatedAt: Date()), workspaceID: old, projectID: nil)
        let live = state.newWorkspace(location: WorkspaceLocation(path: "/tmp/checkout"))
        let terminal = state.primaryTerminalID!
        let spec = try LaunchSpec(tool: .codex, executable: "/usr/bin/true", directory: "/tmp/checkout")
        state.apply(.intent(spec, .none), to: terminal)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: .none), to: terminal)
        state.editThread("workspace:" + live.uuidString) { $0.pinnedAt = Date(timeIntervalSince1970: 100) }
        state.associateConversation(id, workspaceID: live)
        XCTAssertEqual(state.workspace(for: id)?.id, live)
        XCTAssertFalse(state.workspace(for: id)?.conversationOwnershipAmbiguous == true)
        XCTAssertFalse(state.workspaces.contains { $0.id == old })
        XCTAssertEqual(state.presentation(for: id.threadKey).pinnedAt, Date(timeIntervalSince1970: 100))
        try state.validate()
    }

    func testRepositoryRefreshRetainsAnchorScopeAndIdentity() throws {
        var state = WorkspaceState()
        let location = WorkspaceLocation(path: "/tmp/repo/child")
        let workspace = state.newWorkspace(location: location)
        state.bindWorkspace(workspace)
        let observed = WorkspaceLocation(path: location.path, scopePath: "/tmp/repo", checkoutIdentity: "/tmp/repo/.git", branch: "main", commonRepository: "/tmp/repo/.git")
        state.refreshRepositoryMetadata(observed, workspaceID: workspace)
        XCTAssertEqual(state.selected?.anchor?.id, location.id)
        XCTAssertEqual(state.selected?.anchor?.scopePath, location.path)
        XCTAssertEqual(state.selected?.anchor?.checkoutIdentity, observed.checkoutIdentity)
        XCTAssertEqual(state.selected?.anchor?.branch, "main")
        let canonical = WorkspaceLocation(path: "/private/tmp/repo/child", checkoutIdentity: "/private/tmp/repo/.git", branch: "updated", commonRepository: "/private/tmp/repo/.git")
        state.refreshRepositoryMetadata(canonical, workspaceID: workspace, scope: location.path)
        XCTAssertEqual(state.selected?.anchor?.path, location.path)
        XCTAssertEqual(state.selected?.anchor?.id, location.id)
        XCTAssertEqual(state.selected?.anchor?.branch, "updated")
        try state.validate()
    }
}
