import Foundation
import SpookkyCore

public struct GitCheckout: Sendable, Equatable {
    public let path: String
    public let identity: String
    public let branch: String?
    public let commit: String?
    public let locked: Bool
    public let available: Bool
}
public struct GitReference: Sendable, Equatable {
    public let name: String
    public let remote: String?
    public var qualifiedName: String { (remote == nil ? "refs/heads/" : "refs/remotes/") + name }
}
public struct RepositorySnapshot: Sendable {
    public let generation = UUID()
    public let location: WorkspaceLocation
    public let checkouts: [GitCheckout]
    public let references: [GitReference]
    public let defaultSource: String
    public let head: String?
}

public struct GitRepository: Sendable {
    public let executor: any GitCommandExecutor
    public let scheduler: GitScheduler
    public init(executor: any GitCommandExecutor = NativeGitExecutor(), scheduler: GitScheduler = .shared) {
        self.executor = executor; self.scheduler = scheduler
    }
    public func command(_ path: String, _ arguments: [String]) async throws -> GitResult {
        try await scheduler.read { try await executor.execute(["-C", path] + arguments) }
    }
    public func discover(_ url: URL) async throws -> WorkspaceLocation {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { throw LaunchError.folderUnavailable(path) }
        guard executor.isAvailable else { return WorkspaceLocation(path: path) }
        let root = try await command(path, ["rev-parse", "--show-toplevel"])
        guard !root.truncated else { throw LaunchError.command("Git discovery output exceeded its limit.") }
        guard root.status == 0 else {
            if root.error.contains("not a git repository") { return WorkspaceLocation(path: path) }
            throw LaunchError.command(root.error)
        }
        async let gitDirectoryRead = command(path, ["rev-parse", "--absolute-git-dir"])
        async let commonRead = command(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        async let branchRead = command(path, ["symbolic-ref", "--short", "-q", "HEAD"])
        let (gitDirectory, common, branch) = try await (gitDirectoryRead, commonRead, branchRead)
        func canonical(_ value: String) -> String { URL(fileURLWithPath: value.trimmingCharacters(in: .newlines)).resolvingSymlinksInPath().path }
        return WorkspaceLocation(path: path, scopePath: canonical(try root.checked()), checkoutIdentity: canonical(try gitDirectory.checked()),
                                 branch: branch.status == 0 ? branch.output.trimmingCharacters(in: .newlines) : "Detached HEAD",
                                 commonRepository: canonical(try common.checked()))
    }
    public func resolve(_ path: String, reference: String) async throws -> String {
        guard !reference.hasPrefix("-"), !reference.contains("\0") else { throw LaunchError.invalid("Invalid starting reference.") }
        return try await command(path, ["rev-parse", "--verify", "--end-of-options", reference + "^{commit}"]).checked().trimmingCharacters(in: .newlines)
    }
    public func snapshot(_ location: WorkspaceLocation) async throws -> RepositorySnapshot {
        let current = try await discover(URL(fileURLWithPath: location.path))
        guard current.isGit else { return RepositorySnapshot(location: current, checkouts: [], references: [], defaultSource: "HEAD", head: nil) }
        let headResult = try await command(current.scopePath, ["rev-parse", "--verify", "HEAD"])
        let head = headResult.status == 0 ? headResult.output.trimmingCharacters(in: .newlines) : nil
        let raw = try await command(current.scopePath, ["worktree", "list", "--porcelain", "-z"]).checked()
        var entries: [GitCheckout] = [], path: String?, branch: String?, commit: String?, locked = false
        for token in raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) {
            if token.isEmpty {
                if let path {
                    do {
                        let discovered = try await discover(URL(fileURLWithPath: path))
                        if let identity = discovered.checkoutIdentity { entries.append(GitCheckout(path: discovered.scopePath, identity: identity, branch: branch, commit: commit, locked: locked, available: true)) }
                    } catch LaunchError.folderUnavailable {
                        let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
                        entries.append(GitCheckout(path: canonical, identity: "unavailable:" + canonical, branch: branch, commit: commit, locked: locked, available: false))
                    }
                }
                path = nil; branch = nil; commit = nil; locked = false
            } else if token.hasPrefix("worktree ") { path = String(token.dropFirst(9)) }
            else if token.hasPrefix("branch refs/heads/") { branch = String(token.dropFirst(18)) }
            else if token.hasPrefix("HEAD ") { commit = String(token.dropFirst(5)) }
            else if token.hasPrefix("locked") { locked = true }
        }
        let refs = try await referenceSnapshot(current.scopePath)
        return RepositorySnapshot(location: current, checkouts: entries, references: refs.references, defaultSource: refs.defaultSource, head: head)
    }
    public func referenceSnapshot(_ root: String) async throws -> (references: [GitReference], defaultSource: String) {
        let refs = try await command(root, ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"]).checked()
        let remotes = try await command(root, ["remote"]).checked().split(separator: "\n").map(String.init)
        let matchingRemotes = remotes.sorted { $0.count > $1.count }
        let references = refs.split(separator: "\n").compactMap { line -> GitReference? in
            let ref = String(line)
            if ref.hasPrefix("refs/heads/") { return GitReference(name: String(ref.dropFirst(11)), remote: nil) }
            guard ref.hasPrefix("refs/remotes/"), !ref.hasSuffix("/HEAD") else { return nil }
            let name = String(ref.dropFirst(13))
            let remote = matchingRemotes.first { name.hasPrefix($0 + "/") }
            return GitReference(name: name, remote: remote)
        }
        var defaultSource = "HEAD"
        for remote in remotes.sorted(by: { ($0 == "origin" ? 0 : 1, $0) < ($1 == "origin" ? 0 : 1, $1) }) {
            let symbolic = try await command(root, ["symbolic-ref", "--short", "-q", "refs/remotes/" + remote + "/HEAD"])
            if symbolic.status == 0 { defaultSource = symbolic.output.trimmingCharacters(in: .newlines); break }
        }
        return (references, defaultSource)
    }
    public func validateBranch(_ path: String, name: String) async throws {
        _ = try await command(path, ["check-ref-format", "--branch", name]).checked()
        guard !name.hasPrefix("-") else { throw LaunchError.invalid("Branch name cannot begin with a dash.") }
    }
}
