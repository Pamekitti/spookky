import XCTest
import SpookkyCore
import SpookkyPersistence

final class ProjectDraftIsolationTests: XCTestCase {
    func testAddingAndRemovingAnotherProjectKeepsOriginalDraftAndGlobalDraft() async throws {
        var state = WorkspaceState()
        let global = state.showLanding(homeDirectory: "/tmp/home")
        state.editDraft(state.primaryTerminalID!, tool: .codex, prompt: "Global draft")
        let first = state.registerProject(WorkspaceLocation(path: "/tmp/first"))
        let draft = state.showLanding(projectID: first, homeDirectory: "/tmp/home")
        state.editDraft(state.primaryTerminalID!, tool: .claude, prompt: "Keep 日本語\nproject draft")
        state.setLocation(WorkspaceLocation(path: "/tmp/chosen/child"), projectID: first, workspaceID: draft)
        state.openSupport(.browser(url: "about:blank"), title: "Retained browser")
        let original = try XCTUnwrap(state.selected)

        let added = state.openProject(WorkspaceLocation(path: "/tmp/second"), ifSelected: draft, homeDirectory: "/tmp/home")
        XCTAssertNotEqual(state.selectedWorkspaceID, draft)
        XCTAssertEqual(state.selected?.landingContext, added.uuidString)
        XCTAssertEqual(state.workspaces.first { $0.id == draft }, original)
        state.removeProject(added)
        XCTAssertEqual(state.showLanding(projectID: first, homeDirectory: "/tmp/home"), draft)
        XCTAssertEqual(state.selected?.tabs, original.tabs)
        XCTAssertEqual(state.selected?.selectedLocation, original.selectedLocation)
        XCTAssertEqual(state.selected?.support, original.support)
        XCTAssertEqual(state.selected?.landingContext, first.uuidString)
        XCTAssertEqual(state.showLanding(homeDirectory: "/tmp/home"), global)
        XCTAssertEqual(state.selectedTab?.draft.prompt, "Global draft")
        XCTAssertTrue(state.workspaces.flatMap(\.tabs).allSatisfy { $0.launch == nil && $0.binding == nil })

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite").path
        do { let database = try WorkspaceDatabase(path: path); try await database.save(state) }
        let database = try WorkspaceDatabase(path: path)
        let loaded = try await database.load()
        var restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.showLanding(projectID: first, homeDirectory: "/tmp/home"), draft)
        XCTAssertEqual(restored.selected?.tabs, original.tabs)
        XCTAssertEqual(restored.selected?.selectedLocation, original.selectedLocation)
        try restored.validate()
    }

    func testRegistrationFinishingAfterNavigationDoesNotRetargetEitherDraft() throws {
        var state = WorkspaceState()
        let first = state.showLanding(homeDirectory: "/tmp/home")
        state.editDraft(state.primaryTerminalID!, prompt: "Keep global")
        let other = state.registerProject(WorkspaceLocation(path: "/tmp/other"))
        let selected = state.showLanding(projectID: other, homeDirectory: "/tmp/home")
        state.editDraft(state.primaryTerminalID!, tool: .claude, prompt: "Keep selected")
        let before = state.workspaces
        let added = state.openProject(WorkspaceLocation(path: "/tmp/late"), ifSelected: first, homeDirectory: "/tmp/home")
        XCTAssertTrue(state.projects.contains { $0.id == added })
        XCTAssertEqual(state.selectedWorkspaceID, selected)
        XCTAssertEqual(state.workspaces, before)
        try state.validate()
    }

    func testReopeningRegisteredProjectReusesItsDraftFromAnotherDraftOrBoundWorkspace() throws {
        var state = WorkspaceState()
        let location = WorkspaceLocation(path: "/tmp/project")
        let global = state.showLanding(homeDirectory: "/tmp/home")
        let project = state.openProject(location, ifSelected: global, homeDirectory: "/tmp/home")
        let draft = try XCTUnwrap(state.selectedWorkspaceID)
        state.editDraft(state.primaryTerminalID!, prompt: "Project draft")
        let running = state.newWorkspace(directory: "/tmp/running")
        state.bindWorkspace(running)
        let bound = state.selected
        XCTAssertEqual(state.openProject(location, ifSelected: running, homeDirectory: "/tmp/home"), project)
        XCTAssertEqual(state.selectedWorkspaceID, draft)
        XCTAssertEqual(state.selectedTab?.draft.prompt, "Project draft")
        XCTAssertEqual(state.workspaces.first { $0.id == running }, bound)
        XCTAssertEqual(state.projects.count, 1)
        XCTAssertEqual(state.workspaces.filter { $0.landingContext == project.uuidString }.count, 1)
        try state.validate()
    }

    func testRemovalUsesDraftOwnerAfterAnIntentionalFolderChange() throws {
        var state = WorkspaceState()
        let global = state.showLanding(homeDirectory: "/tmp/home")
        let first = state.registerProject(WorkspaceLocation(path: "/tmp/first"))
        let second = state.registerProject(WorkspaceLocation(path: "/tmp/second"))
        let draft = state.showLanding(projectID: first, homeDirectory: "/tmp/home")
        state.editDraft(state.primaryTerminalID!, prompt: "Keep project draft")
        state.setLocation(WorkspaceLocation(path: "/tmp/second/child"), projectID: second, workspaceID: draft)
        state.removeProject(second)
        XCTAssertEqual(state.selected?.landingContext, first.uuidString)
        XCTAssertEqual(state.selected?.directory, "/tmp/second/child")
        state.setLocation(WorkspaceLocation(path: "/tmp/once"), projectID: nil, workspaceID: draft)
        state.removeProject(first)
        XCTAssertNil(state.selected?.landingContext)
        XCTAssertEqual(state.selectedTab?.draft.prompt, "Keep project draft")
        XCTAssertEqual(state.selected?.directory, "/tmp/once")
        XCTAssertEqual(state.showLanding(homeDirectory: "/tmp/home"), global)
        try state.validate()
    }
}
