import XCTest
import SpookkyCore
import SpookkyRuntime
import SpookkyPersistence
@testable import SpookkyWorkspace

final class InstalledModelSelectionTests: XCTestCase {
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
