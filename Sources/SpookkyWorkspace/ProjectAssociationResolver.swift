import Foundation
import SpookkyCore
import SpookkyGit

public struct ProjectAssociationResolver: Sendable {
    private let git: GitRepository
    public init(git: GitRepository = GitRepository(executor: NativeGitExecutor(timeout: 2, outputLimit: 32_768))) { self.git = git }

    /// A display-only snapshot. Launch and resume actions must use fresh `resolve` calls.
    public func resolveBatch(directories: [String], projects: [Project],
                             limits: ProjectAssociationBatchLimits = ProjectAssociationBatchLimits()) async throws -> ProjectAssociationBatch {
        try limits.validate()
        try Task.checkCancellation()
        guard projects.count <= limits.maximumProjects else { throw ProjectAssociationBatchError.tooManyProjects }
        guard directories.count <= limits.maximumRequests else { throw ProjectAssociationBatchError.tooManyRequests }
        return try await withThrowingTaskGroup(of: ProjectAssociationBatch.self) { group in
            group.addTask { try await ProjectAssociationBatch.discover(directories: directories, projects: projects, git: git, limits: limits) }
            group.addTask {
                try await Task.sleep(for: limits.timeout)
                throw ProjectAssociationBatchError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        }
    }

    public func resolve(directory: String, projects: [Project], preferredProjectID: UUID? = nil) async -> ProjectAssociationResolution {
        let actual: WorkspaceLocation
        do { actual = try await git.discover(URL(fileURLWithPath: directory)) }
        catch { return ProjectAssociationResolution(location: nil, key: nil, status: .unavailable,
                                                     message: "The selected checkout is unavailable. Locate it before continuing.") }
        if let preferredProjectID {
            guard let project = projects.first(where: { $0.id == preferredProjectID }),
                  let current = try? await git.discover(URL(fileURLWithPath: project.location.path)),
                  current.projectAssociationKey == actual.projectAssociationKey else {
                return ProjectAssociationResolution(location: actual, key: actual.projectAssociationKey, status: .unavailable,
                    message: "The selected project is missing or no longer matches this checkout. Locate or choose the intended project.")
            }
            return resolved(actual, project: project, root: current.path)
        }
        guard projects.count <= 256 else {
            return ProjectAssociationResolution(location: actual, key: actual.projectAssociationKey, status: .unavailable,
                message: "Project discovery exceeds the 256-project limit. Choose the intended project.")
        }
        let deadline = Date().addingTimeInterval(10)
        var matches: [(Project, WorkspaceLocation)] = []
        // Registered projects are metadata, not a recursive filesystem scan. Reads share Git's bounded scheduler.
        for project in projects {
            guard Date() < deadline else {
                return ProjectAssociationResolution(location: actual, key: actual.projectAssociationKey, status: .unavailable,
                    message: "Project discovery exceeded its time limit. Choose the intended project.")
            }
            guard let current = try? await git.discover(URL(fileURLWithPath: project.location.path)),
                  current.projectAssociationKey == actual.projectAssociationKey else { continue }
            matches.append((project, current))
        }
        guard matches.count == 1, let match = matches.first else {
            return ProjectAssociationResolution(location: actual, key: actual.projectAssociationKey,
                status: matches.isEmpty ? .unregistered : .ambiguous,
                message: matches.isEmpty ? "No available registered project matches this checkout." : "Multiple registered projects match this repository. Choose the intended project.")
        }
        return resolved(actual, project: match.0, root: match.1.path)
    }

    private func resolved(_ location: WorkspaceLocation, project: Project, root: String) -> ProjectAssociationResolution {
        ProjectAssociationResolution(location: location, key: location.projectAssociationKey,
                                     projectID: project.id, projectRoot: root, status: .matched)
    }
}
