import Foundation

public struct ConversationID: Codable, Hashable, Sendable {
    public let provider: SessionTool
    public let sessionID: String
    public init(provider: SessionTool, sessionID: String) { self.provider = provider; self.sessionID = sessionID }
    public func hash(into hasher: inout Hasher) { hasher.combine(provider.rawValue); hasher.combine(sessionID) }
}

public enum ConversationAvailability: String, Codable, Sendable {
    case local, folderUnavailable, historyUnavailable
}

public struct ConversationMetadata: Codable, Equatable, Identifiable, Sendable {
    public let id: ConversationID
    public let title: String?
    public let directory: String
    public let updatedAt: Date
    public let source: String?
    public let providerProjectID: String?
    public let historyPath: String?
    public var availability: ConversationAvailability
    public var displayTitle: String { title ?? id.provider.displayName + " " + String(id.sessionID.prefix(8)) }

    public init(id: ConversationID, title: String?, directory: String, updatedAt: Date,
                source: String? = nil, providerProjectID: String? = nil, historyPath: String? = nil,
                availability: ConversationAvailability = .local) {
        self.id = id; self.title = Self.cleanTitle(title); self.directory = directory; self.updatedAt = updatedAt
        self.source = source; self.providerProjectID = providerProjectID; self.historyPath = historyPath
        self.availability = availability
    }
    private static func cleanTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let value = title.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return value.isEmpty ? nil : String(value.prefix(240))
    }
}

public struct SessionCatalogIssue: Equatable, Sendable {
    public let provider: SessionTool
    public let message: String
    public init(_ provider: SessionTool, _ message: String) { self.provider = provider; self.message = message }
}

public struct SessionCatalogSnapshot: Sendable {
    public let conversations: [ConversationMetadata]
    public let issues: [SessionCatalogIssue]
    public let truncated: Bool
    public let refreshedAt: Date
    public init(conversations: [ConversationMetadata], issues: [SessionCatalogIssue] = [],
                truncated: Bool = false, refreshedAt: Date = Date()) {
        self.conversations = conversations; self.issues = issues; self.truncated = truncated; self.refreshedAt = refreshedAt
    }
}
