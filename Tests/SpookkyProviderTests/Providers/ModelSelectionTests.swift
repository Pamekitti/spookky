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
