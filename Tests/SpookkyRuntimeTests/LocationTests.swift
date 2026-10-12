import XCTest
import SpookkyCore
import SpookkyRuntime
import SpookkyWorkspace

final class LocationTests: XCTestCase {
    func testGitAliasesSubdirectoryAndUnbornBranch() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-m1-location-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo café 日本語"), sub = repo.appendingPathComponent("src")
        try PrivateFiles.directory(sub)
        _ = try ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "init", "-b", "dev"])
        let file = repo.appendingPathComponent("data.txt")
        try Data("unchanged fixture".utf8).write(to: file)
        let first = try await LocationDiscovery.discover(repo), second = try await LocationDiscovery.discover(sub)
        XCTAssertEqual(first.checkoutIdentity, second.checkoutIdentity)
        XCTAssertEqual(first.scopePath, second.scopePath)
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertEqual(first.branch, "dev")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repo)
        let third = try await LocationDiscovery.discover(alias)
        XCTAssertEqual(first.checkoutIdentity, third.checkoutIdentity)
        XCTAssertEqual(try Data(contentsOf: file), Data("unchanged fixture".utf8))
        let status = try ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "status", "--porcelain"])
        XCTAssertEqual(status.output, "?? data.txt\n")
    }
    func testPlainFolderAndRemovedLocation() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-m1-location-" + UUID().uuidString.prefix(8))
        try PrivateFiles.directory(root)
        let location = try await LocationDiscovery.discover(root); XCTAssertFalse(location.isGit)
        try FileManager.default.removeItem(at: root)
        do { _ = try await LocationDiscovery.discover(root); XCTFail("Missing folder should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unavailable")) }
    }
    func testRunningWorkspaceCannotBeRelocated() throws {
        var state = WorkspaceState(); let id = state.newWorkspace(directory: "/tmp")
        let tab = try XCTUnwrap(state.selectedTab?.id)
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/zsh", directory: "/tmp")
        state.apply(.preparing, to: tab); state.apply(.intent(spec, .none), to: tab)
        state.bindWorkspace(id)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: tab)
        state.relocateWorkspace(id, location: WorkspaceLocation(path: "/different"))
        XCTAssertEqual(state.selected?.directory, "/tmp")
        state.apply(.terminated, to: tab)
        state.relocateWorkspace(id, location: WorkspaceLocation(path: "/different"))
        XCTAssertEqual(state.selected?.directory, "/different")
    }
}
