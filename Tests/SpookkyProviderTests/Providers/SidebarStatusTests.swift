import XCTest
import SpookkyCore
import SpookkyGit

private actor PullRequestFixture: GitHubPullRequestLoading {
    var calls = 0, active = 0, maximumActive = 0
    let data: Data
    let delay: Int
    init(data: Data = Data("[]".utf8), delay: Int = 5) { self.data = data; self.delay = delay }
    func load(_ query: GitHubPullRequestQuery) async throws -> Data {
        calls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(delay))
        return data
    }
}

final class InstalledSidebarStatusTests: XCTestCase {
    private let repository = GitHubRepositoryID(owner: "Owner", name: "Example")
    private let head = String(repeating: "a", count: 40)
    private func record(number: Int = 12, state: String = "OPEN", draft: Bool = false, head: String? = nil,
                        owner: String = "owner", branch: String = "codex/sidebar", url: String? = nil) throws -> GitHubPullRequestRecord {
        let raw: [String: Any] = ["number": number, "state": state, "isDraft": draft, "headRefName": branch,
            "headRefOid": head ?? self.head, "headRepositoryOwner": ["login": owner], "headRepository": ["name": "example"],
            "url": url ?? "https://github.com/owner/example/pull/\(number)"]
        return try JSONDecoder().decode(GitHubPullRequestRecord.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    private var checkout: SidebarCheckoutInfo {
        SidebarCheckoutInfo(repository: repository, branch: "codex/sidebar", headCommit: head, linkedWorktree: true)
    }
    func testInstalledGitHubCLIReportsVerifiedMergedPR() async throws {
        guard ProcessInfo.processInfo.environment["SPOOKKY_REAL_PR_CHECK"] == "1" else { throw XCTSkip("Opt-in read-only GitHub CLI check") }
        let association = ThreadPullRequest(repository: GitHubRepositoryID(owner: "Pamekitti", name: "spookky"), number: 16,
            branch: "codex/agent-activity", headCommit: "5d980b005e44908223abd745e046205ec75a5720")
        let status = await GitHubPullRequestService().status(association: association)
        XCTAssertEqual(status?.state, .merged); XCTAssertEqual(status?.association.number, 16)
    }
}
