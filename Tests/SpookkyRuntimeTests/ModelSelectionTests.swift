import XCTest
import SpookkyCore
import SpookkyRuntime
import SpookkyPersistence
@testable import SpookkyWorkspace

final class ModelSelectionTests: XCTestCase {
    func testModelEffortMemorySurvivesSwitchesDefaultAndRestart() throws {
        var state = WorkspaceState(); state.showLanding(homeDirectory: "/tmp")
        let id = try XCTUnwrap(state.primaryTerminalID)
        state.editDraft(id, tool: .codex)
        state.editModelSelection(id, selection: AgentModelSelection(model: "a", effort: "high"))
        state.editModelSelection(id, selection: AgentModelSelection(model: "b", effort: "low"))
        state.editDraft(id, tool: .claude)
        state.editModelSelection(id, selection: AgentModelSelection(model: "a", effort: "max"))
        state.editDraft(id, tool: .codex)
        state.editModelSelection(id, selection: AgentModelSelection())
        let restored = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.tab(id)?.draft.modelSelection, AgentModelSelection())
        XCTAssertEqual(restored.rememberedModelSelection(for: .codex, model: "a")?.effort, "high")
        XCTAssertEqual(restored.rememberedModelSelection(for: .codex, model: "b")?.effort, "low")
        XCTAssertEqual(restored.rememberedModelSelection(for: .claude, model: "a")?.effort, "max")
        state.editModelSelection(id, selection: AgentModelSelection(model: "a"))
        XCTAssertNotNil(state.rememberedModelSelection(for: .codex, model: "a"))
        XCTAssertNil(state.rememberedModelSelection(for: .codex, model: "a")?.effort)
        try restored.validate()
    }

    func testModelMemoryIsBoundedAndReadsLegacyProviderChoice() throws {
        var state = WorkspaceState(); state.showLanding(homeDirectory: "/tmp")
        let id = try XCTUnwrap(state.primaryTerminalID); state.editDraft(id, tool: .codex)
        for index in 0..<33 { state.editModelSelection(id, selection: AgentModelSelection(model: "model-\(index)", effort: "high")) }
        XCTAssertNil(state.rememberedModelSelection(for: .codex, model: "model-0"))
        XCTAssertNotNil(state.rememberedModelSelection(for: .codex, model: "model-1"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object.removeValue(forKey: "modelChoiceHistory")
        let legacy = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.rememberedModelSelection(for: .codex, model: "model-32")?.effort, "high")
        try legacy.validate(); try state.validate()
    }
    func testInstalledModelCatalogWithoutStartingConversation() async throws {
        guard ProcessInfo.processInfo.environment["SPOOKKY_TEST_MODEL_CATALOG"] == "1" else {
            throw XCTSkip("Opt-in installed CLI metadata probe")
        }
        let catalog = ProviderModelCatalog()
        for tool in [SessionTool.codex, .claude] {
            let start = ProcessInfo.processInfo.systemUptime
            let result = await catalog.models(for: tool, directory: "/tmp", refresh: true)
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
            XCTAssertNil(result.issue)
            XCTAssertFalse(result.models.isEmpty)
            print("MODEL_CATALOG \(tool.rawValue) count=\(result.models.count) milliseconds=\(Int(milliseconds))")
        }
    }
    func testLegacyDraftDefaultsAndProviderChoicesRoundTrip() throws {
        var draft = try JSONDecoder().decode(TerminalDraft.self, from: Data(#"{"tool":"codex","prompt":"keep"}"#.utf8))
        XCTAssertNil(draft.recordedModelSelection(for: .codex))
        XCTAssertEqual(draft.modelSelection, AgentModelSelection())
        draft.selectModel(AgentModelSelection(model: "codex-model", effort: "high", displayName: "Codex model"), for: .codex)
        draft.selectModel(AgentModelSelection(model: "sonnet"), for: .claude)
        draft.tool = .claude
        let restored = try JSONDecoder().decode(TerminalDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(restored.modelSelection.model, "sonnet")
        XCTAssertEqual(restored.recordedModelSelection(for: .codex)?.effort, "high")
        XCTAssertEqual(restored.recordedModelSelection(for: .codex)?.displayName, "Codex model")
        XCTAssertEqual(restored.prompt, "keep")
    }

    func testContextSeedsProjectLocalButNeverReplacesRetainedDraft() throws {
        var state = WorkspaceState()
        let local = WorkspaceLocation(path: "/tmp/project", checkoutIdentity: "local", branch: "main", commonRepository: "/tmp/project/.git")
        let project = state.registerProject(local)
        let worktree = WorkspaceLocation(path: "/tmp/worktree", checkoutIdentity: "worktree", branch: "feature", commonRepository: local.commonRepository)
        state.newWorkspace(location: worktree, projectID: project)
        let original = try XCTUnwrap(state.primaryTerminalID)
        state.editDraft(original, tool: .claude, prompt: "Existing conversation", images: ["/tmp/old.png"])
        state.editModelSelection(original, selection: AgentModelSelection(model: "sonnet", effort: "high"))
        let source = try XCTUnwrap(state.selected?.primaryTerminal?.draft)
        let landing = state.showLanding(projectID: project, homeDirectory: "/tmp/home", inheriting: source)
        let tab = try XCTUnwrap(state.primaryTerminalID)
        XCTAssertEqual(state.selected?.directory, local.path)
        XCTAssertEqual(state.selected?.projectID, project)
        XCTAssertEqual(state.selected?.primaryTerminal?.draft.tool, .claude)
        XCTAssertEqual(state.selected?.primaryTerminal?.draft.modelSelection, source.modelSelection)
        XCTAssertTrue(state.selected?.primaryTerminal?.draft.isEmpty == true)
        XCTAssertEqual(state.tab(original)?.draft, source)

        state.editDraft(tab, tool: .codex, prompt: "Draft stays", images: ["/tmp/draft.png"])
        state.editModelSelection(tab, selection: AgentModelSelection(model: "chosen", effort: "low"))
        state.setLocation(worktree, projectID: project, workspaceID: landing)
        state.selectWorkspace(state.workspace(containing: original)!.id)
        XCTAssertEqual(state.showLanding(projectID: project, homeDirectory: "/tmp/home", inheriting: source), landing)
        XCTAssertEqual(state.selected?.directory, worktree.path)
        XCTAssertEqual(state.tab(tab)?.draft.prompt, "Draft stays")
        XCTAssertEqual(state.tab(tab)?.draft.images, ["/tmp/draft.png"])
        XCTAssertEqual(state.tab(tab)?.draft.modelSelection.model, "chosen")
    }

    func testUnknownModelUsesLastChoiceAndShellDoesNotBecomeProvider() throws {
        var state = WorkspaceState()
        state.newWorkspace(directory: "/tmp")
        let original = try XCTUnwrap(state.primaryTerminalID)
        state.editDraft(original, tool: .claude)
        state.editModelSelection(original, selection: AgentModelSelection(model: "opus"))
        state.showLanding(homeDirectory: "/tmp/home", inheriting: TerminalDraft(tool: .claude))
        XCTAssertEqual(state.selected?.primaryTerminal?.draft.modelSelection.model, "opus")
        let project = state.registerProject(WorkspaceLocation(path: "/tmp/plain"))
        state.showLanding(projectID: project, homeDirectory: "/tmp/home", inheriting: TerminalDraft(tool: .shell))
        XCTAssertEqual(state.selected?.primaryTerminal?.draft.tool, .claude)
        XCTAssertEqual(state.selected?.primaryTerminal?.draft.modelSelection.model, "opus")
    }

    func testProviderSwitchesKeepPromptImagesAndSeparateSelections() throws {
        var state = WorkspaceState(); state.showLanding(homeDirectory: "/tmp")
        let id = try XCTUnwrap(state.primaryTerminalID)
        state.editDraft(id, tool: .codex, prompt: "Keep this", images: ["/tmp/image.png"])
        state.editModelSelection(id, selection: AgentModelSelection(model: "sol", effort: "high"))
        state.editDraft(id, tool: .claude)
        state.editModelSelection(id, selection: AgentModelSelection(model: "sonnet"))
        state.editDraft(id, tool: .codex)
        XCTAssertEqual(state.tab(id)?.draft.modelSelection, AgentModelSelection(model: "sol", effort: "high"))
        XCTAssertEqual(state.tab(id)?.draft.prompt, "Keep this")
        XCTAssertEqual(state.tab(id)?.draft.images, ["/tmp/image.png"])
        state.editModelSelection(id, selection: AgentModelSelection())
        state.editDraft(id, tool: .claude)
        XCTAssertEqual(state.tab(id)?.draft.modelSelection.model, "sonnet")
        state.editDraft(id, tool: .codex)
        XCTAssertNil(state.tab(id)?.draft.modelSelection.model)
    }

    func testModelOptionsRemainLiteralAndDefaultsDoNotOverrideConfiguration() throws {
        for tool in [SessionTool.codex, .claude] {
            let original = try LaunchSpec(tool: tool, executable: "/bin/cat", arguments: ["--permission-option", "kept"],
                                          directory: "/tmp", environment: ["UNCHANGED": "yes"], initialPrompt: "--this is prompt data")
            XCTAssertEqual(try original.selectingModel(AgentModelSelection()), original)
            let selection = AgentModelSelection(model: "--fake-option $(touch NO)", effort: "high")
            let result = try original.selectingModel(selection)
            XCTAssertEqual(Array(result.arguments.prefix(2)), ["--permission-option", "kept"])
            XCTAssertTrue(result.arguments.contains("--model=--fake-option $(touch NO)"))
            XCTAssertEqual(Array(result.arguments.suffix(2)), ["--", "--this is prompt data"])
            XCTAssertEqual(result.environment, original.environment)
            XCTAssertEqual(result.operationID, original.operationID)
            XCTAssertTrue(result.arguments.contains(tool == .codex ? #"model_reasoning_effort="high""# : "--effort=high"))
            XCTAssertThrowsError(try original.selectingModel(AgentModelSelection(model: "bad\0value")))
        }
        let shell = try LaunchSpec(tool: .shell, executable: "/bin/zsh", arguments: ["-l"], directory: "/tmp")
        XCTAssertEqual(try shell.selectingModel(AgentModelSelection(model: "unused")), shell)
    }

    func testActivityWrapperReceivesModelAndImagesInsideProviderArguments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PrivateFiles.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("image.png"); try Data([1]).write(to: image)
        let resolver = AgentActivityResolver(base: ModelFixtureResolver(), root: root, helper: "/bin/true")
        for tool in [SessionTool.codex, .claude] {
            let result = try await resolver.resolveFresh(tool, directory: root.path, prompt: "Look", images: [image.path], model: AgentModelSelection(model: "model", effort: "high"))
            XCTAssertEqual(Array(result.arguments.prefix(5)), ["--agent-run", tool.rawValue, "--executable", "/bin/false", "--"])
            XCTAssertTrue(Array(result.arguments.dropFirst(5)).contains("--model=model"))
            XCTAssertTrue(result.arguments.last?.contains("Look") == true)
            XCTAssertTrue(result.arguments.joined().contains(image.path))
        }
    }

    func testCodexCatalogUsesOnlyMetadataAndAdvertisedCapabilities() async throws {
        let rpc = ModelFixtureConnection(pages: [#"{"data":[{"model":"sol","displayName":"Sol","supportedReasoningEfforts":[{"reasoningEffort":"high"}],"inputModalities":["text"]},{"model":"hidden","hidden":true}],"nextCursor":"next"}"#,
            #"{"data":[{"model":"legacy","displayName":"Legacy"}],"nextCursor":null}"#])
        let result = try await ProviderModelCatalog.codexModels(connection: rpc)
        XCTAssertEqual(result.models.map(\.id), ["sol", "legacy"])
        XCTAssertEqual(result.models[0].efforts, ["high"])
        XCTAssertFalse(result.models[0].acceptsImages)
        XCTAssertTrue(result.models[1].acceptsImages)
        let methods = await rpc.methods
        XCTAssertEqual(methods, ["model/list", "model/list"])
    }

    func testCatalogRejectsRepeatedCursorsAndReadsClaudeCapabilities() async throws {
        let rpc = ModelFixtureConnection(pages: Array(repeating: #"{"data":[],"nextCursor":"repeat"}"#, count: 4))
        do { _ = try await ProviderModelCatalog.codexModels(connection: rpc); XCTFail("Repeated pagination must stop") } catch {}
        let help = "  --model <model> Model alias (e.g. 'sonnet', 'opus') or full name.\n  --effort <level> Effort (low, medium, high, xhigh, max)\n  --next <value> Another option"
        let claude = ProviderModelCatalog.claudeModels(help: help)
        XCTAssertEqual(claude.models.map(\.id), ["sonnet", "opus"])
        XCTAssertEqual(claude.efforts, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertNotNil(ProviderModelCatalog.claudeModels(help: "Usage: unknown").issue)
    }

    @MainActor func testSelectionsPersistAcrossDatabaseReopenWithoutMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try PrivateFiles.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("metadata.sqlite").path
        var state = WorkspaceState(); state.showLanding(homeDirectory: root.path)
        let id = try XCTUnwrap(state.primaryTerminalID)
        state.editModelSelection(id, selection: AgentModelSelection(model: "chosen", effort: "high"))
        try await WorkspaceDatabase(path: path).save(state)
        let value = try await WorkspaceDatabase(path: path).load()
        XCTAssertEqual(value?.version, 8)
        XCTAssertEqual(value?.tab(id)?.draft.modelSelection, state.tab(id)?.draft.modelSelection)
        XCTAssertEqual(value?.lastModelSelection(for: .codex), state.lastModelSelection(for: .codex))
    }
}

private struct ModelFixtureResolver: ExecutableResolver {
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try LaunchSpec(tool: tool, executable: "/bin/false", directory: directory, initialPrompt: prompt)
    }
}

private actor ModelFixtureConnection: CodexProjectConnection {
    var pages: [String]
    var methods: [String] = []
    init(pages: [String]) { self.pages = pages }
    func request(_ method: String, params: Data) throws -> Data {
        methods.append(method)
        guard !pages.isEmpty else { throw CodexProjectError.invalidResponse }
        return Data(pages.removeFirst().utf8)
    }
}
