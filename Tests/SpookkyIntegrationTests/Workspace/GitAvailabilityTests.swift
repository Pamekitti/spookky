import XCTest
import Foundation
import SpookkyCore
@testable import SpookkyGit

final class GitAvailabilityTests: XCTestCase {
    func testFreshMacDoesNotChooseApplesInstallStub() {
        XCTAssertNil(NativeGitExecutor.availableGit(developerDirectory: nil, path: "/usr/bin:/bin", isExecutable: { $0 == "/usr/bin/git" || $0 == "/bin/git" }))
    }
    func testPlainFolderDiscoveryDoesNotNeedGit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-no-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try await GitRepository(executor: MissingGit()).discover(root)
        XCTAssertEqual(location.path, root.resolvingSymlinksInPath().path)
        XCTAssertFalse(location.isGit)
    }
    private struct MissingGit: GitCommandExecutor {
        var isAvailable: Bool { false }
        func execute(_ arguments: [String]) async throws -> GitResult {
            XCTFail("Discovery must not launch an unavailable Git executable.")
            return GitResult(status: 1)
        }
    }
    func testInstalledDeveloperGitAndStandaloneGitRemainAvailable() {
        let git = "/Applications/ExampleXcode.app/Contents/Developer/usr/bin/git"
        XCTAssertEqual(NativeGitExecutor.availableGit(developerDirectory: "/Applications/ExampleXcode.app/Contents/Developer", path: "/usr/bin", isExecutable: { $0 == git }), git)
        XCTAssertEqual(NativeGitExecutor.availableGit(developerDirectory: nil, path: "/home/example/bin:/usr/bin", isExecutable: { $0 == "/home/example/bin/git" }), "/home/example/bin/git")
    }
}
