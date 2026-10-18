import Foundation
import SpookkyCore

public struct HistoryQuery: Hashable, Sendable {
    public let projectID: UUID?
    public let directories: [String]
    public let search: String
    public let limit: Int
    public let cursor: String?
    public let exactDirectories: Bool
    public let titleSearchOnly: Bool

    public init(projectID: UUID? = nil, directories: [String] = [], search: String = "",
                limit: Int = 5, cursor: String? = nil, exactDirectories: Bool = false, titleSearchOnly: Bool = false) {
        self.projectID = projectID
        self.directories = Array(Set(directories.filter { $0.hasPrefix("/") && !$0.contains("\0") }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
        self.search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        self.limit = min(100, max(1, limit)); self.cursor = cursor
        self.exactDirectories = exactDirectories
        self.titleSearchOnly = titleSearchOnly
    }

    func matches(_ item: ConversationMetadata) -> Bool {
        let path = URL(fileURLWithPath: item.directory).standardizedFileURL.path
        let inDirectory = directories.isEmpty || directories.contains {
            path == $0 || (!exactDirectories && path.hasPrefix($0 == "/" ? "/" : $0 + "/"))
        }
        return inDirectory && (search.isEmpty || item.displayTitle.localizedCaseInsensitiveContains(search) ||
            (!titleSearchOnly && (item.id.sessionID.localizedCaseInsensitiveContains(search) || item.directory.localizedCaseInsensitiveContains(search))))
    }

    var identity: String {
        ([projectID?.uuidString ?? "", exactDirectories ? "exact" : "recursive", titleSearchOnly ? "title" : "metadata", search] + directories)
            .joined(separator: "\0")
    }
}

public struct HistoryPage: Sendable {
    public let conversations: [ConversationMetadata]
    public let nextCursor: String?
    public let issues: [SessionCatalogIssue]
    public let truncated: Bool
    public let refreshedAt: Date

    public init(conversations: [ConversationMetadata], nextCursor: String? = nil,
                issues: [SessionCatalogIssue] = [], truncated: Bool = false, refreshedAt: Date = Date()) {
        self.conversations = conversations; self.nextCursor = nextCursor
        self.issues = issues; self.truncated = truncated; self.refreshedAt = refreshedAt
    }
}

struct HistoryPosition: Codable {
    let updatedAt: Date
    let provider: String
    let sessionID: String

    init(_ item: ConversationMetadata) {
        updatedAt = item.updatedAt; provider = item.id.provider.rawValue; sessionID = item.id.sessionID
    }
    func containsOlder(_ item: ConversationMetadata) -> Bool {
        if item.updatedAt != updatedAt { return item.updatedAt < updatedAt }
        return (item.id.provider.rawValue, item.id.sessionID) > (provider, sessionID)
    }
}

func historyNewestFirst(_ lhs: ConversationMetadata, _ rhs: ConversationMetadata) -> Bool {
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    return (lhs.id.provider.rawValue, lhs.id.sessionID) < (rhs.id.provider.rawValue, rhs.id.sessionID)
}
