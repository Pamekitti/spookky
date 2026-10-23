import XCTest
import SpookkyCore
@testable import SpookkyWorkspace

final class PromptImageTests: XCTestCase {
    func testImagesStayInsideProviderArgumentsWhenActivityWrapperIsAdded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PrivateFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("image.png")
        try Data([1]).write(to: image)
        let base = ImageFixtureResolver()
        let resolver = AgentActivityResolver(base: base, root: root, helper: "/bin/true")
        let spec = try await resolver.resolveFresh(.claude, directory: root.path, prompt: "Look", images: [image.path])
        XCTAssertEqual(Array(spec.arguments.prefix(5)), ["--agent-run", "claude", "--executable", "/bin/false", "--"])
        XCTAssertEqual(Array(spec.arguments.suffix(2)), ["--", "Look\n\nAttached images:\n" + image.path])
    }
    func testOldDraftDecodesAndImagesRoundTrip() throws {
        let draft = try JSONDecoder().decode(TerminalDraft.self, from: Data(#"{"tool":"codex","prompt":"draft"}"#.utf8))
        XCTAssertEqual(draft.images, [])
        var attached = TerminalDraft(tool: .codex, images: ["/tmp/image.png"])
        XCTAssertFalse(attached.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(TerminalDraft.self, from: JSONEncoder().encode(attached)), attached)
        attached.images = []
        XCTAssertTrue(attached.isEmpty)
    }

    func testLiteralImagePathsReachBothProviderLaunchArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PrivateFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("café's $(touch SHOULD_NOT_EXIST).png")
        try Data([1]).write(to: image)
        let prompt = "Explain this\n--literal"
        for tool in [SessionTool.codex, .claude] {
            let original = try LaunchSpec(tool: tool, executable: "/bin/cat", arguments: ["--existing-option"],
                directory: root.path, environment: ["FIXTURE": "kept"], initialPrompt: prompt)
            let spec = try await original.attachingPromptImages([image.path])
            XCTAssertEqual(spec.operationID, original.operationID)
            XCTAssertEqual(spec.environment, original.environment)
            let expected = tool == .codex ? ["--existing-option", "--image", image.path, "--", prompt] :
                ["--existing-option", "--", prompt + "\n\nAttached images:\n" + image.path]
            XCTAssertEqual(spec.arguments, expected)
            let empty = try LaunchSpec(tool: tool, executable: "/bin/cat", directory: root.path)
            let imageOnly = try await empty.attachingPromptImages([image.path])
            XCTAssertEqual(imageOnly.arguments, tool == .codex ? ["--image", image.path] : ["--", "Attached images:\n" + image.path])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
        let shell = try LaunchSpec(tool: .shell, executable: "/bin/zsh", arguments: ["-l"], directory: root.path)
        let unchanged = try await shell.attachingPromptImages([image.path])
        XCTAssertEqual(unchanged, shell)
    }

    func testMissingImageFailsBeforeLaunch() async throws {
        let spec = try LaunchSpec(tool: .codex, executable: "/bin/cat", directory: "/tmp")
        do {
            _ = try await spec.attachingPromptImages(["/tmp/missing-" + UUID().uuidString + ".png"])
            XCTFail("Missing image must retain the draft for correction")
        } catch { XCTAssertTrue(error.localizedDescription.contains("missing")) }
    }

    func testImageDraftSurvivesProviderChangesAndHistoryAssociation() throws {
        var state = WorkspaceState()
        state.newWorkspace(directory: "/tmp")
        let id = try XCTUnwrap(state.selectedTab?.id)
        state.editDraft(id, tool: .codex, images: ["/tmp/image.png"])
        state.editDraft(id, tool: .claude, prompt: "explain")
        XCTAssertEqual(state.tab(id)?.draft.images, ["/tmp/image.png"])
        state.editDraft(id, prompt: "")
        let saved = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(try XCTUnwrap(saved.tab(id)).draft.isEmpty)
        XCTAssertEqual(saved.tab(id)?.draft.images, ["/tmp/image.png"])
    }
}

private struct ImageFixtureResolver: ExecutableResolver {
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try LaunchSpec(tool: tool, executable: "/bin/false", directory: directory, initialPrompt: prompt)
    }
}
