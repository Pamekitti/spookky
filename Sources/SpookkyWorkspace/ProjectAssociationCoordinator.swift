import Foundation
import SpookkyCore
import SpookkyGit

@MainActor public final class ProjectAssociationCoordinator {
    struct Candidate: Sendable, Hashable {
        let workspaceID: UUID
        let primaryTerminalID: UUID
        let conversationID: ConversationID
        let invocationID: UUID
        let operationID: UUID
        let projectID: UUID?
    }
    typealias Association = @Sendable (LaunchSpec, ConversationID, ProjectAssociationResolution,
                                       @escaping @Sendable () async -> Bool) async -> ProviderProjectAssociation
    private let store: WorkspaceStore
    private let perform: Association
    private var queue: [Candidate] = []
    private var task: Task<Void, Never>?
    private var attempted = Set<Candidate>()
    public init(store: WorkspaceStore) { self.store = store; perform = Self.associate }
    init(store: WorkspaceStore, perform: @escaping Association) { self.store = store; self.perform = perform }

    // Called only after the activity receiver authenticated the event and WorkspaceState accepted it.
    public func observe(_ event: AgentEvent, tabID: UUID) {
        guard let candidate = Self.candidate(event, tabID: tabID, state: store.state),
              !attempted.contains(candidate), queue.count < 16 else { return }
        attempted.insert(candidate); queue.append(candidate)
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            while !queue.isEmpty {
                let request = queue.removeFirst()
                defer { attempted.remove(request) }
                guard isCurrent(request), let launch = store.state.tab(request.primaryTerminalID)?.launch else { continue }
                let resolution = await ProjectAssociationResolver().resolve(directory: launch.directory,
                    projects: store.state.projects, preferredProjectID: request.projectID)
                guard isCurrent(request) else { continue }
                let result: ProviderProjectAssociation
                if resolution.status != .matched {
                    let status: ProviderProjectAssociation.Status = resolution.status == .ambiguous ? .ambiguous : resolution.status == .unregistered ? .unregistered : .unavailable
                    result = ProviderProjectAssociation(sessionID: request.conversationID.sessionID, status: status,
                        message: resolution.message ?? "Project association is unavailable.")
                } else {
                    result = await perform(launch, request.conversationID, resolution) { [weak self] in
                        await self?.isCurrent(request) == true
                    }
                }
                guard isCurrent(request) else { continue }
                store.update { $0.recordProjectAssociation(result, workspaceID: request.workspaceID,
                    primaryTerminalID: request.primaryTerminalID, invocationID: request.invocationID, operationID: request.operationID) }
            }
        }
    }
    func waitUntilIdle() async { await task?.value }

    static func candidate(_ event: AgentEvent, tabID: UUID, state: WorkspaceState) -> Candidate? {
        guard event.isValid, event.provider == .codex, event.childID == nil,
              let workspace = state.workspace(containing: tabID), workspace.primaryTerminalID == tabID,
              workspace.conversationOwnershipAmbiguous != true,
              let conversationID = workspace.conversationID, conversationID.provider == .codex,
              conversationID.sessionID == event.sessionID,
              let tab = workspace.primaryTerminal, let launch = tab.launch, launch.tool == .codex,
              launch.operationID == event.bindingID || tab.binding?.id == event.bindingID,
              tab.activity?.invocationID == event.invocationID, tab.activity?.sessionID == event.sessionID,
              (tab.projectAssociation?.conversationID != conversationID || (tab.projectAssociation?.status == .failed && event.kind == .finished)),
              Self.freshExecutable(launch) != nil else { return nil }
        return Candidate(workspaceID: workspace.id, primaryTerminalID: tabID, conversationID: conversationID,
                         invocationID: event.invocationID, operationID: launch.operationID, projectID: workspace.projectID)
    }
    private func isCurrent(_ request: Candidate) -> Bool {
        guard let workspace = store.state.workspaces.first(where: { $0.id == request.workspaceID }),
              workspace.conversationOwnershipAmbiguous != true, workspace.conversationID == request.conversationID,
              workspace.primaryTerminalID == request.primaryTerminalID, workspace.projectID == request.projectID,
              let primary = workspace.primaryTerminal, primary.launch?.operationID == request.operationID,
              primary.activity?.invocationID == request.invocationID,
              primary.activity?.provider == request.conversationID.provider,
              primary.activity?.sessionID == request.conversationID.sessionID else { return false }
        return true
    }
    nonisolated private static func associate(_ launch: LaunchSpec, _ conversationID: ConversationID,
                                             _ resolution: ProjectAssociationResolution,
                                             _ isCurrent: @escaping @Sendable () async -> Bool) async -> ProviderProjectAssociation {
        do {
            guard let executable = await Self.freshExecutable(launch), await isCurrent() else {
                return ProviderProjectAssociation(sessionID: conversationID.sessionID, status: .unavailable,
                    message: "The conversation changed before project association.")
            }
            let environment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, new in new }
            let connection = try await Task.detached { try CodexProjectRPC(executable: executable, environment: environment) }.value
            let result = await CodexProjectClient().associate(sessionID: conversationID.sessionID,
                resolution: resolution, connection: connection, isCurrent: isCurrent)
            await connection.close()
            return result
        } catch CodexProjectError.unsupported {
            return ProviderProjectAssociation(sessionID: conversationID.sessionID, status: .unsupported,
                message: CodexProjectError.unsupported.localizedDescription)
        } catch {
            return ProviderProjectAssociation(sessionID: conversationID.sessionID, status: .failed,
                message: "Codex project association is unavailable. The selected working directory is unchanged.")
        }
    }

    public static func freshExecutable(_ launch: LaunchSpec) -> String? {
        guard launch.tool == .codex else { return nil }
        var executable = launch.executable, arguments = launch.arguments
        if arguments.starts(with: ["--agent-run", "codex", "--executable"]), arguments.count >= 5, arguments[4] == "--" {
            executable = arguments[3]; arguments = Array(arguments.dropFirst(5))
        }
        let options = arguments.prefix(while: { $0 != "--" })
        guard !options.contains(where: { ["resume", "fork", "--resume", "--remote", "--worktree"].contains($0) || $0.hasPrefix("--remote=") }),
              executable.hasPrefix("/"), !executable.contains("\0") else { return nil }
        return executable
    }
}
