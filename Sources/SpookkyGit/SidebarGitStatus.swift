import Foundation
import SpookkyCore

extension GitRepository {
    public func sidebarCheckout(_ path: String) async throws -> SidebarCheckoutInfo? {
        let location = try await discover(URL(fileURLWithPath: path))
        guard location.isGit else { return nil }
        let head = try await command(location.scopePath, ["rev-parse", "HEAD"]).checked().trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = try await command(location.scopePath, ["remote", "get-url", "origin"])
        let gitDirectory = try await command(location.scopePath, ["rev-parse", "--path-format=absolute", "--git-dir"]).checked().trimmingCharacters(in: .whitespacesAndNewlines)
        let common = try await command(location.scopePath, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).checked().trimmingCharacters(in: .whitespacesAndNewlines)
        let canonical: (String) -> String = { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
        return SidebarCheckoutInfo(repository: remote.status == 0 ? GitHubRepositoryID.parse(remote: remote.output) : nil,
            branch: location.branch == "Detached HEAD" ? nil : location.branch, headCommit: head,
            linkedWorktree: canonical(gitDirectory) != canonical(common))
    }
}

public enum GitHubPullRequestQuery: Hashable, Sendable {
    case branch(GitHubRepositoryID, String), number(GitHubRepositoryID, Int)
    public var arguments: [String] {
        let fields = "number,state,isDraft,headRefName,headRefOid,headRepositoryOwner,headRepository,url"
        switch self {
        case let .branch(repository, branch):
            return ["pr", "list", "--repo", repository.slug, "--head", branch, "--state", "all", "--limit", "50", "--json", fields]
        case let .number(repository, number):
            return ["pr", "view", String(number), "--repo", repository.slug, "--json", fields]
        }
    }
}

public protocol GitHubPullRequestLoading: Sendable {
    func load(_ query: GitHubPullRequestQuery) async throws -> Data
}

public struct GitHubPullRequestCLI: GitHubPullRequestLoading {
    public init() {}
    public func load(_ query: GitHubPullRequestQuery) async throws -> Data {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").prefix(64).map { String($0) + "/gh" }
        guard let executable = (paths + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]).first(where: {
            $0.hasPrefix("/") && !$0.contains("\0") && FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw LaunchError.invalid("GitHub CLI is unavailable.") }
        let result = try await NativeGitExecutor(timeout: 10, outputLimit: 131_072).executeTool(executable, arguments: query.arguments)
        _ = try result.checked(); return result.outputData
    }
}

public struct GitHubPullRequestRecord: Decodable, Sendable {
    public let number: Int
    public let state: String
    public let isDraft: Bool
    public let headRefName: String
    public let headRefOid: String
    public let url: String
    public struct Owner: Decodable, Sendable { public let login: String }
    public struct Repository: Decodable, Sendable { public let name: String }
    public let headRepositoryOwner: Owner?
    public let headRepository: Repository?

    public func status(repository: GitHubRepositoryID) -> PullRequestStatus? {
        let association = ThreadPullRequest(repository: repository, number: number, branch: headRefName, headCommit: headRefOid)
        guard association.isValid, url.lowercased() == association.url.absoluteString.lowercased() else { return nil }
        let value: PullRequestState
        switch state { case "OPEN": value = isDraft ? .draft : .open; case "CLOSED": value = .closed; case "MERGED": value = .merged; default: return nil }
        return PullRequestStatus(association: association, state: value)
    }
    public static func select(_ records: [Self], checkout: SidebarCheckoutInfo) -> PullRequestStatus? {
        guard let repository = checkout.repository, let branch = checkout.branch, let head = checkout.headCommit else { return nil }
        let matching = records.filter {
            $0.headRefName == branch && $0.headRepositoryOwner?.login.lowercased() == repository.owner && $0.headRepository?.name.lowercased() == repository.name
        }
        let open = matching.filter { $0.state == "OPEN" }
        if open.count == 1 { return open[0].status(repository: repository) }
        guard open.isEmpty else { return nil }
        let completed = matching.filter { ["CLOSED", "MERGED"].contains($0.state) && $0.headRefOid == head }
        return completed.count == 1 ? completed[0].status(repository: repository) : nil
    }
}

private actor PullRequestGate {
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 2 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() { if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() } }
}

public actor GitHubPullRequestService {
    private struct Entry { let records: [GitHubPullRequestRecord]?; let date: Date }
    private let loader: any GitHubPullRequestLoading
    private let gate = PullRequestGate()
    private var cache: [GitHubPullRequestQuery: Entry] = [:]
    private var pending: [GitHubPullRequestQuery: Task<[GitHubPullRequestRecord]?, Never>] = [:]
    public init(loader: any GitHubPullRequestLoading = GitHubPullRequestCLI()) { self.loader = loader }
    public var cacheCount: Int { cache.count }
    public var pendingCount: Int { pending.count }
    public func cancelPending() { for task in pending.values { task.cancel() } }
    public func status(checkout: SidebarCheckoutInfo, now: Date = Date()) async -> PullRequestStatus? {
        guard let repository = checkout.repository, repository.isValid, let branch = checkout.branch,
              !branch.isEmpty, branch.utf8.count <= 1024, !branch.contains("\0") else { return nil }
        let records = await records(.branch(repository, branch), now: now)
        return records.flatMap { GitHubPullRequestRecord.select($0, checkout: checkout) }
    }
    public func status(association: ThreadPullRequest, now: Date = Date()) async -> PullRequestStatus? {
        guard association.isValid else { return nil }
        let records = await records(.number(association.repository, association.number), now: now)
        guard let record = records?.first, record.number == association.number, record.headRefName == association.branch else { return nil }
        return record.status(repository: association.repository)
    }
    private func records(_ query: GitHubPullRequestQuery, now: Date) async -> [GitHubPullRequestRecord]? {
        if let entry = cache[query], now.timeIntervalSince(entry.date) < 60 { return entry.records }
        if let task = pending[query] { return await task.value }
        guard pending.count < 128 else { return nil }
        let task = Task { [loader, gate] () -> [GitHubPullRequestRecord]? in
            await gate.acquire()
            let result: [GitHubPullRequestRecord]?
            do {
                try Task.checkCancellation()
                let data = try await loader.load(query)
                guard data.count <= 131_072 else { throw LaunchError.invalid("PR status exceeded its limit.") }
                let decoder = JSONDecoder()
                switch query {
                case .branch: result = try decoder.decode([GitHubPullRequestRecord].self, from: data)
                case .number: result = [try decoder.decode(GitHubPullRequestRecord.self, from: data)]
                }
            } catch { result = nil }
            await gate.release(); return result
        }
        pending[query] = task
        let result = await task.value
        pending[query] = nil
        cache[query] = Entry(records: result, date: now)
        while cache.count > 128, let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key { cache[oldest] = nil }
        return result
    }
}
