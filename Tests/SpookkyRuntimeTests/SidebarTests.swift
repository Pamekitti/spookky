import XCTest
import SpookkyCore
import SpookkyPersistence

final class SidebarTests: XCTestCase {
    func testCollapsePreservesDraftAndSelectionAndSelectionExpands() throws {
        var state = WorkspaceState()
        let location = WorkspaceLocation(path: "/tmp/sidebar")
        let project = state.registerProject(location)
        let workspace = state.newWorkspace(location: location, projectID: project)
        state.editDraft(state.selectedTab!.id, tool: .codex, prompt: "Keep this unsent draft")
        let before = state.selected
        state.toggleProjectCollapsed(project)
        XCTAssertEqual(state.selected, before)
        XCTAssertEqual(state.projects.first?.isCollapsed, true)
        state.selectWorkspace(workspace)
        XCTAssertEqual(state.projects.first?.isCollapsed, false)
        state.toggleProjectCollapsed(project)
        state.newWorkspace(location: location, projectID: project)
        XCTAssertEqual(state.projects.first?.isCollapsed, false)
        XCTAssertEqual(state.workspaces.first, before)
        try state.validate()
    }
    func testCollapseRoundTripAndOldSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = WorkspaceState()
        let id = state.registerProject(WorkspaceLocation(path: "/tmp/sidebar"))
        state.newWorkspace(directory: "/tmp")
        state.setProjectCollapsed(id, true)
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        try await database.save(state)
        let restored = try await database.load()
        XCTAssertEqual(restored?.projects.first?.isCollapsed, true)
        XCTAssertEqual(restored?.version, 3)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        var projects = json["projects"] as! [[String: Any]]
        projects[0].removeValue(forKey: "isCollapsed"); json["projects"] = projects
        let old = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.projects.first?.isCollapsed)
        try old.validate()
    }
}
