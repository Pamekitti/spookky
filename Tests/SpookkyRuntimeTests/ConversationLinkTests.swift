import XCTest
@testable import SpookkyCore

final class ConversationLinkTests: XCTestCase {
    func testFileLinksPreserveScopeAndLiteralNames() throws {
        let root = "/fixture/project"
        let literal = URL(fileURLWithPath: root + "/日本語/literal $(not a command).swift")
        XCTAssertEqual(ConversationLinks.target(for: literal, scopePath: root),
                       .file(path: "日本語/literal $(not a command).swift"))
        XCTAssertNil(ConversationLinks.target(for: URL(fileURLWithPath: "/fixture/project-other/private.swift"), scopePath: root))
        XCTAssertNil(ConversationLinks.target(for: try XCTUnwrap(URL(string: "file:///fixture/project/../outside.swift")), scopePath: root))
        XCTAssertNil(ConversationLinks.target(for: try XCTUnwrap(URL(string: "file://remote/fixture/project/source.swift")), scopePath: root))
        XCTAssertEqual(ConversationLinks.target(for: URL(fileURLWithPath: "/tmp/report.html"), scopePath: root), .artifact(path: "/tmp/report.html"))
        XCTAssertNil(ConversationLinks.target(for: try XCTUnwrap(URL(string: "codex://threads/example")), scopePath: root))
        XCTAssertNil(ConversationLinks.target(for: try XCTUnwrap(URL(string: "https://example.test/?q=" + String(repeating: "x", count: 16_385))), scopePath: root))
    }

    func testLinkTargetsStayWithTheirConversationWithoutChangingSelection() throws {
        var state = WorkspaceState()
        let first = state.newWorkspace(directory: "/fixture/project")
        let firstTerminal = try XCTUnwrap(state.primaryTerminalID)
        state.editDraft(firstTerminal, prompt: "unsent input")
        let second = state.newWorkspace(directory: "/fixture/project")
        let selected = state.selectedWorkspaceID
        let target = try XCTUnwrap(ConversationLinks.target(for: XCTUnwrap(URL(string: "http://localhost:8123/preview")), scopePath: "/fixture/project"))
        state.openSupport(target, title: "Preview", workspaceID: first)
        XCTAssertEqual(state.selectedWorkspaceID, selected)
        XCTAssertEqual(state.workspaces.first { $0.id == first }?.support?.selected?.target, target)
        XCTAssertEqual(state.workspaces.first { $0.id == second }?.support?.tabs.count, 0)
        XCTAssertEqual(state.tab(firstTerminal)?.draft.prompt, "unsent input")
        XCTAssertNil(state.tab(firstTerminal)?.binding)
        try state.validate()
    }
}
