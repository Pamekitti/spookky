import XCTest
import Darwin
import SpookkyCore
import SpookkyRuntime
@testable import SpookkyWorkspace



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
