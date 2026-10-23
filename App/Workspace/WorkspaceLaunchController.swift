import AppKit
import Darwin
import SpookkyCore
import SpookkyFiles
import SpookkyRuntime
import SpookkyWorkspace
import SpookkyGit

@MainActor final class WorkspaceLaunchController {
    weak var host: WorkspaceWindowController?
    let store: WorkspaceStore
    let sessionCatalog: any SessionCatalogReading
    init(host: WorkspaceWindowController) { self.host = host; store = host.store; sessionCatalog = host.sessionCatalog }
    var continuingConversations = Set<ConversationID>()
    var pendingIdentities = Set<UUID>()
    var conversationOpenTask: Task<Void, Never>?
    var preflightConversation: ConversationID?
    var continuationTokens: [ConversationID: UUID] = [:]
    var initialLaunchTasks: [UUID: Task<Void, Never>] = [:]
    var startupDeadlineTask: Task<Void, Never>?
    var startupDeadline: Date?
    var startupNotices: [UUID: ProviderStartupNoticeView] = [:]
    var continuationErrors: [ConversationID: String] = [:]
    lazy var continuations = ConversationContinuationCoordinator(store: store)
    func stop() {
        cancelLaunchPreflight()
        startupDeadlineTask?.cancel(); startupDeadlineTask = nil
    }
    func openConversationWorkspace(_ id: UUID) {
        guard let host else { return }
        guard let workspace = host.store.state.workspaces.first(where: { $0.id == id }) else { return }
        if let identity = workspace.conversationID, continuingConversations.contains(identity), host.store.state.selectedWorkspaceID == id { return }
        cancelLaunchPreflight()
        host.selectWorkspace(id)
        guard let primary = workspace.primaryTerminal, let identity = workspace.conversationID else { return }
        let item = workspace.catalogMetadata ?? ConversationMetadata(id: identity, title: workspace.displayTitle,
            directory: primary.launch?.directory ?? primary.startDirectory ?? workspace.directory, updatedAt: Date())
        guard identity == item.id else { return }
        guard !continuingConversations.contains(item.id) else { return }
        if workspace.conversationOwnershipAmbiguous == true {
            continuationErrors[item.id] = "More than one retained terminal reports this conversation. Reconnect its original terminal before resuming."
            host.contentKey = ""; host.render(); return
        }
        let token = UUID(); continuationTokens[item.id] = token; preflightConversation = item.id
        continuingConversations.insert(item.id); continuationErrors[item.id] = nil
        host.contentKey = ""; host.render()
        conversationOpenTask = Task { [weak self, weak host] in
            guard let self, let host else { return }
            defer {
                if continuationTokens[item.id] == token {
                    continuingConversations.remove(item.id); continuationTokens[item.id] = nil
                    if preflightConversation == item.id { preflightConversation = nil; conversationOpenTask = nil }
                    host.contentKey = ""; host.render()
                }
            }
            do {
                if primary.binding != nil || primary.launch != nil {
                    await host.launches.reconcile(primary.id)
                    try Task.checkCancellation()
                    guard host.store.state.selectedWorkspaceID == id, let observed = host.store.state.tab(primary.id) else { return }
                    if observed.status == .running { reconnect(primary.id); return }
                    guard observed.status == .ended else { return }
                }
                if item.availability == .historyUnavailable {
                    throw LaunchError.invalid("The provider's saved history is unavailable. Restore it, then retry this conversation.")
                }
                let assessment = await host.associationResolver.resolve(directory: item.directory, projects: host.store.state.projects, preferredProjectID: workspace.projectID)
                try Task.checkCancellation()
                guard let location = assessment.location, assessment.status == .matched || assessment.status == .unregistered else {
                    throw LaunchError.invalid(assessment.message ?? "The original folder is unavailable. Locate it before continuing.")
                }
                let decision = try await ConversationExecutionCheck.prepare(item, resolver: host.savedConversationResolver)
                try Task.checkCancellation()
                guard host.store.state.selectedWorkspaceID == id, let current = host.store.state.workspaces.first(where: { $0.id == id }),
                      current.conversationID == item.id, current.primaryTerminalID == primary.id,
                      current.primaryTerminal?.binding == nil || current.primaryTerminal?.status == .ended else { return }
                if current.primaryTerminal?.status == .ended { host.surfaces.release(primary.id) }
                let presentation = host.store.state.presentation(for: current.threadKey)
                let projectID = presentation.hasProjectOverride ? presentation.projectOverride : assessment.projectID
                host.store.update { $0.setLocation(location, projectID: projectID, workspaceID: id) }
                // Cancellation remains active until the coordinator commits durable launch intent.
                // The coordinator records an owned receipt even when navigation cancels this task.
                var available = item; available.availability = .local
                await host.launches.resume(primary.id, conversation: available, prepared: decision.launch)
            } catch is CancellationError { }
            catch { if !Task.isCancelled && continuationTokens[item.id] == token { continuationErrors[item.id] = error.localizedDescription } }
        }
    }
    func cancelLaunchPreflight() {
        for task in initialLaunchTasks.values { task.cancel() }
        conversationOpenTask?.cancel(); conversationOpenTask = nil
        if let id = preflightConversation {
            continuationTokens[id] = nil; continuingConversations.remove(id); preflightConversation = nil
        }
    }
    func openHistoryRecord(_ record: ConversationCatalogRecord) {
        guard let host else { return }
        var workspaceID: UUID!
        host.store.update { workspaceID = $0.openCatalogRecord(record) }
        openConversationWorkspace(workspaceID)
    }
    func launch(_ id: UUID, tool: SessionTool? = nil) {
        guard let host else { return }
        guard initialLaunchTasks[id] == nil, host.composers[id]?.isImportingImage != true, let tab = host.store.state.tab(id),
              let workspace = host.store.state.workspace(containing: id), !host.launches.isBusy(id),
              tab.isEditable || (tab.status == .failed && tab.launch != nil) else { return }
        if (tool ?? tab.draft.tool) != .shell, workspace.primaryTerminalID != id {
            host.store.update { $0.separateAgentTerminal(id) }; launch(id, tool: tool); return
        }
        if workspace.locationOwnerWorkspaceID != nil {
            var resolved = false
            host.store.update { resolved = $0.resolveConversationLocation(workspaceID: workspace.id) }
            if resolved { launch(id, tool: tool) }
            else { host.alert("Location is not ready", "This draft shares a retained location operation. Finish or recover that operation, or choose a folder explicitly.") }
            return
        }
        let deleting = host.store.state.locations?.operations.contains { $0.status == .running && $0.request.kind == .deleteWorktree && $0.request.destination == workspace.selectedLocation.scopePath } ?? false
        guard !deleting else { host.alert("Worktree removal in progress", "Wait for removal to finish before launching here."); return }
        initialLaunchTasks[id] = Task { [weak self, weak host] in
            guard let self, let host else { return }
            defer { initialLaunchTasks[id] = nil }
            do {
                await host.agentPreferencesTask?.value
                try Task.checkCancellation()
                if workspace.anchor == nil && (workspace.locationDraft?.mode == .worktree || workspace.locationOperationID != nil) {
                    host.store.update { $0.apply(.preparing, to: id) }
                    _ = try await host.locations.prepare(workspaceID: workspace.id)
                }
                try Task.checkCancellation()
                guard host.store.state.tab(id) != nil else { return }
                await host.launches.launch(id, tool: tool)
            } catch is CancellationError {
                host.store.update { $0.cancelPreparation(id, restoring: tab) }
            } catch {
                let recovery: FailureRecovery?
                if case .folderUnavailable = error as? LaunchError { recovery = .locateFolder } else { recovery = nil }
                host.store.update { $0.apply(.failure(.failed, TabFailure(.validation, error.localizedDescription, recovery: recovery), clearIntent: true), to: id) }
            }
        }
    }
    func reconnect(_ id: UUID) {
        guard let host else { return }
        Task {
            host.surfaces.release(id)
            await host.launches.reconcile(id)
            host.contentKey = ""; host.render()
        }
    }
    func updateStartupFeedback() {
        guard let host else { return }
        let now = Date()
        for (id, notice) in startupNotices { notice.update(message: host.store.state.tab(id)?.startupMessage(at: now)) }
        let deadline = host.window.isVisible ? host.store.state.visibleTabIDs.compactMap { host.store.state.tab($0)?.pendingStartup?.noticeDate }.filter { $0 > now }.min() : nil
        guard deadline != startupDeadline else { return }
        startupDeadlineTask?.cancel(); startupDeadlineTask = nil; startupDeadline = deadline
        guard let deadline else { return }
        startupDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard let self else { return }
            startupDeadline = nil; startupDeadlineTask = nil
            updateStartupFeedback()
        }
    }
}
