import XCTest
import SpookkyCore
import SpookkyGit

private actor PullRequestFixture: GitHubPullRequestLoading {
    var calls = 0, active = 0, maximumActive = 0
    let data: Data
    init(data: Data = Data("[]".utf8)) { self.data = data }
    func load(_ query: GitHubPullRequestQuery) async throws -> Data {
        calls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(5))
        return data
    }
}

final class SidebarStatusTests: XCTestCase {
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
    func testRepositoryIdentityRejectsUnrelatedHostsAndPreservesLiteralBranchArgument() {
        for remote in ["git@github.com:Owner/Example.git", "https://github.com/Owner/Example", "ssh://git@github.com/Owner/Example.git"] {
            XCTAssertEqual(GitHubRepositoryID.parse(remote: remote), repository)
        }
        for remote in ["https://github.com.evil.test/owner/example", "https://other.test/owner/example", "https://github.com/owner/example?x=1", "git@github.com:owner/../example"] {
            XCTAssertNil(GitHubRepositoryID.parse(remote: remote))
        }
        let branch = "odd ' $(touch /tmp/never)"
        let args = GitHubPullRequestQuery.branch(repository, branch).arguments
        XCTAssertEqual(args[args.firstIndex(of: "--head")! + 1], branch)
        XCTAssertFalse(args.contains("auth")); XCTAssertFalse(args.contains("merge"))
    }
    func testUniqueOpenPRWinsAndForkCollisionsAreRejected() throws {
        let old = try record(number: 11, state: "MERGED")
        let open = try record()
        XCTAssertEqual(GitHubPullRequestRecord.select([old, open], checkout: checkout)?.association.number, 12)
        XCTAssertNil(GitHubPullRequestRecord.select([open, try record(number: 13)], checkout: checkout))
        XCTAssertNil(GitHubPullRequestRecord.select([try record(owner: "another-owner")], checkout: checkout))
        XCTAssertNil(GitHubPullRequestRecord.select([try record(url: "https://evil.test/pull/12")], checkout: checkout))
        XCTAssertEqual(GitHubPullRequestRecord.select([try record(draft: true)], checkout: checkout)?.state, .draft)
    }
    func testReusedBranchDoesNotInheritEarlierMergedPR() throws {
        let merged = try record(state: "MERGED")
        XCTAssertEqual(GitHubPullRequestRecord.select([merged], checkout: checkout)?.state, .merged)
        let reused = SidebarCheckoutInfo(repository: repository, branch: checkout.branch, headCommit: String(repeating: "b", count: 40), linkedWorktree: true)
        XCTAssertNil(GitHubPullRequestRecord.select([merged], checkout: reused))
        let detached = SidebarCheckoutInfo(repository: repository, branch: nil, headCommit: head, linkedWorktree: true)
        XCTAssertNil(GitHubPullRequestRecord.select([merged], checkout: detached))
    }
    func testActivityKeepsPriorityOverPRAndUnknownDoesNotInventWork() {
        for state in [AgentActivityState.needsInput, .failed, .working, .finished] {
            XCTAssertEqual(SidebarAccessory(activity: state, pullRequest: .merged), .activity(state))
        }
        XCTAssertEqual(SidebarAccessory(activity: .unknown, pullRequest: .merged), .pullRequest(.merged))
        XCTAssertEqual(SidebarAccessory(activity: .idle, pullRequest: nil), .none)
    }
    func testVerifiedAssociationRoundTripsWithoutRequiringItInOlderMetadata() throws {
        var entry = try JSONDecoder().decode(ThreadPresentation.self, from: Data(#"{"hasProjectOverride":false}"#.utf8))
        XCTAssertNil(entry.pullRequest)
        entry.pullRequest = ThreadPullRequest(repository: repository, number: 12, branch: "codex/sidebar", headCommit: head)
        entry.pinnedAt = Date(timeIntervalSince1970: 10); entry.archivedAt = Date(timeIntervalSince1970: 20)
        XCTAssertEqual(try JSONDecoder().decode(ThreadPresentation.self, from: JSONEncoder().encode(entry)), entry)
        XCTAssertTrue(entry.pullRequest?.isValid == true)
    }
    func testUnreadRequiresVisibilityAndKnownBottomAndRejectsNewerCompletion() {
        let binding = UUID(), invocation = UUID(), secret = UUID()
        func event(_ kind: AgentEventKind) -> AgentEvent { AgentEvent(bindingID: binding, invocationID: invocation, secret: secret, provider: .codex, kind: kind) }
        var activity = AgentActivity(invocationID: invocation, provider: .codex)
        activity.apply(event(.working)); activity.apply(event(.finished))
        let receipt = AgentCompletionReceipt(activity)
        XCTAssertFalse(activity.acknowledge(receipt, visible: false, viewportAtBottom: true))
        XCTAssertFalse(activity.acknowledge(receipt, visible: true, viewportAtBottom: false))
        XCTAssertFalse(activity.acknowledge(receipt, visible: true, viewportAtBottom: nil))
        activity.apply(event(.working)); activity.apply(event(.finished))
        XCTAssertFalse(activity.acknowledge(receipt, visible: true, viewportAtBottom: true))
        XCTAssertTrue(activity.unread)
        activity.restore()
        XCTAssertTrue(activity.unread); XCTAssertEqual(activity.displayState, .unknown)
        let current = AgentCompletionReceipt(activity)
        XCTAssertTrue(activity.acknowledge(current, visible: true, viewportAtBottom: true))
        activity.apply(event(.needsInput)); activity.manualUnread = true
        XCTAssertTrue(activity.acknowledge(AgentCompletionReceipt(activity), visible: true, viewportAtBottom: true))
        XCTAssertEqual(activity.displayState, .needsInput)
        activity.apply(event(.failed)); activity.acknowledge()
        XCTAssertEqual(activity.displayState, .failed)
    }
    func testLookupDeduplicatesRequestsAndExpiresAfterOneMinute() async {
        let loader = PullRequestFixture(), service = GitHubPullRequestService(loader: loader)
        let checkout = checkout
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { _ = await service.status(checkout: checkout, now: Date(timeIntervalSince1970: 1000)) } }
        }
        let firstCalls = await loader.calls
        XCTAssertEqual(firstCalls, 1)
        _ = await service.status(checkout: checkout, now: Date(timeIntervalSince1970: 1059))
        let freshCalls = await loader.calls
        XCTAssertEqual(freshCalls, 1)
        _ = await service.status(checkout: checkout, now: Date(timeIntervalSince1970: 1061))
        let expiredCalls = await loader.calls
        XCTAssertEqual(expiredCalls, 2)
    }
    func testLookupBoundsConcurrencyAndCache() async {
        let loader = PullRequestFixture(), service = GitHubPullRequestService(loader: loader)
        let repository = repository, head = head
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<140 {
                group.addTask {
                    _ = await service.status(checkout: SidebarCheckoutInfo(repository: repository, branch: "branch-\(index)", headCommit: head, linkedWorktree: false))
                }
            }
        }
        let maximum = await loader.maximumActive, cached = await service.cacheCount, pending = await service.pendingCount
        XCTAssertEqual(maximum, 2); XCTAssertLessThanOrEqual(cached, 128); XCTAssertEqual(pending, 0)
    }
}
