import XCTest
@testable import SpookkyCore

final class SupportingFileContextTests: XCTestCase {
    func testFileTabsKeepIndependentSelectionAndComparisonContexts() throws {
        var state = WorkspaceState(); let workspace = state.newWorkspace(directory: "/tmp")
        let first = state.openSupport(.file(path: "first.swift"), title: "first")!
        var view = state.selected!.support!.selected!.fileView!
        view.query = "first query"; view.scroll = 42
        state.setSupportingFileView(view, workspaceID: workspace)
        let second = state.openSupport(.file(path: "second.swift"), title: "second")!
        XCTAssertNotEqual(first, second)
        state.selectSupport(first)
        XCTAssertEqual(state.selected?.support?.selected?.fileView?.selectedPath, "first.swift")
        XCTAssertEqual(state.selected?.support?.selected?.fileView?.query, "first query")
        XCTAssertEqual(state.selected?.support?.selected?.fileView?.scroll, 42)
        state.selectSupport(second)
        XCTAssertEqual(state.selected?.support?.selected?.fileView?.selectedPath, "second.swift")
        XCTAssertEqual(state.selected?.support?.selected?.fileView?.query, "")
        try state.validate()
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state)), state)
    }
    func testFileReusesPathAndChangesKeepsItsOwnReviewContext() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        var comparison = FileViewState(); comparison.changes = true; comparison.preview = true
        comparison.selectedPath = "sample.swift"; comparison.selectedGroup = "Unstaged"
        let review = state.openSupport(.changes, title: "Changes", fileView: comparison)!
        let source = state.openSupport(.file(path: "sample.swift"), title: "sample", fileView: comparison)!
        XCTAssertNotEqual(review, source)
        XCTAssertEqual(state.selected?.support?.selected?.fileView?.changes, false)
        XCTAssertNil(state.selected?.support?.selected?.fileView?.selectedGroup)
        comparison.againstBranch = true; comparison.reference = "refs/heads/main"; comparison.selectedGroup = "Committed"
        XCTAssertEqual(state.openSupport(.file(path: "sample.swift"), title: "sample", fileView: comparison), source)
        XCTAssertEqual(state.selected?.support?.tabs.count, 2)
        XCTAssertEqual(state.selected?.support?.selected?.fileView?.againstBranch, false)
        state.selectSupport(review)
        XCTAssertEqual(state.selected?.support?.selected?.fileView?.selectedGroup, "Unstaged")
        XCTAssertEqual(state.selected?.support?.selected?.fileView?.againstBranch, false)
        try state.validate()
    }
    func testMigrationAndOldDescriptorsRetainCompatibleFileState() throws {
        var state = WorkspaceState(); state.version = 5
        let id = state.newWorkspace(directory: "/tmp")
        var view = FileViewState(); view.preview = true; view.changes = true
        view.selectedPath = "sample.swift"; view.selectedGroup = "Unstaged"; view.splitDiff = true
        state.setFileView(view, workspaceID: id)
        state.migrateConversationWorkspaces()
        XCTAssertEqual(state.selected?.support?.selected?.fileView, view)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        var workspaces = legacy["workspaces"] as! [[String: Any]]
        var support = workspaces[0]["support"] as! [String: Any]
        var tabs = support["tabs"] as! [[String: Any]]
        tabs[0].removeValue(forKey: "fileView"); support["tabs"] = tabs; workspaces[0]["support"] = support; legacy["workspaces"] = workspaces
        let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.selected?.support?.selected?.fileView)
        XCTAssertEqual(restored.selected?.fileView, view)
        try restored.validate()
    }
}
