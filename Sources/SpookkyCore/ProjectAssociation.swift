import Foundation

public struct ProjectAssociationKey: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case repository, folder }
    public let kind: Kind
    public let path: String
    public init(kind: Kind, path: String) { self.kind = kind; self.path = path }
}

public struct ProjectAssociationResolution: Equatable, Sendable {
    public enum Status: String, Sendable { case matched, unregistered, ambiguous, unavailable }
    public let location: WorkspaceLocation?
    public let key: ProjectAssociationKey?
    public let projectID: UUID?
    public let projectRoot: String?
    public let status: Status
    public let message: String?
    public init(location: WorkspaceLocation?, key: ProjectAssociationKey?, projectID: UUID? = nil,
                projectRoot: String? = nil, status: Status, message: String? = nil) {
        self.location = location; self.key = key; self.projectID = projectID
        self.projectRoot = projectRoot; self.status = status; self.message = message
    }
}

public struct ProviderProjectAssociation: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case associated, unregistered, ambiguous, unavailable, unsupported, failed }
    public let provider: SessionTool
    public let sessionID: String
    public var conversationID: ConversationID { ConversationID(provider: provider, sessionID: sessionID) }
    public let projectID: String?
    public let status: Status
    public let message: String
    public init(provider: SessionTool = .codex, sessionID: String, projectID: String? = nil, status: Status, message: String) {
        self.provider = provider; self.sessionID = sessionID; self.projectID = projectID
        self.status = status; self.message = message
    }
}
