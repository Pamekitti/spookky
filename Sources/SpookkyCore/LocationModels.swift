import Foundation

public enum ProjectCreationMode: String, Codable, Sendable { case create, clone }
public struct ProjectCreationDraft: Codable, Equatable, Sendable {
    public var mode: ProjectCreationMode = .create
    public var name = ""
    public var parentPath: String
    public var repositoryURL = ""
    public var initializeGit = false
    public init(parentPath: String = FileManager.default.homeDirectoryForCurrentUser.path) { self.parentPath = parentPath }
}
public enum LocationMode: String, Codable, Sendable { case local, worktree }
public enum BranchMode: String, Codable, Sendable { case automatic, custom, existing }
public struct LocationDraft: Codable, Equatable, Sendable {
    public var mode: LocationMode = .local
    public var source = "HEAD"
    public var branchMode: BranchMode = .automatic
    public var branch = ""
    public var destination = ""
    public var useCachedSource = false
    public var cachedCommit: String?
    public init() {}
}
public struct CheckoutRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var location: WorkspaceLocation
    public var createdBy: UUID?
    public var creationCommit: String?
    public init(location: WorkspaceLocation, createdBy: UUID? = nil, creationCommit: String? = nil) {
        id = location.id; self.location = location; self.createdBy = createdBy; self.creationCommit = creationCommit
    }
}
public enum LocationOperationKind: String, Codable, Sendable { case create, clone, worktree, deleteWorktree }
public enum LocationOperationPhase: String, Codable, Sendable { case intent, reserved, fetched, cachedSource, resolved, filesystemComplete, reconciled, registered, removed }
public enum LocationOperationStatus: String, Codable, Sendable { case running, failed, cancelled, uncertain, complete }
public struct LocationReceipt: Codable, Equatable, Sendable {
    public let phase: LocationOperationPhase
    public let commit: String?
    public let location: WorkspaceLocation?
    public let directoryIdentity: String?
    public let date: Date
    public init(_ phase: LocationOperationPhase, commit: String? = nil, location: WorkspaceLocation? = nil, directoryIdentity: String? = nil) {
        self.directoryIdentity = directoryIdentity
        self.phase = phase; self.commit = commit; self.location = location; date = Date()
    }
}
public struct LocationRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: LocationOperationKind
    public let projectID: UUID?
    public let workspaceID: UUID?
    public let sourcePath: String?
    public let commonRepository: String?
    public let destination: String
    public let repositoryURL: String?
    public let initializeGit: Bool
    public let source: String?
    public let remote: String?
    public let branch: String?
    public let existingBranch: Bool
    public let useCachedSource: Bool
    public let cachedCommit: String?
    public init(id: UUID = UUID(), kind: LocationOperationKind, destination: String, projectID: UUID? = nil,
                workspaceID: UUID? = nil, sourcePath: String? = nil, commonRepository: String? = nil,
                repositoryURL: String? = nil, initializeGit: Bool = false, source: String? = nil, remote: String? = nil,
                branch: String? = nil, existingBranch: Bool = false, useCachedSource: Bool = false, cachedCommit: String? = nil) {
        self.id = id; self.kind = kind; self.destination = destination; self.projectID = projectID; self.workspaceID = workspaceID
        self.sourcePath = sourcePath; self.commonRepository = commonRepository; self.repositoryURL = repositoryURL
        self.initializeGit = initializeGit; self.source = source; self.remote = remote; self.branch = branch
        self.existingBranch = existingBranch; self.useCachedSource = useCachedSource; self.cachedCommit = cachedCommit
    }
    public func validate() throws {
        let values = [destination, sourcePath, commonRepository, repositoryURL, source, remote, branch, cachedCommit].compactMap { $0 }
        guard destination.hasPrefix("/"), destination != "/", !values.contains(where: { $0.contains("\0") }) else { throw LaunchError.invalid("Location request contains an invalid path or null byte.") }
        if kind == .clone {
            guard let repositoryURL, !repositoryURL.isEmpty, !repositoryURL.hasPrefix("-") else { throw LaunchError.invalid("Clone request requires a repository URL.") }
        }
        if kind == .worktree || kind == .deleteWorktree {
            guard sourcePath?.hasPrefix("/") == true, commonRepository?.hasPrefix("/") == true, branch?.isEmpty == false else { throw LaunchError.invalid("Worktree request requires a repository and branch.") }
        }
        if kind == .worktree {
            guard source?.isEmpty == false else { throw LaunchError.invalid("Worktree request requires a starting reference.") }
            if useCachedSource && remote != nil && cachedCommit == nil { throw LaunchError.invalid("Cached source requires an explicit commit.") }
        }
    }

}
public struct LocationOperation: Codable, Equatable, Identifiable, Sendable {
    public let request: LocationRequest
    public var id: UUID { request.id }
    public var status: LocationOperationStatus = .running
    public var receipts: [LocationReceipt] = []
    public var error: String?
    public init(_ request: LocationRequest) { self.request = request }
    public var location: WorkspaceLocation? { receipts.last(where: { $0.location != nil })?.location }
    public var commit: String? { receipts.last(where: { $0.commit != nil && $0.phase != .cachedSource })?.commit }
    public var cachedCommit: String? { receipts.last(where: { $0.phase == .cachedSource })?.commit }
}
public struct LocationMetadata: Codable, Equatable, Sendable {
    public var checkouts: [CheckoutRecord] = []
    public var operations: [LocationOperation] = []
    public init() {}
}
