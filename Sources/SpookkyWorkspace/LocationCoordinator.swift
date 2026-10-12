import Darwin
import Foundation
import SpookkyCore
import SpookkyGit

@MainActor public final class LocationCoordinator {
    private let store: WorkspaceStore
    public let git: GitRepository
    private let operationRoot: URL
    private let runtime: (any SessionRuntime)?
    private var workspacePreparations: [UUID: Task<WorkspaceLocation, Error>] = [:]
    private var tasks: [UUID: Task<WorkspaceLocation?, Error>] = [:]
    private var active = Set<UUID>()
    private var cancelled = Set<UUID>()
    private var preparing = Set<UUID>()
    public init(store: WorkspaceStore, git: GitRepository = GitRepository(), runtime: (any SessionRuntime)? = nil, operationRoot: URL = URL(fileURLWithPath: "/tmp/spookky-git-development-\(getuid())")) { self.store = store; self.git = git; self.runtime = runtime; self.operationRoot = operationRoot }
    public func isBusy(workspaceID: UUID) -> Bool { preparing.contains(workspaceID) || workspacePreparations[workspaceID] != nil }
    public var activeOperationIDs: [UUID] { Array(active.union(store.state.locations?.operations.filter { $0.status == .running }.map(\.id) ?? [])) }
    public func cancel(_ id: UUID) {
        if active.contains(id) { cancelled.insert(id); tasks[id]?.cancel() }
        else if operation(id) != nil {
            Task {
                do {
                    let root = operationRoot
                    try await Task.detached { try GitExecutionJournal.cancel(root: root, operationID: id) }.value
                    if var op = operation(id) { op.status = .cancelled; op.error = "Owned Git command cancelled. Reconcile before retrying."; store.update { $0.recordOperation(op) }; try await store.flush() }
                    _ = try await reconcile(id)
                } catch { if var op = operation(id) { op.status = .uncertain; op.error = error.localizedDescription; store.update { $0.recordOperation(op) } } }
            }
        }
    }
    public func operation(_ id: UUID) -> LocationOperation? { store.state.locations?.operations.first { $0.id == id } }

    nonisolated public static func projectRequest(_ draft: ProjectCreationDraft) throws -> LocationRequest {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
              draft.parentPath.hasPrefix("/"), !draft.parentPath.contains("\0") else { throw LaunchError.invalid("Choose a folder name and an absolute destination.") }
        let parent = URL(fileURLWithPath: draft.parentPath).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else { throw LaunchError.folderUnavailable(parent.path) }
        let url = draft.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.mode == .clone {
            guard !url.isEmpty, !url.hasPrefix("-"), !url.contains("\0"), !url.contains("\n") else { throw LaunchError.invalid("Enter a repository URL or SSH address.") }
            if let parsed = URL(string: url), parsed.password != nil { throw LaunchError.invalid("Use your Git credential helper instead of a password in the URL.") }
        }
        return LocationRequest(kind: draft.mode == .clone ? .clone : .create,
                               destination: parent.appendingPathComponent(name).path,
                               repositoryURL: draft.mode == .clone ? url : nil, initializeGit: draft.initializeGit)
    }
    @discardableResult public func start(_ request: LocationRequest) async throws -> WorkspaceLocation? {
        try request.validate()
        if let common = request.commonRepository, store.state.locations?.operations.contains(where: { $0.id != request.id && $0.request.commonRepository == common && [.running, .uncertain].contains($0.status) && !active.contains($0.id) }) == true {
            throw LaunchError.invalid("This repository has an unfinished Git operation. Reconcile or cancel it before another write.")
        }
        guard !active.contains(request.id) else { throw LaunchError.invalid("This operation is already running.") }
        if let id = request.workspaceID {
            guard !preparing.contains(id) else { throw LaunchError.invalid("This workspace is preparing another location.") }
            preparing.insert(id)
        }
        active.insert(request.id)
        defer { if let id = request.workspaceID { preparing.remove(id) }; tasks.removeValue(forKey: request.id); active.remove(request.id); cancelled.remove(request.id) }
        if var existing = operation(request.id) {
            guard existing.request == request, request.kind == .worktree, [.failed, .cancelled].contains(existing.status), await safeToRetry(existing) else {
                throw LaunchError.invalid("Reconcile the existing operation before retrying.")
            }
            existing.status = .running; existing.error = nil
            store.update { $0.recordOperation(existing) }
        } else { store.update { $0.recordOperation(LocationOperation(request)) } }
        do { try await store.flush() }
        catch {
            var failed = operation(request.id) ?? LocationOperation(request); failed.status = .failed; failed.error = error.localizedDescription
            store.update { $0.recordOperation(failed) }; throw error
        }
        let task = Task {
            if self.cancelled.contains(request.id) { throw CancellationError() }
            return try await self.execute(request)
        }
        tasks[request.id] = task
        do { return try await task.value }
        catch {
            if var operation = operation(request.id) {
                operation.status = error is CancellationError ? .cancelled : .failed
                operation.error = error is CancellationError ? "Cancelled. Retained files: " + request.destination : error.localizedDescription
                store.update { $0.recordOperation(operation) }
                try? await store.flush()
            }
            throw error
        }
    }
    private func receipt(_ request: LocationRequest, _ receipt: LocationReceipt, complete: Bool = false) async throws {
        guard var operation = operation(request.id) else { throw LaunchError.invalid("Operation metadata is missing.") }
        if !operation.receipts.contains(where: { $0.phase == receipt.phase && $0.commit == receipt.commit && $0.location?.path == receipt.location?.path }) { operation.receipts.append(receipt) }
        operation.error = nil
        if complete { operation.status = .complete }
        store.update { $0.recordOperation(operation) }
        try await store.flush()
    }
    private func write(_ request: LocationRequest, _ arguments: [String]) async throws -> GitResult {
        try await git.executor.execute(arguments, context: GitExecutionContext(root: operationRoot, operationID: request.id))
    }
    private func execute(_ request: LocationRequest) async throws -> WorkspaceLocation? {
        try await git.scheduler.destination(request.destination) {
            switch request.kind {
            case .create, .clone: return try await self.createProject(request)
            case .worktree: return try await self.createWorktree(request)
            case .deleteWorktree: return try await self.deleteWorktree(request)
            }
        }
    }
    nonisolated private static func directoryIdentity(_ path: String) -> String? {
        var value = stat()
        guard lstat(path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { return nil }
        return "\(value.st_dev):\(value.st_ino)"
    }
    nonisolated private static func directoryIsEmpty(_ path: String) -> Bool {
        guard let directory = opendir(path) else { return false }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { return false }
        }
        return true
    }
    private func safeToRetry(_ operation: LocationOperation) async -> Bool {
        let path = operation.request.destination
        let identity = operation.receipts.first(where: { $0.phase == .reserved })?.directoryIdentity
        let completed = operation.receipts.contains { $0.phase == .filesystemComplete || $0.phase == .reconciled }
        return await Task.detached {
            if !FileManager.default.fileExists(atPath: path) { return !completed }
            guard let identity, identity == Self.directoryIdentity(path) else { return false }
            return Self.directoryIsEmpty(path)
        }.value
    }
    private func verifyDirectoryIdentity(_ request: LocationRequest) async throws {
        let expected = operation(request.id)?.receipts.first(where: { $0.phase == .reserved })?.directoryIdentity
        let actual = await Task.detached { Self.directoryIdentity(request.destination) }.value
        guard let expected, expected == actual else { throw LaunchError.invalid("Reserved destination changed. Existing files were retained.") }
    }
    private func verifyReservedDirectory(_ request: LocationRequest) async throws {
        try await verifyDirectoryIdentity(request)
        let empty = await Task.detached { Self.directoryIsEmpty(request.destination) }.value
        guard empty else { throw LaunchError.invalid("Reserved destination is no longer empty. Existing files were retained.") }
    }
    private func reserve(_ request: LocationRequest) async throws {
        try Task.checkCancellation()
        try await Task.detached {
            if mkdir(request.destination, 0o755) != 0 {
                if errno == EEXIST { throw LaunchError.invalid("Destination already exists: " + request.destination) }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }.value
        try await receipt(request, LocationReceipt(.reserved, directoryIdentity: Self.directoryIdentity(request.destination)))
    }
    private func createProject(_ request: LocationRequest) async throws -> WorkspaceLocation {
        try await reserve(request)
        try Task.checkCancellation()
        try await verifyReservedDirectory(request)
        if request.kind == .clone {
            guard let url = request.repositoryURL else { throw LaunchError.invalid("Repository URL is missing.") }
            _ = try await write(request, ["clone", "--", url, request.destination]).checked()
        } else if request.initializeGit {
            _ = try await write(request, ["-C", request.destination, "init"]).checked()
        }
        try await verifyDirectoryIdentity(request)
        let location = try await git.discover(URL(fileURLWithPath: request.destination))
        try await receipt(request, LocationReceipt(.filesystemComplete, location: location))
        try Task.checkCancellation()
        return try await register(request, location)
    }
    private func register(_ request: LocationRequest, _ location: WorkspaceLocation) async throws -> WorkspaceLocation {
        let commit = operation(request.id)?.commit
        let created = request.kind == .worktree && operation(request.id)?.receipts.contains(where: { $0.phase == .filesystemComplete }) == true
        store.update {
            if location.isGit { $0.recordCheckout(location, createdBy: created ? request.id : nil, commit: commit) }
            if let workspaceID = request.workspaceID, $0.workspaces.first(where: { $0.id == workspaceID })?.locationOperationID == request.id {
                $0.acceptPreparedLocation(location, workspaceID: workspaceID)
                if request.kind == .worktree { $0.bindWorkspace(workspaceID) }
            }
            else if request.kind == .create || request.kind == .clone { _ = $0.registerProject(location) }
        }
        try await receipt(request, LocationReceipt(.registered, location: location), complete: true)
        return location
    }
    public func reconcileAll() async {
        for operation in store.state.locations?.operations ?? [] where operation.status != .complete {
            do { _ = try await reconcile(operation.id) }
            catch {
                if var failed = self.operation(operation.id) {
                    failed.status = .failed; failed.error = error.localizedDescription
                    store.update { $0.recordOperation(failed) }
                }
            }
        }
    }
    @discardableResult public func reconcile(_ id: UUID) async throws -> WorkspaceLocation? {
        guard var op = operation(id), tasks[id] == nil else { return nil }
        let request = op.request
        let root = operationRoot
        do {
            let live = try await Task.detached { try GitExecutionJournal.hasLiveCommands(root: root, operationID: id) }.value
            if live {
                op.status = .running; op.error = "Spookky-owned Git command is still running. Cancel it or wait, then reconcile."
                store.update { $0.recordOperation(op) }; try await store.flush(); return nil
            }
        } catch {
            op.status = .uncertain; op.error = error.localizedDescription
            store.update { $0.recordOperation(op) }; try await store.flush(); return nil
        }
        if op.status == .complete { return op.location }
        if request.kind == .deleteWorktree {
            if let source = request.sourcePath, let snapshot = try? await git.snapshot(WorkspaceLocation(path: source)),
               snapshot.location.commonRepository == request.commonRepository,
               !snapshot.checkouts.contains(where: { $0.path == request.destination }),
               !FileManager.default.fileExists(atPath: request.destination) {
                try await finishDeletion(request)
                return nil
            }
            op.status = .uncertain; op.error = "Deletion was interrupted. Refresh repository metadata before another explicit deletion."
        } else if let saved = op.location, op.receipts.contains(where: { $0.phase == .filesystemComplete || $0.phase == .registered }) {
            let actual = try await git.discover(URL(fileURLWithPath: saved.path))
            guard actual.checkoutIdentity == saved.checkoutIdentity else { throw LaunchError.invalid("Prepared checkout identity changed. Files were retained.") }
            return try await register(request, actual)
        } else if op.receipts.contains(where: { $0.phase == .reserved }) && request.kind == .create && !request.initializeGit {
            let actual = try await git.discover(URL(fileURLWithPath: request.destination))
            guard !actual.isGit else { throw LaunchError.invalid("Destination changed after creation. Inspect it before registering.") }
            return try await register(request, actual)
        } else if request.kind == .worktree, let sourcePath = request.sourcePath, let commit = op.commit,
                  let snapshot = try? await git.snapshot(WorkspaceLocation(path: sourcePath)),
                  snapshot.location.commonRepository == request.commonRepository,
                  let actual = snapshot.checkouts.first(where: { $0.path == request.destination && $0.branch == request.branch && $0.commit == commit }) {
            let location = try await git.discover(URL(fileURLWithPath: actual.path))
            try await receipt(request, LocationReceipt(.reconciled, commit: commit, location: location))
            return try await register(request, startLocation(location, source: snapshot.location))
        } else if op.receipts.contains(where: { $0.phase == .reserved }), request.kind == .clone || (request.kind == .create && request.initializeGit) {
            if let actual = try? await git.discover(URL(fileURLWithPath: request.destination)), actual.isGit, actual.scopePath == request.destination {
                let clean = try await git.command(actual.scopePath, ["status", "--porcelain", "-z"]).checked().isEmpty
                let origin = try await git.command(actual.scopePath, ["remote", "get-url", "origin"])
                if clean && (request.kind != .clone || (origin.status == 0 && origin.output.trimmingCharacters(in: .newlines) == request.repositoryURL)) {
                    try await receipt(request, LocationReceipt(.filesystemComplete, location: actual))
                    return try await register(request, actual)
                }
            }
            op.status = .uncertain
            op.error = "Incomplete destination retained at " + request.destination + ". Choose a fresh destination to retry."
        } else if request.kind == .worktree, await safeToRetry(op) {
            op.status = .failed; op.error = op.error ?? "No checkout was created. Retry the saved request, or edit the location draft. Retained destination: " + request.destination
        } else if request.kind == .worktree, git.executor is NativeGitExecutor {
            op.status = .failed
            op.error = "The destination could not be verified and was retained at " + request.destination + ". Choose another destination or branch. No Git command was repeated."
        } else {
            op.status = .uncertain
            op.error = "Inspect retained files at " + request.destination + ". No operation was repeated. Choose a fresh destination to retry."
        }
        store.update { $0.recordOperation(op) }; try await store.flush(); return nil
    }

    public func prepare(workspaceID: UUID) async throws -> WorkspaceLocation {
        if let pending = workspacePreparations[workspaceID] { return try await pending.value }
        let task = Task { try await self.prepareLocation(workspaceID: workspaceID) }
        workspacePreparations[workspaceID] = task
        defer { workspacePreparations.removeValue(forKey: workspaceID) }
        return try await task.value
    }
    private func prepareLocation(workspaceID: UUID) async throws -> WorkspaceLocation {
        guard let workspace = store.state.workspaces.first(where: { $0.id == workspaceID }) else { throw LaunchError.invalid("Workspace was closed.") }
        if let anchor = workspace.anchor { return anchor }
        var previous: LocationOperation?
        if let id = workspace.locationOperationID, let op = operation(id), op.request.kind == .worktree {
            if let recovered = try await reconcile(id) { return recovered }
            previous = operation(id)
            if previous?.status == .uncertain || previous?.status == .running { throw LaunchError.invalid(previous?.error ?? "Worktree creation requires reconciliation.") }
        }
        guard let draft = workspace.locationDraft, draft.mode == .worktree else { return workspace.selectedLocation }
        guard !preparing.contains(workspaceID), let projectID = workspace.projectID,
              let project = store.state.projects.first(where: { $0.id == projectID }) else { throw LaunchError.invalid("Choose a Git project before creating a worktree.") }
        let snapshot = try await git.snapshot(workspace.selectedLocation)
        guard snapshot.head != nil else { throw LaunchError.invalid("Create a first commit before making a worktree.") }
        let branch = draft.branchMode == .automatic ? Self.defaultBranch(workspaceID: workspaceID) : draft.branch
        try await git.validateBranch(snapshot.location.scopePath, name: branch)
        let destination = draft.destination.isEmpty ? Self.defaultDestination(project, workspaceID: workspaceID) : draft.destination
        guard destination.hasPrefix("/"), !destination.contains("\0"), destination != "/" else { throw LaunchError.invalid("Choose an absolute worktree destination.") }
        let canonical = await Task.detached { URL(fileURLWithPath: destination).standardizedFileURL.resolvingSymlinksInPath().path }.value
        let reference = snapshot.references.first { $0.name == draft.source || $0.qualifiedName == draft.source }
        guard draft.branchMode == .existing || draft.source == "HEAD" || reference != nil else { throw LaunchError.invalid("Starting reference is no longer available. Refresh the project.") }
        let source = draft.branchMode == .existing ? branch : reference?.qualifiedName ?? "HEAD"
        let remote = draft.branchMode == .existing ? nil : reference?.remote
        if let previous, await safeToRetry(previous), previous.request.destination == canonical,
           previous.request.branch == branch, previous.request.source == source,
           previous.request.existingBranch == (draft.branchMode == .existing), previous.request.useCachedSource == draft.useCachedSource {
            guard let result = try await start(previous.request) else { throw LaunchError.invalid("Worktree preparation has no result.") }
            return result
        }
        let cachedCommit = draft.cachedCommit ?? (previous?.request.source == source ? previous?.cachedCommit : nil)
        if draft.useCachedSource && remote != nil && cachedCommit == nil { throw LaunchError.invalid("Choose the displayed cached commit after a fetch failure, or retry fetching.") }
        let request = LocationRequest(kind: .worktree, destination: canonical, projectID: projectID, workspaceID: workspaceID,
            sourcePath: snapshot.location.path, commonRepository: snapshot.location.commonRepository, source: source,
            remote: remote, branch: branch, existingBranch: draft.branchMode == .existing, useCachedSource: draft.useCachedSource, cachedCommit: cachedCommit)
        guard let result = try await start(request) else { throw LaunchError.invalid("Worktree preparation has no result.") }
        return result
    }
    nonisolated public static func defaultBranch(workspaceID: UUID) -> String {
        "spookky/workspace-" + workspaceID.uuidString.prefix(8).lowercased()
    }
    nonisolated public static func defaultDestination(_ project: Project, workspaceID: UUID) -> String {
        let name = project.name.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("worktrees")
            .appendingPathComponent(name + "-" + project.id.uuidString.prefix(8).lowercased())
            .appendingPathComponent("workspace-" + workspaceID.uuidString.prefix(8).lowercased()).path
    }
    private func createWorktree(_ request: LocationRequest) async throws -> WorkspaceLocation {
        guard let path = request.sourcePath, let common = request.commonRepository, let branch = request.branch, let source = request.source else {
            throw LaunchError.invalid("Worktree request is incomplete.")
        }
        return try await git.scheduler.write(repository: common) {
            let current = try await self.git.snapshot(WorkspaceLocation(path: path))
            guard current.location.commonRepository == common, current.head != nil else { throw LaunchError.invalid("Repository identity changed or has no commit.") }
            if request.existingBranch, let existing = current.checkouts.first(where: { $0.branch == branch }) {
                let location = try await self.git.discover(URL(fileURLWithPath: existing.path))
                try await self.receipt(request, LocationReceipt(.reconciled, location: location))
                return try await self.register(request, self.startLocation(location, source: current.location))
            }
            let savedCommit = await self.operation(request.id)?.commit
            if let remote = request.remote, !request.useCachedSource, savedCommit == nil {
                do { _ = try await self.write(request, ["-C", current.location.scopePath, "fetch", "--", remote]).checked() }
                catch is CancellationError { throw CancellationError() }
                catch {
                    let cached = try? await self.git.resolve(current.location.scopePath, reference: source)
                    if let cached { try await self.receipt(request, LocationReceipt(.cachedSource, commit: cached)) }
                    throw LaunchError.command(error.localizedDescription + (cached.map { "\nFetch failed. Retry, or explicitly use cached " + source + " at " + $0 } ?? "\nNo cached commit is available."))
                }
                try await self.receipt(request, LocationReceipt(.fetched))
            }
            let commit: String
            if let savedCommit { commit = savedCommit }
            else { commit = try await self.git.resolve(current.location.scopePath, reference: request.useCachedSource && request.remote != nil ? request.cachedCommit! : request.existingBranch ? "refs/heads/" + branch : source) }
            try await self.receipt(request, LocationReceipt(.resolved, commit: commit))
            try Task.checkCancellation()
            let refreshed = try await self.git.discover(URL(fileURLWithPath: path))
            guard refreshed.commonRepository == common else { throw LaunchError.invalid("Repository identity changed before creation.") }
            try await self.git.validateBranch(refreshed.scopePath, name: branch)
            let branchResult = try await self.git.command(refreshed.scopePath, ["show-ref", "--verify", "--quiet", "refs/heads/" + branch])
            if !request.existingBranch && branchResult.status != 1 { throw LaunchError.invalid("Branch already exists or cannot be checked: " + branch) }
            if request.existingBranch {
                guard try await self.git.resolve(refreshed.scopePath, reference: "refs/heads/" + branch) == commit else { throw LaunchError.invalid("Branch moved before creation. Refresh and try again.") }
            }
            try await self.ensureWorktreeParent(request.destination)
            let reserved = await self.operation(request.id)?.receipts.first { $0.phase == .reserved }
            if reserved?.directoryIdentity == nil { try await self.reserve(request) }
            try await self.verifyReservedDirectory(request)
            try Task.checkCancellation()
            let arguments = request.existingBranch ? ["worktree", "add", "--", request.destination, branch] : ["worktree", "add", "-b", branch, "--", request.destination, commit]
            _ = try await self.write(request, ["-C", refreshed.scopePath] + arguments).checked()
            let location = try await self.git.discover(URL(fileURLWithPath: request.destination))
            guard location.commonRepository == common else { throw LaunchError.invalid("Created checkout identity does not match the repository.") }
            try await self.receipt(request, LocationReceipt(.filesystemComplete, commit: commit, location: location))
            try Task.checkCancellation()
            return try await self.register(request, self.startLocation(location, source: current.location))
        }
    }
    private func startLocation(_ location: WorkspaceLocation, source: WorkspaceLocation) -> WorkspaceLocation {
        let prefix = source.scopePath + "/"
        guard source.path.hasPrefix(prefix) else { return location }
        var result = location
        result.path = URL(fileURLWithPath: location.scopePath).appendingPathComponent(String(source.path.dropFirst(prefix.count))).path
        return result
    }
    private func ensureWorktreeParent(_ destination: String) async throws {
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) { return }
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("worktrees").path
        guard parent.path.hasPrefix(defaultRoot + "/") else { throw LaunchError.folderUnavailable(parent.path) }
        try await Task.detached { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }.value
    }
    public func deletionRequest(_ record: CheckoutRecord) throws -> LocationRequest {
        guard let creator = record.createdBy, let operation = operation(creator), operation.request.kind == .worktree,
              operation.receipts.contains(where: { $0.phase == .filesystemComplete }), let common = record.location.commonRepository else {
            throw LaunchError.invalid("Only verified app-created worktrees can be deleted here.")
        }
        return LocationRequest(kind: .deleteWorktree, destination: record.location.scopePath,
            sourcePath: store.state.projects.first(where: { $0.location.commonRepository == common })?.location.scopePath,
            commonRepository: common, branch: record.location.branch)
    }
    public func checkDeletion(_ request: LocationRequest) async throws {
        _ = try await validatedDeletionCommit(request, refreshRemote: false)
    }
    private func validatedDeletionCommit(_ request: LocationRequest, refreshRemote: Bool) async throws -> String {
        guard let record = store.state.locations?.checkouts.first(where: { $0.location.scopePath == request.destination }),
              let creator = record.createdBy, let creation = operation(creator), creation.request.kind == .worktree,
              creation.receipts.contains(where: { $0.phase == .filesystemComplete && $0.location?.checkoutIdentity == record.location.checkoutIdentity }) else {
            throw LaunchError.invalid("App-created worktree ownership could not be verified.")
        }
        guard request.kind == .deleteWorktree, let path = request.sourcePath, let common = request.commonRepository else {
            throw LaunchError.invalid("Register an available checkout from this repository before removing its worktree.")
        }
        guard !store.state.workspaces.contains(where: { workspace in
            let location = workspace.anchor ?? workspace.selectedLocation
            return location.scopePath == request.destination && workspace.tabs.contains { [.running, .preparing, .launching, .reconnecting, .uncertain, .unavailable].contains($0.status) || ($0.status == .failed && ($0.binding != nil || $0.launch != nil)) }
        }) else { throw LaunchError.invalid("Close all active or uncertain sessions for this worktree before deleting it.") }
        guard let runtime else { throw LaunchError.invalid("Session ownership is unavailable. Worktree deletion was blocked.") }
        for binding in try await runtime.list() where binding.phase != .closed {
            guard let observed = try await runtime.inspect(binding) else {
                if binding.phase == .intent || binding.phase == .starting { throw LaunchError.uncertainLaunch }
                continue
            }
            if observed.dead { continue }
            guard let cwd = observed.currentDirectory else { throw LaunchError.invalid("A live session's directory is unknown. Close it before deleting the worktree.") }
            let canonical = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
            if canonical == request.destination || canonical.hasPrefix(request.destination + "/") || binding.directory == request.destination || binding.directory.hasPrefix(request.destination + "/") {
                throw LaunchError.invalid("An owned session is using this worktree. Close it before deleting.")
            }
        }
        let snapshot = try await git.snapshot(WorkspaceLocation(path: path))
        guard snapshot.location.commonRepository == common else { throw LaunchError.invalid("Repository identity changed.") }
        guard let worktree = snapshot.checkouts.first(where: { $0.path == request.destination }) else { throw LaunchError.invalid("Worktree is no longer registered at " + request.destination) }
        guard !worktree.locked else { throw LaunchError.invalid("Worktree is locked.") }
        guard let branch = worktree.branch, branch == request.branch else { throw LaunchError.invalid("Worktree branch changed from " + (request.branch ?? "Detached HEAD") + " to " + (worktree.branch ?? "Detached HEAD") + ". Refresh before deleting.") }
        guard try await git.command(worktree.path, ["status", "--porcelain", "-z", "--untracked-files=all"]).checked().isEmpty else { throw LaunchError.invalid("Worktree contains modified or untracked files.") }
        let upstream = try await git.command(worktree.path, ["rev-parse", "--symbolic-full-name", "@{upstream}"])
        guard upstream.status == 0 else { throw LaunchError.invalid("No upstream is configured. Push and verify this branch before deleting its worktree.") }
        let ref = upstream.output.trimmingCharacters(in: .newlines)
        let refs = try await git.snapshot(WorkspaceLocation(path: worktree.path))
        guard let remote = refs.references.first(where: { "refs/remotes/" + $0.name == ref })?.remote else { throw LaunchError.invalid("The upstream is not a verified remote reference.") }
        var base = refs.defaultSource
        if refreshRemote {
            let baseRemote = refs.references.first(where: { $0.name == base || $0.qualifiedName == base })?.remote ?? remote
            for name in Set([remote, baseRemote]).sorted() { _ = try await write(request, ["-C", path, "fetch", "--", name]).checked() }
            let head = try await git.command(path, ["ls-remote", "--symref", "--", baseRemote, "HEAD"]).checked()
            guard let line = head.split(separator: "\n").first(where: { $0.hasPrefix("ref: refs/heads/") && $0.hasSuffix("\tHEAD") }) else { throw LaunchError.invalid("Remote default branch could not be verified.") }
            let branch = String(line.dropFirst("ref: refs/heads/".count).dropLast("\tHEAD".count))
            base = "refs/remotes/" + baseRemote + "/" + branch
        }
        guard base != "HEAD" else { throw LaunchError.invalid("A known remote default branch is required to verify merged commits.") }
        let commit = try await git.resolve(worktree.path, reference: "HEAD")
        let pushed = try await git.command(worktree.path, ["merge-base", "--is-ancestor", commit, ref])
        let merged = try await git.command(worktree.path, ["merge-base", "--is-ancestor", commit, base])
        guard pushed.status == 0 && merged.status == 0 else { throw LaunchError.invalid("Worktree has unpushed or unmerged commits.") }
        return commit
    }
    private func deleteWorktree(_ request: LocationRequest) async throws -> WorkspaceLocation? {
        guard let common = request.commonRepository, let path = request.sourcePath else { throw LaunchError.invalid("Repository is unavailable.") }
        return try await git.scheduler.write(repository: common) {
            let commit = try await self.validatedDeletionCommit(request, refreshRemote: true)
            try await self.receipt(request, LocationReceipt(.resolved, commit: commit))
            guard try await self.git.resolve(request.destination, reference: "HEAD") == commit,
                  try await self.git.command(request.destination, ["status", "--porcelain", "-z", "--untracked-files=all"]).checked().isEmpty else { throw LaunchError.invalid("Worktree changed during deletion checks. It was kept.") }
            _ = try await self.write(request, ["-C", path, "worktree", "remove", "--", request.destination]).checked()
            try await self.finishDeletion(request)
            return nil
        }
    }
    private func finishDeletion(_ request: LocationRequest) async throws {
        store.update { state in
            if let identity = state.locations?.checkouts.first(where: { $0.location.scopePath == request.destination })?.location.checkoutIdentity { state.removeCheckout(identity) }
        }
        try await receipt(request, LocationReceipt(.removed), complete: true)
    }
}
