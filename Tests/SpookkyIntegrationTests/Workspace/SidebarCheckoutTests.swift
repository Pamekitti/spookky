import XCTest
import SpookkyCore
import SpookkyGit

final class SidebarCheckoutTests: XCTestCase {
    private let repository = GitHubRepositoryID(owner: "Owner", name: "Example")
    func testLocalCheckoutAndLinkedWorktreeAreVerifiedFromGit() async throws {
        let executor = NativeGitExecutor(timeout: 10)
        guard executor.isAvailable else { throw XCTSkip("Git is unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-sidebar-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRepository(executor: executor)
        _ = try await git.command(root.path, ["init", "--initial-branch=main"]).checked()
        _ = try await git.command(root.path, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "gc.auto=0", "commit", "--allow-empty", "-m", "Fixture"]).checked()
        _ = try await git.command(root.path, ["remote", "add", "origin", "git@github.com:owner/example.git"]).checked()
        let local = try await git.sidebarCheckout(root.path)
        XCTAssertEqual(local?.linkedWorktree, false); XCTAssertEqual(local?.branch, "main")
        XCTAssertEqual(local?.repository, repository)
        let linked = root.appendingPathComponent("linked").path
        _ = try await git.command(root.path, ["worktree", "add", "-b", "codex/sidebar-check", linked]).checked()
        let worktree = try await git.sidebarCheckout(linked)
        XCTAssertEqual(worktree?.linkedWorktree, true); XCTAssertEqual(worktree?.branch, "codex/sidebar-check")
        XCTAssertEqual(worktree?.headCommit, local?.headCommit)
    }

}
