import Foundation
import SpookkyCore
import SpookkyGit

public struct ProjectAssociationBatchLimits: Sendable {
    public let maximumProjects: Int
    public let maximumDirectories: Int
    public let maximumRequests: Int
    public let timeout: Duration
    public init(maximumProjects: Int = 256, maximumDirectories: Int = 1024,
                maximumRequests: Int = 4096, timeout: Duration = .seconds(10)) {
        self.maximumProjects = maximumProjects; self.maximumDirectories = maximumDirectories
        self.maximumRequests = maximumRequests; self.timeout = timeout
    }
    func validate() throws {
        guard (1...256).contains(maximumProjects), (1...4096).contains(maximumDirectories),
              (1...16_384).contains(maximumRequests), timeout > .zero, timeout <= .seconds(30) else {
            throw ProjectAssociationBatchError.invalidLimits
        }
    }
}

public enum ProjectAssociationBatchError: Error, LocalizedError, Equatable, Sendable {
    case invalidLimits, tooManyProjects, tooManyDirectories, tooManyRequests, timedOut
    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "Project refresh limits are invalid."
        case .tooManyProjects: "Project refresh exceeded its registered-project limit."
        case .tooManyDirectories: "Project refresh exceeded its unique-directory limit."
        case .tooManyRequests: "Project refresh exceeded its saved-directory request limit."
        case .timedOut: "Project refresh exceeded its time limit."
        }
    }
}

public struct ProjectAssociationBatch: Sendable {
    public let id: UUID
    public let uniqueDirectoryCount: Int
    private let directories: [String: WorkspaceLocation]
    private let requested: Set<String>
    private let projectRoots: [UUID: WorkspaceLocation]
    private let projectsByKey: [ProjectAssociationKey: [UUID]]

    public func resolution(for directory: String, preferredProjectID: UUID? = nil) -> ProjectAssociationResolution {
        guard directory.utf8.count <= 16_384, directory.hasPrefix("/"), !directory.contains("\0") else {
            return ProjectAssociationResolution(location: nil, key: nil, status: .unavailable,
                message: "The saved checkout path is invalid.")
        }
        guard let actual = directories[directory] else {
            return ProjectAssociationResolution(location: nil, key: nil, status: .unavailable,
                message: requested.contains(directory) ? "The saved checkout is unavailable or invalid. Locate it before continuing."
                    : "This directory was not included in the current project refresh.")
        }
        let key = actual.projectAssociationKey
        if let preferredProjectID {
            guard let root = projectRoots[preferredProjectID], root.projectAssociationKey == key else {
                return ProjectAssociationResolution(location: actual, key: key, status: .unavailable,
                    message: "The selected project is missing or no longer matches this checkout. Locate or choose the intended project.")
            }
            return ProjectAssociationResolution(location: actual, key: key, projectID: preferredProjectID,
                                                projectRoot: root.path, status: .matched)
        }
        let matches = projectsByKey[key] ?? []
        guard matches.count == 1, let projectID = matches.first, let root = projectRoots[projectID] else {
            return ProjectAssociationResolution(location: actual, key: key, status: matches.isEmpty ? .unregistered : .ambiguous,
                message: matches.isEmpty ? "No available registered project matches this checkout."
                    : "Multiple registered projects match this repository. Choose the intended project.")
        }
        return ProjectAssociationResolution(location: actual, key: key, projectID: projectID,
                                            projectRoot: root.path, status: .matched)
    }

    static func discover(directories: [String], projects: [Project], git: GitRepository,
                         limits: ProjectAssociationBatchLimits) async throws -> ProjectAssociationBatch {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: limits.timeout)
        func check() throws {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw ProjectAssociationBatchError.timedOut }
        }
        var canonical: [String: String] = [:], paths: [String] = [], uniquePaths = Set<String>(), seen = Set<String>()
        // Normalize each input once, including aliases shared by project roots and saved directories.
        for path in projects.map(\.location.path) + directories {
            try check()
            guard path.utf8.count <= 16_384, seen.insert(path).inserted,
                  path.hasPrefix("/"), !path.contains("\0") else { continue }
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            canonical[path] = resolved
            if uniquePaths.insert(resolved).inserted {
                guard uniquePaths.count <= limits.maximumDirectories else { throw ProjectAssociationBatchError.tooManyDirectories }
                paths.append(resolved)
            }
        }
        var observed: [String: WorkspaceLocation] = [:]
        // Sequential discoveries retain Git's two-command read bound and cache failed paths too.
        for path in paths {
            try check()
            do { observed[path] = try await git.discover(URL(fileURLWithPath: path)) }
            catch is CancellationError { throw CancellationError() }
            catch { }
            try check()
        }
        var projectRoots: [UUID: WorkspaceLocation] = [:], projectsByKey: [ProjectAssociationKey: [UUID]] = [:]
        for project in projects {
            try check()
            guard projectRoots[project.id] == nil, let path = canonical[project.location.path], let location = observed[path] else { continue }
            projectRoots[project.id] = location
            projectsByKey[location.projectAssociationKey, default: []].append(project.id)
        }
        var locations: [String: WorkspaceLocation] = [:], requested = Set<String>()
        for directory in directories {
            try check()
            guard directory.utf8.count <= 16_384 else { continue }
            requested.insert(directory)
            if let path = canonical[directory], let location = observed[path] { locations[directory] = location }
        }
        return ProjectAssociationBatch(id: UUID(), uniqueDirectoryCount: paths.count,
            directories: locations, requested: requested, projectRoots: projectRoots, projectsByKey: projectsByKey)
    }
}
