import Foundation

public struct GitHubRepositoryID: Codable, Hashable, Sendable {
    public let owner: String
    public let name: String
    public init(owner: String, name: String) { self.owner = owner.lowercased(); self.name = name.lowercased() }
    public var slug: String { owner + "/" + name }
    public var isValid: Bool {
        !owner.isEmpty && owner.utf8.count <= 39 && !name.isEmpty && name.utf8.count <= 100 &&
        owner.utf8.allSatisfy { Self.allowed($0, repository: false) } &&
        name.utf8.allSatisfy { Self.allowed($0, repository: true) } && name != "." && name != ".."
    }
    private static func allowed(_ byte: UInt8, repository: Bool) -> Bool {
        (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || repository && [46, 95].contains(byte)
    }
    public static func parse(remote: String) -> Self? {
        let value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if value.hasPrefix("git@github.com:") { path = String(value.dropFirst(15)) }
        else {
            guard let url = URLComponents(string: value), ["https", "ssh"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.lowercased() == "github.com", url.query == nil, url.fragment == nil,
                  url.password == nil, url.port == nil else { return nil }
            path = String(url.path.drop(while: { $0 == "/" }))
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let name = String(parts[1]); let repository = Self(owner: String(parts[0]), name: name.hasSuffix(".git") ? String(name.dropLast(4)) : name)
        return repository.isValid ? repository : nil
    }
}

public enum PullRequestState: String, Codable, Sendable { case draft, open, closed, merged }

public struct ThreadPullRequest: Codable, Equatable, Hashable, Sendable {
    public let repository: GitHubRepositoryID
    public let number: Int
    public let branch: String
    public let headCommit: String
    public init(repository: GitHubRepositoryID, number: Int, branch: String, headCommit: String) {
        self.repository = repository; self.number = number; self.branch = branch; self.headCommit = headCommit
    }
    public var isValid: Bool {
        repository.isValid && number > 0 && number < 1_000_000_000 && !branch.isEmpty && branch.utf8.count <= 1024 && !branch.contains("\0") &&
        headCommit.utf8.count == 40 && headCommit.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public var url: URL { URL(string: "https://github.com/" + repository.slug + "/pull/" + String(number))! }
}

public struct PullRequestStatus: Equatable, Sendable {
    public let association: ThreadPullRequest
    public let state: PullRequestState
    public init(association: ThreadPullRequest, state: PullRequestState) { self.association = association; self.state = state }
    public var label: String {
        let prefix = switch state { case .draft: "Draft PR"; case .open: "Open PR"; case .closed: "Closed PR"; case .merged: "Merged PR" }
        return prefix + " #" + String(association.number)
    }
    public func matchesLiveCheckout(_ checkout: SidebarCheckoutInfo) -> Bool {
        guard association.repository == checkout.repository, association.branch == checkout.branch else { return false }
        switch state {
        case .open, .draft: return true
        case .closed, .merged: return association.headCommit == checkout.headCommit
        }
    }
}

public struct SidebarCheckoutInfo: Hashable, Sendable {
    public let repository: GitHubRepositoryID?
    public let branch: String?
    public let headCommit: String?
    public let linkedWorktree: Bool
    public init(repository: GitHubRepositoryID?, branch: String?, headCommit: String?, linkedWorktree: Bool) {
        self.repository = repository; self.branch = branch; self.headCommit = headCommit; self.linkedWorktree = linkedWorktree
    }
}

public enum SidebarAccessory: Equatable, Sendable {
    case none, activity(AgentActivityState), pullRequest(PullRequestState)
    public init(activity: AgentActivityState?, pullRequest: PullRequestState?) {
        if let activity, [.needsInput, .failed, .working, .finished].contains(activity) { self = .activity(activity) }
        else if let pullRequest { self = .pullRequest(pullRequest) }
        else { self = .none }
    }
}

public struct AgentCompletionReceipt: Equatable, Sendable {
    public let invocationID: UUID
    public let completionID: UUID?
    public let manualUnread: Bool
    public init(_ activity: AgentActivity) {
        invocationID = activity.invocationID; completionID = activity.completionID; manualUnread = activity.manualUnread
    }
}

public enum TerminalViewportPosition {
    public static func atBottom(total: UInt64, offset: UInt64, length: UInt64) -> Bool? {
        guard length > 0, length <= total, offset <= total - length else { return nil }
        return offset == total - length
    }
}

extension AgentActivity {
    @discardableResult public mutating func acknowledge(_ receipt: AgentCompletionReceipt, visible: Bool, viewportAtBottom: Bool?) -> Bool {
        guard visible, viewportAtBottom == true, unread, receipt == AgentCompletionReceipt(self) else { return false }
        acknowledge(); return true
    }
}
