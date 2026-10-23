import XCTest
import Darwin
import SpookkyCore
import SpookkyRuntime
@testable import SpookkyWorkspace

private struct IdentityFixtureResolver: ExecutableResolver {
    let executable: String
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try LaunchSpec(tool: tool, executable: executable, directory: directory,
                       environment: ["PATH": "/usr/bin:/bin"], initialPrompt: prompt)
    }
}

final class InstalledProviderIdentityTests: XCTestCase, @unchecked Sendable {
    func testInstalledCodexIdentityFromDisposableSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let id = environment["SPOOKKY_IDENTITY_TEST_SESSION"],
              let directory = environment["SPOOKKY_IDENTITY_TEST_DIRECTORY"] else {
            throw XCTSkip("Opt in with a disposable saved Codex session")
        }
        let metadata = await ProviderIdentityResolver.codex(candidates: [id], directory: directory)
        XCTAssertEqual(metadata?.id.sessionID, id)
    }

}
