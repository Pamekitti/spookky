import AppKit
import Darwin
import SpookkyCore
import SpookkyFiles
import SpookkyRuntime
import SpookkyWorkspace
import SpookkyGit

@MainActor final class WorkspaceSidebarCoordinator {
    weak var host: WorkspaceWindowController?
    let store: WorkspaceStore
    let sessionCatalog: any SessionCatalogReading
    init(host: WorkspaceWindowController) { self.host = host; store = host.store; sessionCatalog = host.sessionCatalog }
    var avatarTasks: [UUID: Task<Void, Never>] = [:]
    var projectOwners: [String: String] = [:]
    var projectImages: [UUID: NSImage] = [:]
    var sidebarRecords: [String: ConversationCatalogRecord] = [:]
    let sidebarPRService = GitHubPullRequestService()
    var sidebarGit: [String: (checkout: SidebarCheckoutInfo?, pr: PullRequestStatus?, date: Date)] = [:]
    var sidebarGitTask: Task<Void, Never>?
    var sidebarGitTimer: Timer?
    var sidebarGitGeneration = UUID()
    var sidebarVisibleItems: [WorkspaceSidebarItem] = []
    var selectedSidebarOccurrence: String?
    var sectionLimits: [String: Int] = [:]
    var sidebarWorkspaceIDs: [String: UUID] = [:]
    var showingArchived = false
    var providerHistoryNotices = Set<String>()
    func installProjectAvatar(_ project: Project) {
        guard let host else { return }
        guard project.location.isGit, avatarTasks[project.id] == nil else { return }
        avatarTasks[project.id] = Task { [weak self, weak host] in
            guard let self, let host else { return }
            let path = project.location.scopePath
            let owner: String
            if let known = projectOwners[path] { owner = known }
            else {
                owner = (try? await GitRepository().githubOwner(project.location)) ?? ""
                guard !Task.isCancelled else { return }; projectOwners[path] = owner
            }
            guard !owner.isEmpty, !Task.isCancelled else { return }
            if let data = await host.avatarCache.cached(owner), let image = NSImage(data: data) {
                projectImages[project.id] = image; host.chromeRevision = ""; host.render()
            }
            guard let data = await host.avatarCache.image(owner), !Task.isCancelled,
                  host.store.state.projects.contains(where: { $0.id == project.id }), let image = NSImage(data: data) else { return }
            projectImages[project.id] = image; host.chromeRevision = ""; host.render()
        }
    }
    func stop() {
        sidebarGitTask?.cancel(); sidebarGitTimer?.invalidate()
        sidebarGitTimer = nil
        for task in avatarTasks.values { task.cancel() }
        avatarTasks.removeAll()
    }
    func renderConversationSidebar(_ state: WorkspaceState, collapsed: Bool) {
        guard let host else { return }
        let structure = String(collapsed) + String(describing: host.window.effectiveAppearance.name)
        if collapsed {
            if host.sidebarRevision != structure { host.sidebarRevision = structure; host.clear(host.rail) }
            host.conversationSidebar.update(items: [], collapsed: true)
            return
        }
        if host.sidebarRevision != structure {
            host.sidebarRevision = structure; host.clear(host.rail)
            host.rail.edgeInsets = NSEdgeInsets(top: SpookkyStyle.points(8), left: 0, bottom: SpookkyStyle.points(12), right: 0)
            let create = ActionButton("New chat", symbol: "plus", help: "New chat · ⌘N") { [weak self] in self?.host?.newWorkspace() }
            create.contentTintColor = SidebarPalette.text
            create.alignment = .left
            create.heightAnchor.constraint(equalToConstant: 32).displayScaled().isActive = true
            let controls = NSStackView(views: [create, host.historySearch])
            controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = SpookkyStyle.points(4)
            controls.edgeInsets = NSEdgeInsets(top: 0, left: SpookkyStyle.points(8), bottom: 0, right: SpookkyStyle.points(8))
            for view in controls.arrangedSubviews { view.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -16).displayScaled().isActive = true }
            host.rail.addArrangedSubview(controls)
            host.historySearch.heightAnchor.constraint(equalToConstant: 28).displayScaled().isActive = true
            host.rail.addArrangedSubview(host.conversationSidebar)
            host.conversationSidebar.setContentHuggingPriority(.defaultLow, for: .vertical)
            for view in host.rail.arrangedSubviews { view.widthAnchor.constraint(equalTo: host.rail.widthAnchor).isActive = true }
            host.conversationSidebar.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).displayScaled().isActive = true
            host.conversationSidebar.onActivate = { [weak self] in self?.activateSidebarItem($0) }
            host.conversationSidebar.onAddProject = { [weak self] in self?.host?.addProjectMenu(anchor: $0) }
            host.conversationSidebar.onAddProjectSession = { [weak self] value in
                if let id = UUID(uuidString: value.replacingOccurrences(of: "project:", with: "")) { self?.host?.newProjectWorkspace(id) }
            }
            host.conversationSidebar.onMore = { [weak self] value in self?.host?.history.showMoreHistory(String(value.dropFirst(5))) }
            host.conversationSidebar.onContextMenu = { [weak self] in self?.sidebarContextMenu($0) }
            host.conversationSidebar.onThreadAction = { [weak self] id, action in
                guard let menu = self?.sidebarContextMenu(id), let item = menu.items.first(where: {
                    (action == "pin" ? ["Pin", "Unpin"] : ["Archive", "Unarchive"]).contains($0.title)
                }), let selector = item.action else { return }
                NSApp.sendAction(selector, to: item.target, from: item)
            }
            host.conversationSidebar.onReorder = { [weak self, weak host] ids in
                guard let self, let host else { return }
                let keys = ids.compactMap(sidebarThreadKey)
                guard keys.count == ids.count else { return }
                host.store.update { $0.reorderThreads(keys) }
                host.chromeRevision = ""; host.render()
            }
            host.conversationSidebar.onVisibleItems = { [weak self] items in
                guard let self else { return }
                if sidebarVisibleItems.map(\.id) != items.map(\.id), sidebarGitTask != nil {
                    sidebarGitTask?.cancel()
                    let service = sidebarPRService; Task { await service.cancelPending() }
                }
                sidebarVisibleItems = items; refreshSidebarGit()
            }
        }
        var items: [WorkspaceSidebarItem] = []; sidebarRecords.removeAll(keepingCapacity: true); sidebarWorkspaceIDs.removeAll(keepingCapacity: true)
        var seen = Set<ConversationID>()
        let search = host.historySearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedWorkspace = state.selected
        let workspaceByKey = Dictionary(grouping: state.workspaces, by: \.threadKey)
            .compactMapValues { state.preferredWorkspace(in: $0) }
        func append(_ records: [ConversationCatalogRecord], projectID: UUID?, key: String) {
            let supplemental = state.workspaces.filter { workspace in
                !workspace.isLanding && !state.isArchived(workspace) && (key == "search" || workspace.projectID == projectID) &&
                    (workspace.id == state.selectedWorkspaceID || workspace.catalogMetadata == nil && workspace.viewClosed != true) &&
                    (search.isEmpty || workspace.displayTitle.localizedCaseInsensitiveContains(search))
            }.compactMap { workspace -> ConversationCatalogRecord? in
                guard let identity = workspace.conversationID else { return nil }
                let metadata = workspace.catalogMetadata ?? ConversationMetadata(id: identity, title: workspace.displayTitle,
                    directory: workspace.directory, updatedAt: workspace.lastViewedAt ?? Date.distantPast)
                return ConversationCatalogRecord(metadata: metadata, projectID: workspace.projectID,
                    localAlias: workspace.customTitle ? workspace.title : nil, workspaceID: workspace.id, terminalID: workspace.primaryTerminalID)
            }
            let moved = (state.threadPresentations ?? [:]).values.filter { $0.hasProjectOverride && (key == "search" || $0.projectOverride == projectID) }.compactMap(\.conversation)
            var rows: [(id: String, position: Double, record: ConversationCatalogRecord?, workspace: Workspace?)] = []
            for originalRecord in records + supplemental + moved {
                var record = originalRecord
                let presentation = state.presentation(for: record.id.threadKey)
                if presentation.hasProjectOverride { record.projectID = presentation.projectOverride }
                guard presentation.archivedAt == nil else { continue }
                let workspace = workspaceByKey[record.id.threadKey]
                if key != "search", (workspace?.projectID ?? record.projectID) != projectID { continue }
                if !search.isEmpty, ![workspace?.displayTitle ?? record.displayTitle, record.metadata.directory, record.id.sessionID].contains(where: { $0.localizedCaseInsensitiveContains(search) }) { continue }
                guard seen.insert(record.id).inserted else { continue }
                rows.append(("conversation:" + record.id.threadKey,
                    presentation.sidebarPosition ?? record.metadata.updatedAt.timeIntervalSinceReferenceDate, record, workspace))
            }
            for workspace in state.workspaces where !workspace.isLanding && workspace.projectID == projectID && workspace.conversationID == nil && !state.isArchived(workspace) &&
                (search.isEmpty || workspace.displayTitle.localizedCaseInsensitiveContains(search)) {
                let fallback = Double(state.workspaces.firstIndex { $0.id == workspace.id } ?? 0)
                rows.append((workspace.threadKey, state.presentation(for: workspace.threadKey).sidebarPosition ?? fallback, nil, workspace))
            }
            rows.sort { $0.position == $1.position ? $0.id < $1.id : $0.position > $1.position }
            let limit = host.history.historyPageLimits[key] ?? (key == "search" ? 10 : 5)
            let selectedIndex = rows.firstIndex { $0.workspace?.id == state.selectedWorkspaceID }
            let visibleLimit = max(limit, selectedIndex.map { $0 + 1 } ?? 0)
            if visibleLimit > limit { host.history.historyPageLimits[key] = visibleLimit }
            let visible = Array(rows.prefix(visibleLimit))
            for row in visible {
                let record = row.record, workspace = row.workspace, activity = workspace?.activityState
                if let record { sidebarRecords[row.id] = record }
                guard let title = workspace?.displayTitle ?? record?.displayTitle else { continue }
                let heading = record.map { $0.displayTitle + " · " + $0.id.provider.displayName } ?? title
                items.append(WorkspaceSidebarItem(id: row.id, kind: .conversation, title: title,
                    image: SpookkyStyle.toolImage(record?.id.provider ?? workspace?.displayProvider ?? .shell),
                    help: ([heading, record?.metadata.directory ?? workspace?.directory, workspace?.currentProjectAssociation?.message, activity?.label].compactMap { $0 }).joined(separator: "\n"),
                    selected: workspace?.id == state.selectedWorkspaceID && (selectedSidebarOccurrence == nil || selectedSidebarOccurrence == row.id),
                    nested: projectID != nil, activity: activity, groupID: key, reorderable: key != "search"))
            }
            if rows.count > limit || host.history.historyHasMore.contains(key) || host.history.historyIssues[key] != nil {
                items.append(WorkspaceSidebarItem(id: "more:" + key, kind: .more,
                    title: host.history.historyIssues[key] == nil ? "Show more" : "Retry history", help: host.history.historyIssues[key] ?? "Show ten more conversations", nested: projectID != nil))
            }
        }

        func localSection(_ title: String, key: String, filter: (ThreadPresentation) -> Bool) {
            var records = (state.threadPresentations ?? [:]).filter { filter($0.value) }.map { ($0.key, $0.value) }
            var included = Set(records.map(\.0))
            for workspace in state.workspaces where !workspace.isLanding && included.insert(workspace.threadKey).inserted {
                var entry = state.presentation(for: workspace.threadKey); entry.lastVisitedAt = workspace.lastViewedAt
                if filter(entry) { records.append((workspace.threadKey, entry)) }
            }
            func date(_ entry: ThreadPresentation) -> Date {
                (key == "pinned" ? entry.pinnedAt : key == "archived" ? entry.archivedAt : entry.lastVisitedAt) ?? .distantPast
            }
            records.sort { date($0.1) == date($1.1) ? $0.0 < $1.0 : date($0.1) > date($1.1) }
            guard !records.isEmpty else { return }
            items.append(WorkspaceSidebarItem(id: "section:" + key, kind: .section, title: title))
            for (identity, entry) in records.prefix(sectionLimits[key] ?? 5) {
                let workspace = selectedWorkspace?.threadKey == identity ? selectedWorkspace : workspaceByKey[identity]
                let record = workspace?.catalogMetadata.map { ConversationCatalogRecord(metadata: $0, projectID: workspace?.projectID, localAlias: workspace?.customTitle == true ? workspace?.title : nil) } ?? entry.conversation
                let id = key + ":" + identity
                if let record { sidebarRecords[id] = record }
                if let workspace { sidebarWorkspaceIDs[id] = workspace.id }
                guard let title = workspace?.displayTitle ?? record?.displayTitle else { continue }
                items.append(WorkspaceSidebarItem(id: id, kind: .conversation, title: title,
                    image: SpookkyStyle.toolImage(workspace?.displayProvider ?? record?.id.provider ?? .shell),
                    help: title + "\n" + (workspace?.directory ?? record?.metadata.directory ?? ""),
                    selected: workspace?.id == state.selectedWorkspaceID && selectedSidebarOccurrence == id, activity: workspace?.activityState))
            }
            if records.count > (sectionLimits[key] ?? 5) { items.append(WorkspaceSidebarItem(id: "more:" + key, kind: .more, title: "Show more")) }
        }
        if showingArchived {
            localSection("Archived", key: "archived", filter: { $0.archivedAt != nil })
        } else if !search.isEmpty {
            append(host.history.historyRecords["search"] ?? [], projectID: nil, key: "search")
        } else {
            localSection("Pinned", key: "pinned", filter: { $0.pinnedAt != nil && $0.archivedAt == nil })
            items.append(WorkspaceSidebarItem(id: "section:projects", kind: .section, title: "Projects"))
            for project in state.projects {
                installProjectAvatar(project)
                items.append(WorkspaceSidebarItem(id: "project:" + project.id.uuidString, kind: .project, title: project.name,
                    image: projectImages[project.id] ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil), help: project.name + "\n" + project.location.path,
                    collapsed: project.isCollapsed == true))
                if project.isCollapsed != true { append(host.history.historyRecords[project.id.uuidString] ?? [], projectID: project.id, key: project.id.uuidString) }
            }
            let unbound = host.history.historyRecords["unbound"] ?? []
            if !unbound.isEmpty || host.history.historyHasMore.contains("unbound") || host.history.historyIssues["unbound"] != nil || state.openWorkspaces.contains(where: { $0.projectID == nil }) {
                items.append(WorkspaceSidebarItem(id: "section:unbound", kind: .section, title: "No project"))
                append(unbound, projectID: nil, key: "unbound")
            }
        }
        for index in items.indices where items[index].kind == .conversation {
            guard let key = sidebarThreadKey(items[index].id) else { continue }
            let record = sidebarRecords[items[index].id]
            let workspace = workspaceByKey[key]
            let presentation = state.presentation(for: key)
            items[index].pinned = presentation.pinnedAt != nil; items[index].archived = presentation.archivedAt != nil
            items[index].provider = workspace?.displayProvider ?? record?.id.provider
            items[index].updatedAt = workspace?.primaryTerminal?.activity.flatMap { $0.lastEventAt > 0 ? Date(timeIntervalSince1970: $0.lastEventAt) : nil } ?? record?.metadata.updatedAt
            let projectID = workspace?.projectID ?? record?.projectID
            items[index].associationMessage = workspace?.currentProjectAssociation.flatMap { $0.message.isEmpty ? nil : String($0.message.prefix(512)) }
            items[index].projectName = state.projects.first { $0.id == projectID }?.name
            items[index].checkout = sidebarGit[key]?.checkout; items[index].pullRequest = sidebarGit[key]?.pr
            items[index].help += "\n" + [items[index].provider?.displayName, items[index].pullRequest?.label,
                items[index].checkout?.linkedWorktree == true ? "Linked worktree" : nil, items[index].checkout?.branch].compactMap { $0 }.joined(separator: " · ")
        }
        host.conversationSidebar.update(items: items, collapsed: false)
    }
    func sidebarThreadKey(_ id: String) -> String? {
        guard let host else { return nil }
        if let record = sidebarRecords[id] { return record.id.threadKey }
        if let workspaceID = sidebarWorkspaceIDs[id] { return host.store.state.workspaces.first { $0.id == workspaceID }?.threadKey }
        return host.store.state.workspaces.first { $0.threadKey == id }?.threadKey
    }
    func refreshSidebarGit() {
        guard let host else { return }
        guard let window = host.window, NSApp.isActive, window.isVisible, window.occlusionState.contains(.visible), !host.store.state.sidebarCollapsed else {
            if sidebarGitTask != nil {
                sidebarGitTask?.cancel()
                let service = sidebarPRService; Task { await service.cancelPending() }
            }
            if sidebarGitTimer != nil { sidebarGitTimer?.invalidate(); sidebarGitTimer = nil }
            return
        }
        if sidebarGitTimer == nil {
            sidebarGitTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshSidebarGit() }
            }
        }
        guard sidebarGitTask == nil else { return }
        struct Job: Sendable {
            let key: String
            let workspaceID: UUID?
            let bindingID: UUID?
            let directory: String?
            let association: ThreadPullRequest?
        }
        var keys = Set<String>()
        let jobs = sidebarVisibleItems.compactMap { item -> Job? in
            guard let key = sidebarThreadKey(item.id), keys.insert(key).inserted,
                  sidebarGit[key].map({ Date().timeIntervalSince($0.date) >= 60 }) ?? true else { return nil }
            let workspace = host.store.state.workspaces.first { $0.threadKey == key && $0.primaryTerminal?.binding != nil && $0.primaryTerminal?.status == .running }
            let association = host.store.state.presentation(for: key).pullRequest
            guard workspace != nil || association != nil else { return nil }
            return Job(key: key, workspaceID: workspace?.id, bindingID: workspace?.primaryTerminal?.binding?.id,
                directory: workspace?.directory, association: association)
        }
        guard !jobs.isEmpty else { return }
        let generation = UUID(); sidebarGitGeneration = generation
        let service = sidebarPRService
        sidebarGitTask = Task { [weak self, weak host] in
            await withTaskGroup(of: (Job, SidebarCheckoutInfo?, PullRequestStatus?, Bool).self) { group in
                for job in jobs.prefix(128) {
                    group.addTask {
                        let git = GitRepository(executor: NativeGitExecutor(timeout: 10, outputLimit: 131_072))
                        let checkout = if let directory = job.directory { try? await git.sidebarCheckout(directory) } else { nil as SidebarCheckoutInfo? }
                        let status: PullRequestStatus?
                        var invalidAssociation = false
                        if let checkout {
                            if let known = job.association, known.repository == checkout.repository, known.branch == checkout.branch {
                                let previous = await service.status(association: known)
                                if let previous, !previous.matchesLiveCheckout(checkout) {
                                    invalidAssociation = true; status = await service.status(checkout: checkout)
                                } else { status = previous }
                            } else { invalidAssociation = job.association != nil; status = await service.status(checkout: checkout) }
                            if let directory = job.directory, (try? await git.sidebarCheckout(directory)) != checkout { return (job, nil, nil, false) }
                        } else if let known = job.association, job.directory == nil {
                            let fetched = await service.status(association: known)
                            let observed = SidebarCheckoutInfo(repository: known.repository, branch: known.branch,
                                headCommit: known.headCommit, linkedWorktree: false)
                            status = fetched?.matchesLiveCheckout(observed) == true ? fetched : nil
                        }
                        else { status = nil }
                        return (job, checkout, status, invalidAssociation)
                    }
                }
                for await (job, checkout, pr, invalidAssociation) in group {
                    guard !Task.isCancelled, let self, let host, self.sidebarGitGeneration == generation,
                          self.sidebarVisibleItems.contains(where: { self.sidebarThreadKey($0.id) == job.key }),
                          host.window.isVisible, NSApp.isActive else { continue }
                    if let id = job.workspaceID {
                        guard let workspace = host.store.state.workspaces.first(where: { $0.id == id }),
                              workspace.threadKey == job.key, workspace.primaryTerminal?.binding?.id == job.bindingID,
                              workspace.directory == job.directory else { continue }
                    }
                    self.sidebarGit[job.key] = (checkout, pr, Date())
                    if let association = pr?.association, host.store.state.presentation(for: job.key).pullRequest != association {
                        host.store.update(debounced: true) { $0.editThread(job.key) { $0.pullRequest = association } }
                    } else if invalidAssociation {
                        host.store.update(debounced: true) { $0.editThread(job.key) { $0.pullRequest = nil } }
                    }
                    while self.sidebarGit.count > 128, let oldest = self.sidebarGit.min(by: { $0.value.date < $1.value.date })?.key { self.sidebarGit[oldest] = nil }
                    host.chromeRevision = ""; host.renderChrome()
                }
            }
            if let self, self.sidebarGitGeneration == generation { self.sidebarGitTask = nil; self.refreshSidebarGit() }
        }
    }
    func activateSidebarItem(_ value: String) {
        guard let host else { return }
        if !value.hasPrefix("project:") && !value.hasPrefix("more:") { selectedSidebarOccurrence = value }
        if value.hasPrefix("project:"), let id = UUID(uuidString: String(value.dropFirst(8))) {
            if host.store.state.projects.first(where: { $0.id == id })?.isCollapsed != true {
                let key = id.uuidString, records = host.history.historyRecords[id.uuidString] ?? []
                host.history.historyPageLimits[key] = 5
                host.history.historyRecords[key] = Array(records.prefix(5))
                host.history.historyCursors[key] = nil
                if records.count > 5 { host.history.historyHasMore.insert(key) }
            }
            host.store.update { $0.toggleProjectCollapsed(id) }
            host.history.requestCatalogRefresh(force: true)
        } else if value.hasPrefix("more:") { host.history.showMoreHistory(String(value.dropFirst(5))) }
        else if let id = sidebarWorkspaceIDs[value] { host.sessionLaunch.openConversationWorkspace(id) }
        else if let record = sidebarRecords[value] { host.sessionLaunch.openHistoryRecord(record) }
        else if value.hasPrefix("workspace:"), let id = UUID(uuidString: String(value.dropFirst(10))) { host.sessionLaunch.openConversationWorkspace(id) }
    }
    func sidebarContextMenu(_ value: String) -> NSMenu? {
        guard let host else { return nil }
        if value.hasPrefix("project:"), let id = UUID(uuidString: String(value.dropFirst(8))) {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("New chat") { [weak self] in self?.host?.newProjectWorkspace(id) })
            menu.addItem(ClosureMenuItem("Refresh conversations") { [weak self] in self?.host?.requestCatalogRefresh(force: true) })
            menu.addItem(ClosureMenuItem("Remove project") { [weak host] in
                guard let host else { return }
                host.store.update { $0.removeProject(id) }
                Task {
                    do { try await host.history.historyCatalog.removeProject(id); host.history.requestCatalogRefresh(force: true) }
                    catch { host.history.historyIssues["unbound"] = error.localizedDescription; host.chromeRevision = ""; host.render() }
                }
            })
            return menu
        }
        if let id = sidebarWorkspaceIDs[value] { return workspaceContextMenu(id) }
        if let record = sidebarRecords[value] {
            if let workspace = host.store.state.workspace(for: record.id) { return workspaceContextMenu(workspace.id) }
            let menu = NSMenu()
            addThreadActions(menu, key: record.id.threadKey, record: record)
            menu.addItem(ClosureMenuItem("Go to conversation") { [weak self] in self?.host?.sessionLaunch.openHistoryRecord(record) })
            menu.addItem(ClosureMenuItem("Rename in Spookky…") { [weak self] in self?.renameHistoryRecord(record) })
            return menu
        }
        if value.hasPrefix("workspace:"), let id = UUID(uuidString: String(value.dropFirst(10))) { return workspaceContextMenu(id) }
        return nil
    }
    func workspaceContextMenu(_ id: UUID) -> NSMenu {
        guard let host else { return NSMenu() }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Rename…") { [weak self] in self?.host?.rename(workspaceID: id) })
        if let workspace = host.store.state.workspaces.first(where: { $0.id == id }) {
            addThreadActions(menu, key: workspace.threadKey)
            let unread = workspace.primaryTerminal?.activity?.unread == true
            menu.addItem(ClosureMenuItem(unread ? "Mark read" : "Mark unread") { [weak self] in self?.host?.changeAgentAttention( workspace.tabs.map(\.id), action: unread ? "read" : "unread") })
            menu.addItem(.separator()); host.addContinuationAction(menu, workspaceID: id)
            if workspace.primaryTerminal?.binding != nil && workspace.displayProvider != .shell {
                menu.addItem(ClosureMenuItem("Stop primary terminal…") { [weak self] in self?.host?.stopPrimaryAgent(id) })
            }
        }
        return menu
    }
    func renameHistoryRecord(_ record: ConversationCatalogRecord) {
        guard let host else { return }
        presentThreadName(record.displayTitle) { [weak host] name in
            guard let host else { return }
            Task {
                do {
                    try await host.history.historyCatalog.rename(record.id, alias: name)
                    if let updated = try await host.history.historyCatalog.record(record.id) { host.store.update { $0.rememberThread(updated) } }
                    host.history.requestCatalogRefresh(force: true)
                } catch { host.alert("Could not rename thread", error.localizedDescription) }
            }
        }
    }
    func presentThreadName(_ current: String, save: @escaping (String) -> Void) {
        guard let host else { return }
        guard host.window.attachedSheet == nil else { return }
        let panel = ChromeAlert(); panel.messageText = "Rename in Spookky"
        let field = ChromeTextField(string: current); field.frame = NSRect(x: 0, y: 0, width: SpookkyStyle.points(320), height: SpookkyStyle.controlHeight)
        field.setAccessibilityLabel("Thread name")
        panel.accessoryView = field; panel.window.initialFirstResponder = field
        panel.addButton(withTitle: "Save"); panel.addButton(withTitle: "Cancel")
        panel.beginSheetModal(for: host.window) { result in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if result == .alertFirstButtonReturn, !name.isEmpty { save(name) }
        }
    }
    func addThreadActions(_ menu: NSMenu, key: String, record: ConversationCatalogRecord? = nil) {
        guard let host else { return }
        let presentation = host.store.state.presentation(for: key)
        if let association = sidebarGit[key]?.pr?.association ?? presentation.pullRequest, association.isValid {
            menu.addItem(ClosureMenuItem("Open PR #" + String(association.number)) { NSWorkspace.shared.open(association.url) })
        }
        menu.addItem(ClosureMenuItem(presentation.pinnedAt == nil ? "Pin" : "Unpin") { [weak self] in
            self?.store.update { if let record { $0.rememberThread(record) }; $0.editThread(key) { $0.pinnedAt = presentation.pinnedAt == nil ? Date() : nil } }
            self?.host?.chromeRevision = ""; self?.host?.render()
        })
        let move = NSMenuItem(title: "Move to project", action: nil, keyEquivalent: ""), projects = NSMenu()
        for (id, name) in [(nil as UUID?, "No project")] + host.store.state.projects.map({ (Optional($0.id), $0.name) }) {
            projects.addItem(ClosureMenuItem(name) { [weak self] in
                self?.store.update { if let record { $0.rememberThread(record) }; $0.editThread(key) { $0.hasProjectOverride = true; $0.projectOverride = id } }
                self?.host?.requestCatalogRefresh(force: true)
            })
        }
        move.submenu = projects; menu.addItem(move)
        menu.addItem(ClosureMenuItem(presentation.archivedAt == nil ? "Archive" : "Unarchive") { [weak host] in
            guard let host else { return }
            if presentation.archivedAt == nil && host.store.state.selected?.threadKey == key { host.sessionLaunch.cancelLaunchPreflight() }
            host.store.update { if let record { $0.rememberThread(record) }; $0.editThread(key) { $0.archivedAt = presentation.archivedAt == nil ? Date() : nil } }
            host.chromeRevision = ""; host.render(); host.history.requestCatalogRefresh(force: false)
        })
    }
}
