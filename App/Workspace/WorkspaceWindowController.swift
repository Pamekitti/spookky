import AppKit
import Darwin
import SpookkyCore
import SpookkyFiles
import SpookkyRuntime
import SpookkyWorkspace
import SpookkyGit

@MainActor final class WorkspaceWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation, NSSearchFieldDelegate {
    private(set) var window: WorkspaceNativeWindow!
    lazy var history = WorkspaceHistoryController(host: self)
    lazy var sidebar = WorkspaceSidebarCoordinator(host: self)
    lazy var sessionLaunch = WorkspaceLaunchController(host: self)
    let store: WorkspaceStore
    let services = AppServices()
    let locations: LocationCoordinator
    var repositoryRefreshTask: Task<Void, Never>?
    var repositorySnapshots: [UUID: RepositorySnapshot] = [:]
    var repositoryGenerations: [UUID: UUID] = [:]
    var projectCreation: ProjectCreationController?
    let avatarCache: GitHubAvatarCache
    let sessionCatalog: any SessionCatalogReading
    let associationResolver = ProjectAssociationResolver()
    let savedConversationResolver: any ExecutableResolver
    let conversationSidebar = WorkspaceSidebarView(frame: .zero)
    let historySearch = ChromeSearchField()
    let launches: LaunchCoordinator
    let surfaces: TerminalSurfaceManager
    lazy var projectAssociations = ProjectAssociationCoordinator(store: store)
#if SPOOKKY_HARNESS
    let diagnostics: WorkspaceDiagnostics?
#endif
    let rail = NSStackView()
    let tabs = NSStackView()
    let body = NSView()
    let supportingTerminal = NSView()
    lazy var workspaceLayout = SupportingWorkspaceView(primary: body)
    var supportingContentHost: (any SupportingContentHost)? { didSet { supportContentKey = ""; render() } }
    var supportContentKey = ""

    lazy var files = FileWorkspaceController(store: store, terminal: NSView()) { [weak self] in
        guard let self, let id = store.state.selectedTab?.id else { return }
        if let surface = surfaces.view(id) { window.makeFirstResponder(surface) }
        else { composers[id]?.focus() }
    }
    let sidebarToggle = ActionButton("", symbol: "sidebar.left", help: "Collapse workspace sidebar · ⌘B", action: {})
    let tabOverflow = ActionButton("", symbol: "chevron.down", help: "All tabs", action: {})
    let header = WorkspaceHeaderView()
    var toggleLeading: NSLayoutConstraint!
    var navigationLeading: NSLayoutConstraint!
    var tabsLeading: NSLayoutConstraint!
    var tabsWidth: NSLayoutConstraint!
    var supportHeaderLeading: NSLayoutConstraint!
    var workspaceBottom: NSLayoutConstraint!
    var overflowWidth: NSLayoutConstraint!
    var changesWidth: NSLayoutConstraint!
    var compactHeader = false
    var updatingHeader = false
    let cancelLocation = ActionButton("Cancel operation", action: {})
    let warning = SpookkyStyle.label( "")
    let railScroll = NSScrollView()
    let tabScroll = TabStripScrollView()
    let sidebarDivider = FileDivider()
    var railWidth: NSLayoutConstraint!
    var composers: [UUID: LaunchComposerView] = [:]
    let promptImageDirectory: URL
    var contentKey = ""
    var navigation: [UUID] = []
    var navigationIndex = -1
    var navigating = false
    var filePicker: WorkspaceFilePicker?
    var detailsPopover: NSPopover?
    var startPages: [UUID: SupportingStartPage] = [:]
    let navigationBack = ActionButton("", symbol: "chevron.left", help: "Previous thread", action: {})
    let navigationForward = ActionButton("", symbol: "chevron.right", help: "Next thread", action: {})
    let threadDetails = ActionButton("", symbol: "slider.horizontal.3", help: "Thread details", action: {})
    let threadActions = ActionButton("", symbol: "ellipsis", help: "Thread actions", action: {})
    let threadChanges = ActionButton("", help: "View changes", action: {})
    let supportingToggle = ActionButton("", symbol: "sidebar.right", help: "Show side panel", action: {})

    var renderTask: Task<Void, Never>?
    var closing = Set<UUID>()
    let runtimeEvents: RuntimeEventMonitor
    var observationTask: Task<Void, Never>?
    var observationRequested = false
    var continuationTask: Task<Void, Never>?
    var continuationMetadata: ((ConversationID) -> ConversationMetadata?)? {
        didSet { sessionLaunch.continuations.metadata = continuationMetadata }
    }
    var wakeObserver: NSObjectProtocol?
    var displayOptionsObserver: NSObjectProtocol?
    var chromeRevision = ""
    var sidebarRevision = ""
    var tabRevision = ""
    var tabPairs: [UUID: WorkspaceTabView] = [:]
    var fullscreenTransition = false
    var announcedError: String?
    var renameEditor: InlineRenameEditor?
    var paneHeaders: [UUID: ChromeStackView] = [:]
    var paneTitles: [UUID: NSTextField] = [:]
    var agentHeaderLabels: [UUID: NSTextField] = [:]
    var activityReceiver: AgentActivityReceiver?
    let agentNotifications = AgentNotifications()
    let activityRoot: URL
    var knownActivityBindings = Set<UUID>()
    var knownActivityTabs = Set<UUID>()
    var acknowledgmentTasks: [UUID: Task<Void, Never>] = [:]
    var agentPreferencesTask: Task<Void, Never>?
    let backgroundFixture: Bool
#if SPOOKKY_HARNESS
    var fixtureCloseRequests: [[String: String]] = []
    var fixtureQuitRequests: [[String: String]] = []
#endif

    func controlTextDidChange(_ notification: Notification) { history.controlTextDidChange(notification) }
    func openConversationWorkspace(_ id: UUID) { sessionLaunch.openConversationWorkspace(id) }
    func requestCatalogRefresh(force: Bool) { history.requestCatalogRefresh(force: force) }
    func catalogProjectSignature() -> String { history.catalogProjectSignature() }
    var historyRefreshTask: Task<Void, Never>? { history.historyRefreshTask }
    init(root: URL, initialStore: WorkspaceStore? = nil,
         resolver: any ExecutableResolver = CLIResolver(), backgroundFixture: Bool = false,
         catalog: (any SessionCatalogReading)? = nil, dataDirectory: URL? = nil) throws {
        let paths = AppPaths(bundleID: Bundle.main.bundleIdentifier, home: FileManager.default.homeDirectoryForCurrentUser, userID: getuid())
        promptImageDirectory = (dataDirectory ?? paths.data).appendingPathComponent("PromptImages")
        avatarCache = GitHubAvatarCache(directory: (dataDirectory ?? paths.data).appendingPathComponent("AvatarCache"))
        self.backgroundFixture = backgroundFixture
        let fixture = backgroundFixture || ApplicationArguments.values.contains { $0.hasPrefix("--workspace-benchmark") }
#if SPOOKKY_HARNESS
        let historyFixture = ApplicationArguments.values.contains("--workspace-benchmark-history")
        sessionCatalog = catalog ?? (historyFixture ? SyntheticHistoryCatalog(root: root) as any SessionCatalogReading : (fixture ? EmptySessionCatalog() as any SessionCatalogReading : SessionCatalog()))
        savedConversationResolver = historyFixture ? HistoryFixtureResolver(root: root) : resolver
#else
        sessionCatalog = catalog ?? SessionCatalog()
        savedConversationResolver = resolver
#endif
        activityRoot = root
        let store = initialStore ?? WorkspaceStore()
        self.store = store
        try PrivateFiles.directory(root)
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("spookky-launch").path
        runtimeEvents = try RuntimeEventMonitor(root: root)
        let tmux = try PackagedRuntime.tmux()
        let actionLog = ApplicationArguments.values.contains("--workspace-benchmark-continuity") ? root.appendingPathComponent("runtime-actions.json") : nil
        let baseRuntime = try TmuxRuntime(executable: tmux, helper: helper, root: root, eventFile: runtimeEvents.eventFile, actionLog: actionLog)
        let runtime: any SessionViewportRuntime
#if SPOOKKY_HARNESS
        if (ApplicationArguments.values.contains("--workspace-benchmark-races") || ApplicationArguments.values.contains("--workspace-benchmark-sidebar")), ApplicationArguments.values.contains("--workspace-benchmark-count"),
           root.path.hasPrefix("/tmp/spookky-m1-"), ProcessInfo.processInfo.environment["SPOOKKY_M1_DATA"] != nil {
            runtime = WorkspaceViewportFixtureRuntime(baseRuntime)
        } else { runtime = baseRuntime }
#else
        runtime = baseRuntime
#endif
        locations = LocationCoordinator(store: store, runtime: runtime, operationRoot: root.appendingPathComponent("git-operations"))
        let clipboard = ApplicationArguments.values.contains("--workspace-benchmark-selection")
            ? NSPasteboard(name: NSPasteboard.Name("dev.spookky.selection-fixture." + root.lastPathComponent)) : .general
        let engine = try GhosttyEngine(root: root, clipboard: clipboard)
        launches = LaunchCoordinator(store: store, runtime: runtime,
            resolver: AgentActivityResolver(base: savedConversationResolver, root: root, helper: helper))
        surfaces = TerminalSurfaceManager(engine: engine, runtime: runtime, executable: tmux, root: root,
            appearanceFile: ApplicationArguments.values.contains("--workspace-benchmark-display") ? root.appendingPathComponent("live-appearance-config").path : nil)
#if SPOOKKY_HARNESS
        diagnostics = WorkspaceDiagnostics(root: root)
#endif
        super.init()
        store.update { $0.restoreAgentActivity() }
        continuationMetadata = { [weak self] id in self?.store.state.workspace(for: id)?.catalogMetadata }
        services.persistsDisplayPreferences = !fixture
        if fixture { services.displayPreferences = DisplayPreferences() }
        DisplayMetrics.preferences = DisplayPreferences()
        buildWindow(); buildMenu()
        services.displayPreferencesDidChange = { [weak self] preferences in
            guard let self else { return }
            let old = DisplayMetrics.preferences
            let ratio = preferences.zoom / old.zoom
            if ratio != 1 {
                DisplayMetrics.apply(preferences, to: window.contentView)
                chromeRevision = ""; tabRevision = ""
                conversationSidebar.displayChanged(); files.displayChanged(ratio: ratio)
            } else { DisplayMetrics.preferences = preferences }
            updateHeaderGeometry(); window.contentView?.needsLayout = true
            if ratio != 1 { render() }
            if ratio != 1 || preferences.terminalFontAdjustment != old.terminalFontAdjustment { surfaces.refreshAppearance() }
        }

        services.displayPreferencesDidChange?(services.displayPreferences)
        surfaces.onAppearanceStatus = { [weak services] in services?.terminalAppearanceMessage = $0 }
        if !fixture { surfaces.startFollowingAppearance() }
        supportingContentHost = BrowserArtifactContentHost(identity: (Bundle.main.bundleIdentifier ?? "dev.spookky") + root.path)
        services.activityPreferencesDidChange = { [weak self] preferences in self?.saveAgentPreferences(preferences) }
        services.testAgentNotification = { [weak self] in await self?.agentNotifications.test() ?? "Notifications are unavailable." }
        saveAgentPreferences(services.agentPreferences)
        startActivityMonitoring()
        agentNotifications.onFocus = { [weak self] id in
            guard let self, let workspace = store.state.workspace(containing: id) else { return }
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            selectWorkspace(workspace.id); selectTab(id); focusSelectedContent()
        }
        agentNotifications.watchFocus { [weak self] in self?.refreshAgentAttention(clearManual: true) }
        services.prepareForUpdate = { [weak self] in
            guard let self else { throw LaunchError.invalid("Workspaces are unavailable.") }
            try await self.prepareForUpdate()
        }
#if SPOOKKY_HARNESS
        diagnostics?.visibility = { [weak self] in self?.window.occlusionState.contains(.visible) == true }
#endif
        history.historyProjectSignature = history.catalogProjectSignature()
        historySearch.placeholderString = "Search"; historySearch.delegate = self
        historySearch.sendsSearchStringImmediately = true
        historySearch.setAccessibilityLabel("Search all saved conversations")
        store.onChange = { [weak self] in
            guard let self else { return }; render(); refreshAgentAttention()
            if history.historyProjectSignature != history.catalogProjectSignature() { history.requestCatalogRefresh(force: false) }
        }
#if SPOOKKY_HARNESS
        if ApplicationArguments.values.contains("--workspace-benchmark-timing") || ApplicationArguments.values.contains("--workspace-benchmark-restoring") {
        diagnostics?.historyMarker = { [weak self] in
            guard let self, let id = self.store.state.selectedTab?.id else { return nil }
            return self.surfaces.fixtureHistoryMarker(id)
        }
        }
#endif
        surfaces.onExit = { [weak self] id in
            guard let self else { return }
            Task { await self.launches.reconcile(id); self.handleClientExit(id) }
        }
        surfaces.onFocus = { [weak self] id in
            guard let self, self.store.state.selectedTab?.id != id else { return }
            self.store.update { $0.selectTab(id) }
        }
        surfaces.onOpenURL = { [weak self] id, url in
            guard let self, let workspace = self.store.state.workspace(containing: id),
                  let target = ConversationLinks.target(for: url, scopePath: workspace.anchor?.scopePath ?? workspace.directory) else { return false }
            let title = url.isFileURL ? url.lastPathComponent : (url.host ?? "Browser")
            self.store.update { $0.openSupport(target, title: title, workspaceID: workspace.id) }
            return true
        }
        surfaces.onViewport = { [weak self] id, viewport in self?.store.update { $0.setViewport(viewport, tabID: id) } }
        surfaces.onViewportChanged = { [weak self] _ in self?.refreshAgentAttention() }
        surfaces.onViewportFailure = { [weak self] id, error in
            guard let self, self.store.state.tab(id)?.binding != nil else { return }
            self.store.update { $0.apply(.failure(.unavailable, TabFailure(.observation, error.localizedDescription), clearIntent: false), to: id) }
        }
        if store.state.selected == nil {
            store.update { $0.showLanding(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path) }
        }
        if store.state.windowFrame == nil { window.center() }
        showWindow(); rememberWindowFrame(); render()
#if SPOOKKY_HARNESS
        if let host = supportingContentHost as? BrowserArtifactContentHost {
            try SupportingPreviewFixture.recordRestoration(host: host, state: store.state, root: root)
        }
#endif
        if backgroundFixture && (window.isKeyWindow || window.isMainWindow) {
            throw LaunchError.invalid("Background fixture took native window focus.")
        }
        Task {
            await locations.reconcileAll()
            await refreshSelectedRepository()
            observeRuntimeEvent()
            history.requestCatalogRefresh(force: false)
        }
        history.historyWatcher.onChange = { [weak self] in self?.history.requestCatalogRefresh(force: true) }
        history.historyWatcher.start(roots: sessionCatalog.historySourceRoots)
        history.historyActivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.history.requestCatalogRefresh(force: true) }
        }
        runtimeEvents.onChange = { [weak self] in self?.observeRuntimeEvent() }
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.conversationSidebar.needsDisplay = true
                }
            }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.observeRuntimeEvent() }
            }
    }
    func startActivityMonitoring() {
        guard activityReceiver == nil else { return }
        activityReceiver = try? AgentActivityReceiver(root: activityRoot) { [weak self] event in
            Task { @MainActor [weak self] in self?.receiveAgentEvent(event) }
        }
    }
    func saveAgentPreferences(_ preferences: AgentNotificationPreferences) {
        let destination = activityRoot.appendingPathComponent("agent-preferences.json")
        let previous = agentPreferencesTask
        agentPreferencesTask = Task {
            await previous?.value
            try? await Task.detached { try PrivateFiles.write(preferences, to: destination) }.value
        }
        for tab in store.state.workspaces.flatMap(\.tabs) { agentNotifications.clear(tab.id) }
        store.update(debounced: true) { state in
            for provider in [SessionTool.codex, .claude] where !preferences.enabled(provider) { state.suspendAgentMonitoring(provider) }
            if !preferences.previews { state.clearAgentPreviews() }
        }
        if window != nil { chromeRevision = ""; renderChrome(); refreshAgentAttention() }
    }
    func agentTargetVisible(_ id: UUID) -> Bool {
        guard NSApp.isActive, window.isKeyWindow, window.occlusionState.contains(.visible),
              store.state.visibleTabIDs.contains(id), let surface = surfaces.view(id) else { return false }
        return surface.window === window && !surface.isHiddenOrHasHiddenAncestor
    }
    func refreshAgentAttention(clearManual: Bool = false, retryCount: Int = 0) {
        let tabs = Set(store.state.workspaces.flatMap(\.tabs).map(\.id))
        for id in knownActivityTabs.subtracting(tabs) { agentNotifications.clear(id) }
        knownActivityTabs = tabs
        for id in store.state.visibleTabIDs {
            guard acknowledgmentTasks[id] == nil else { continue }
            guard agentTargetVisible(id), let activity = store.state.tab(id)?.activity else { continue }
            guard (activity.completionID != nil && activity.completionID != activity.seenCompletionID) || (clearManual && activity.manualUnread) else { continue }
            let receipt = AgentCompletionReceipt(activity)
            let observedView = surfaces.view(id), viewportRevision = observedView?.viewportRevision
            acknowledgmentTasks[id] = Task { [weak self] in
                guard let self else { return }
                var atBottom: Bool?
                var acknowledged = false
                defer {
                    acknowledgmentTasks[id] = nil
                    if let latest = store.state.tab(id)?.activity, latest.unread {
                        let changed = AgentCompletionReceipt(latest) != receipt || surfaces.view(id) !== observedView ||
                            observedView?.viewportRevision != viewportRevision
                        if changed { refreshAgentAttention(clearManual: clearManual) }
                        else if !Task.isCancelled, !acknowledged, atBottom != true, retryCount < 3,
                                observedView?.terminalViewportAtBottom == true, agentTargetVisible(id) {
                            Task { [weak self] in
                                try? await Task.sleep(for: .milliseconds(80))
                                self?.refreshAgentAttention(clearManual: clearManual, retryCount: retryCount + 1)
                            }
                        }
                    }
                }
                atBottom = try? await surfaces.viewportAtBottom(id)
                guard !Task.isCancelled, agentTargetVisible(id) else { return }
                store.update(debounced: true) { acknowledged = $0.acknowledgeAgent(id, receipt: receipt, viewportAtBottom: atBottom) }
                if acknowledged { agentNotifications.clear(id) }
            }
        }
        agentNotifications.updateBadge(store.state, preferences: services.agentPreferences)
        let bindings = Set(store.state.workspaces.flatMap(\.tabs).compactMap { $0.binding?.id ?? $0.launch?.operationID })
        let removed = knownActivityBindings.subtracting(bindings)
        knownActivityBindings = bindings
        if !removed.isEmpty {
            let root = activityRoot
            Task { await Task.detached {
                for id in removed {
                    let active = root.appendingPathComponent("agent-active-" + id.uuidString + ".json")
                    if let invocation = try? AgentIntegration.read(AgentInvocation.self, path: active.path) {
                        try? FileManager.default.removeItem(atPath: invocation.path)
                    }
                    for path in [active, root.appendingPathComponent("agent-terminal-" + id.uuidString + ".json")] {
                        try? FileManager.default.removeItem(at: path)
                    }
                }
            }.value }
        }
    }
    func receiveAgentEvent(_ event: AgentEvent) {
        guard services.agentPreferences.enabled(event.provider) else { return }
        var event = event
        if !services.agentPreferences.previews { event.preview = nil }
        let previousTab = store.state.workspaces.flatMap(\.tabs).first { $0.binding?.id == event.bindingID || $0.launch?.operationID == event.bindingID }
        let old = previousTab?.activity
        let followTerminal = window.isKeyWindow && previousTab.flatMap { surfaces.view($0.id) }.map { window.firstResponder === $0 } == true
        var accepted: UUID?
        store.update(debounced: true) { state in accepted = state.recordAgentEvent(event, followTerminal: followTerminal) }
        guard let id = accepted, let tab = store.state.tab(id), let activity = tab.activity,
              let workspace = store.state.workspace(containing: id), event.childID == nil else { return }
        projectAssociations.observe(event, tabID: id)
        if activity.sessionID != old?.sessionID || activity.provider != old?.provider { history.requestCatalogRefresh(force: false) }
        if event.kind == .attached { agentNotifications.requestPermission() }
        let next = activity.displayState
        if !next.needsAttention { agentNotifications.clear(id); return }
        guard next != old?.displayState || (next == .finished && activity.completionID != old?.completionID) else { return }
        let invocation = activity.invocationID
        let preferences = services.agentPreferences
        agentNotifications.schedule(tabID: id, state: next, workspace: workspace.displayTitle, provider: activity.provider.displayName,
                                    preview: activity.preview, preferences: preferences) { [weak self] in
            guard let self, let current = store.state.tab(id)?.activity,
                  services.agentPreferences.enabled(current.provider), current.invocationID == invocation,
                  current.displayState == next else { return false }
            return !preferences.suppressVisible || !agentTargetVisible(id)
        }
    }
    func changeAgentAttention(_ ids: [UUID], action: String) {
        store.update(debounced: true) { state in
            for id in ids {
                if action == "unread" { state.markAgentUnread(id) }
                else if action == "read" { state.acknowledgeAgent(id) }
                else { state.resetAgent(id) }
            }
        }
        if action != "unread" { for id in ids { agentNotifications.clear(id) } }
    }
    func addAgentActions(_ menu: NSMenu, ids: [UUID]) {
        guard ids.contains(where: { store.state.tab($0)?.activity != nil }) else { return }
        menu.addItem(.separator())
        for (title, action) in [("Mark unread", "unread"), ("Mark read", "read"), ("Reset activity status", "reset")] {
            menu.addItem(ClosureMenuItem(title) { [weak self] in self?.changeAgentAttention(ids, action: action) })
        }
    }
    func addContinuationAction(_ menu: NSMenu, workspaceID: UUID) {
        guard (try? sessionLaunch.continuations.capture(workspaceID: workspaceID)) != nil else { return }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Continue elsewhere…") { [weak self] in self?.showContinuation(workspaceID) })
    }
    func showContinuation(_ workspaceID: UUID) {
        guard continuationTask == nil, window.attachedSheet == nil else { return }
        let target: ConversationContinuationTarget
        do { target = try sessionLaunch.continuations.capture(workspaceID: workspaceID) }
        catch { alert("Continuation unavailable", error.localizedDescription); return }
        continuationTask = Task { [weak self] in
            guard let self else { return }
            defer { continuationTask = nil }
            do {
                guard let presentation = try await sessionLaunch.continuations.prepare(target), window.isVisible,
                      window.attachedSheet == nil, sessionLaunch.continuations.isCurrent(target) else { return }
                let previousResponder = window.firstResponder
                let guide = presentation.guide
                let alert = ChromeAlert()
                alert.messageText = "Continue " + target.provider.displayName + " elsewhere"
                alert.informativeText = presentation.capabilities.version + ". Commands target the primary conversation."
                let instructions = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 280))
                instructions.isEditable = false; instructions.isSelectable = true; instructions.isRichText = false
                instructions.isVerticallyResizable = true; instructions.isHorizontallyResizable = false
                instructions.minSize = NSSize(width: 0, height: 280)
                instructions.maxSize = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
                instructions.font = .systemFont(ofSize: SpookkyStyle.points(13))
                instructions.textContainerInset = NSSize(width: 8, height: 8)
                instructions.autoresizingMask = [.width]
                instructions.textContainer?.widthTracksTextView = true
                instructions.textContainer?.containerSize = NSSize(width: 464, height: CGFloat.greatestFiniteMagnitude)
                instructions.string = (["Primary folder\n" + target.directory,
                    presentation.warning, presentation.ownership?.explanation].compactMap { $0 } +
                    ["Desktop\n" + guide.desktop, "Remote Control\n" + guide.remote,
                     "Return to Spookky\n" + guide.returnToTerminal]).joined(separator: "\n\n")
                instructions.setAccessibilityLabel("Primary conversation continuation instructions")
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 280))
                scroll.hasVerticalScroller = true; scroll.documentView = instructions
                alert.accessoryView = scroll
                alert.addButton(withTitle: "Cancel")
                if target.binding != nil { alert.addButton(withTitle: "Reconnect primary") }
                let result = await present(alert)
                guard !Task.isCancelled, window.isVisible else { return }
                if result == .alertSecondButtonReturn {
                    guard sessionLaunch.continuations.isCurrent(target) else { return }
                    await surfaces.captureViewports()
                    guard await sessionLaunch.continuations.reconnect(target, using: launches) else { return }
                    surfaces.release(target.terminalID)
                    store.update {
                        $0.selectWorkspace(target.workspaceID); $0.selectPrimaryContent(workspaceID: target.workspaceID)
                    }
                    guard let reopened = try? sessionLaunch.continuations.capture(workspaceID: target.workspaceID),
                          reopened.terminalID == target.terminalID, reopened.conversationID == target.conversationID,
                          reopened.directory == target.directory, reopened.binding == target.binding else { return }
                    contentKey = ""; render()
                    if let renderTask { await renderTask.value }
                    if sessionLaunch.continuations.isCurrent(reopened) { focusSelectedContent() }
                } else if let view = previousResponder as? NSView, view.window === window {
                    window.makeFirstResponder(view)
                }
            } catch {
                if !Task.isCancelled, window.isVisible, sessionLaunch.continuations.isCurrent(target) {
                    alert("Continuation unavailable", error.localizedDescription)
                }
            }
        }
    }
    func observeRuntimeEvent() {
        observationRequested = true
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self else { return }
            defer { self.observationTask = nil }
            await history.reconcileProviderIdentities()
            while self.observationRequested {
                self.observationRequested = false
                let ids = self.store.state.workspaces.flatMap(\.tabs).filter {
                    ($0.binding != nil || $0.launch != nil) && $0.status != .ended
                }.map(\.id)
                for id in ids {
                    guard !Task.isCancelled else { return }
                    await self.launches.reconcile(id); self.handleClientExit(id)
                }
            }
        }
    }
    isolated deinit {
        sidebar.stop(); history.stop(); sessionLaunch.stop()
        for task in acknowledgmentTasks.values { task.cancel() }
        let ownedSurfaces = surfaces
        Task { @MainActor in ownedSurfaces.stopFollowingAppearance() }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let displayOptionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver) }
        observationTask?.cancel(); continuationTask?.cancel()
    }
    func buildWindow() {
        window = WorkspaceNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Spookky"
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.acceptsUserFocus = !backgroundFixture
        window.ignoresMouseEvents = backgroundFixture
        window.isRestorable = false
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 650, height: 450); window.delegate = self
        if let saved = store.state.windowFrame, saved.width.isFinite, saved.height.isFinite,
           saved.x.isFinite, saved.y.isFinite, saved.width >= 650, saved.height >= 450 {
            let frame = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { window.setFrame(frame, display: false) }
        }
        window.backgroundColor = SpookkyPalette.background
        window.onCommand = { [weak self] in self?.handleCommand($0) ?? false }
        let rootView = WorkspaceRootView(); window.contentView = rootView
        rootView.onAppearance = { [weak self] in self?.render() }
        rootView.onBeforeLayout = { [weak self] in self?.updateHeaderGeometry() }
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.onPointerMove = { [weak self] event in
            guard let self else { return }
            for tab in tabPairs.values { tab.reconcilePointer(at: event.locationInWindow) }
            for tab in workspaceLayout.tabItems { tab.reconcilePointer(at: event.locationInWindow) }
        }
        let content = window.contentView!
        let workspaceBody = workspaceLayout
        files.layout.supportingOnly = true
        workspaceLayout.onSelect = { [weak self] id in self?.store.update { $0.selectSupport(id) }; self?.focusSupportingContent() }
        workspaceLayout.onClose = { [weak self] id in
            guard let self else { return }
            let active = store.state.selected?.support?.selectedTabID == id && workspaceLayout.showsSupportingContent
            store.update { $0.closeSupport(id) }
            if active { focusSupportingContent() }
        }
        workspaceLayout.onAdd = { [weak self] _ in self?.newTab() }
        workspaceLayout.onLayout = { [weak self] layout, fraction in
            guard let self else { return }
            store.update(debounced: fraction != nil) { $0.setSupportingLayout(layout, fraction: fraction) }
            if layout == .fullWidth { focusSupportingContent() }
        }
        workspaceLayout.onGeometryChange = { [weak self] in self?.updateHeaderGeometry() }

        sidebarToggle.handler = { [weak self] in self?.toggleWorkspaceSidebar() }
        tabOverflow.handler = { [weak self] in self?.showTabOverflow() }
        rail.orientation = .vertical; rail.alignment = .leading; rail.spacing = SpookkyStyle.points(4)
        railScroll.contentView = WorkspaceSidebarClipView()
        railScroll.automaticallyAdjustsContentInsets = false; railScroll.contentInsets = .init()
        railScroll.documentView = rail; railScroll.hasVerticalScroller = false; railScroll.hasHorizontalScroller = false
        railScroll.horizontalScrollElasticity = .none; railScroll.verticalScrollElasticity = .none
        railScroll.autohidesScrollers = true
        railScroll.drawsBackground = true; railScroll.backgroundColor = SidebarPalette.background
        tabs.orientation = .horizontal; tabs.spacing = 0; tabs.alignment = .centerY
        tabs.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: SpookkyStyle.points(8))
        tabScroll.documentView = tabs; tabScroll.hasHorizontalScroller = false; tabScroll.autohidesScrollers = true; tabScroll.drawsBackground = false
        tabScroll.automaticallyAdjustsContentInsets = false
        tabScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tabScroll.scrollerStyle = .overlay
        warning.font = .systemFont(ofSize: SpookkyStyle.points(11)); warning.textColor = SpookkyPalette.warning
        warning.isHidden = true
        cancelLocation.isHidden = true
        cancelLocation.handler = { [weak self] in
            guard let self, let selected = store.state.selectedWorkspaceID,
                  let operation = store.state.locations?.operations.first(where: { $0.status == .running && $0.request.workspaceID == selected }) else { return }
            locations.cancel(operation.id)
        }
        for view in [header, railScroll, tabScroll, workspaceLayout.headerView, workspaceBody, sidebarToggle, tabOverflow, sidebarDivider, warning, cancelLocation, navigationBack, navigationForward, threadChanges, supportingToggle] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        rail.translatesAutoresizingMaskIntoConstraints = false; tabs.translatesAutoresizingMaskIntoConstraints = false
        navigationBack.handler = { [weak self] in self?.navigateThread(-1) }
        navigationForward.handler = { [weak self] in self?.navigateThread(1) }
        threadDetails.handler = { [weak self] in self?.showThreadDetails() }
        threadChanges.handler = { [weak self] in self?.showChanges() }
        threadChanges.image = SpookkyStyle.changesImage; threadChanges.imagePosition = .imageOnly
        threadChanges.alignsToBounds = true
        supportingToggle.alignsToBounds = true
        supportingToggle.handler = { [weak self] in self?.toggleSupportingPanel() }
        threadActions.handler = { [weak self] in
            guard let self, let id = store.state.selectedWorkspaceID else { return }
            headerActionsMenu(id).popUp(positioning: nil, at: NSPoint(x: 0, y: threadActions.bounds.minY), in: threadActions)
        }
        sidebarDivider.setAccessibilityLabel("Resize workspace sidebar")
        sidebarDivider.onMove = { [weak self] x in self?.services.changeDisplay { $0.sidebarWidth = Double(x) / $0.zoom } }
        sidebarDivider.onKey = { [weak self] delta in self?.services.changeDisplay { $0.sidebarWidth += delta < 0 ? -16 : 16 } }
        sidebarDivider.onReset = { [weak self] in self?.services.changeDisplay { $0.sidebarWidth = 264 } }
        railWidth = railScroll.widthAnchor.constraint(equalToConstant: SpookkyStyle.sidebarWidth)
        navigationLeading = navigationBack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 92)
        toggleLeading = sidebarToggle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 196).displayScaled()
        tabsLeading = tabScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SpookkyStyle.sidebarWidth)
        tabsWidth = tabScroll.widthAnchor.constraint(equalToConstant: 220).displayScaled()
        supportHeaderLeading = workspaceLayout.headerView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SpookkyStyle.sidebarWidth + 220)
        workspaceBottom = workspaceBody.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        overflowWidth = tabOverflow.widthAnchor.constraint(equalToConstant: 0).displayScaled()
        changesWidth = threadChanges.widthAnchor.constraint(equalToConstant: 28).displayScaled()
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor), header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor), header.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).displayScaled(alreadyScaled: true),
            railScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), railScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            railScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor), railWidth,
            sidebarDivider.centerXAnchor.constraint(equalTo: railScroll.trailingAnchor),
            sidebarDivider.topAnchor.constraint(equalTo: header.bottomAnchor), sidebarDivider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebarDivider.widthAnchor.constraint(equalToConstant: 6),
            rail.widthAnchor.constraint(equalTo: railScroll.widthAnchor), rail.heightAnchor.constraint(equalTo: railScroll.heightAnchor),
            tabsLeading, tabsWidth, supportHeaderLeading,
            workspaceLayout.headerView.trailingAnchor.constraint(equalTo: tabOverflow.leadingAnchor, constant: -4).displayScaled(),
            workspaceLayout.headerView.topAnchor.constraint(equalTo: content.topAnchor),
            workspaceLayout.headerView.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).displayScaled(alreadyScaled: true),
            tabScroll.topAnchor.constraint(equalTo: content.topAnchor), tabScroll.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).displayScaled(alreadyScaled: true),
            tabs.heightAnchor.constraint(equalTo: tabScroll.heightAnchor),
            navigationLeading, toggleLeading, sidebarToggle.topAnchor.constraint(equalTo: content.topAnchor, constant: 6).displayScaled(),
            sidebarToggle.widthAnchor.constraint(equalToConstant: 28).displayScaled(), sidebarToggle.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            supportingToggle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8).displayScaled(),
            threadChanges.trailingAnchor.constraint(equalTo: supportingToggle.leadingAnchor, constant: -4).displayScaled(),
            tabOverflow.trailingAnchor.constraint(equalTo: threadChanges.leadingAnchor, constant: -4).displayScaled(), overflowWidth,
            supportingToggle.widthAnchor.constraint(equalToConstant: 28).displayScaled(), supportingToggle.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            changesWidth, threadChanges.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            threadChanges.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor),
            supportingToggle.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor),
            navigationBack.widthAnchor.constraint(equalToConstant: 28).displayScaled(), navigationBack.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            navigationForward.widthAnchor.constraint(equalToConstant: 28).displayScaled(), navigationForward.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            navigationBack.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor), navigationForward.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor),
            navigationForward.leadingAnchor.constraint(equalTo: navigationBack.trailingAnchor),
            tabOverflow.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor),
            tabOverflow.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            workspaceBody.leadingAnchor.constraint(equalTo: railScroll.trailingAnchor), workspaceBody.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            workspaceBody.topAnchor.constraint(equalTo: tabScroll.bottomAnchor), workspaceBottom,
            warning.leadingAnchor.constraint(equalTo: workspaceBody.leadingAnchor, constant: 12).displayScaled(),
            warning.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8).displayScaled(),
            warning.trailingAnchor.constraint(lessThanOrEqualTo: cancelLocation.leadingAnchor, constant: -8).displayScaled(),
            cancelLocation.trailingAnchor.constraint(equalTo: workspaceBody.trailingAnchor, constant: -12).displayScaled(),
            cancelLocation.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4).displayScaled()
        ])
    }
    func updateHeaderGeometry() {
        guard !updatingHeader, let content = window?.contentView, toggleLeading != nil else { return }
        updatingHeader = true; defer { updatingHeader = false }
        let collapsed = store.state.sidebarCollapsed
        let width = collapsed ? 0 : CGFloat(services.displayPreferences.sidebarPoints(available: content.bounds.width))
        railWidth.constant = width; railScroll.isHidden = collapsed; sidebarDivider.isHidden = collapsed
        window.positionWindowButtons(headerHeight: SpookkyStyle.headerHeight)
        if header.sidebarWidth != width { header.sidebarWidth = width }
        let occupied = window.styleMask.contains(.fullScreen) ? 0 : [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            .filter { !$0.isHidden }.map { content.convert($0.bounds, from: $0).maxX }.max() ?? 0
        navigationLeading.constant = occupied + SpookkyStyle.points(8)
        let leading = max(collapsed ? 0 : width - SpookkyStyle.points(36), occupied + SpookkyStyle.points(72))
        if toggleLeading.constant != leading { toggleLeading.constant = leading }
        let tabStart = max(width, leading + SpookkyStyle.points(36))
        if tabsLeading.constant != tabStart { tabsLeading.constant = tabStart }
        sidebarToggle.toolTip = (collapsed ? "Expand" : "Collapse") + " workspace sidebar · ⌘B"
        sidebarToggle.setAccessibilityLabel(sidebarToggle.toolTip!)
        sidebarToggle.setAccessibilityValue(collapsed ? "Collapsed" : "Expanded")
        let compact = content.bounds.width - width < workspaceLayout.minimumSplitWidth
        if workspaceLayout.compact != compact {
            workspaceLayout.compact = compact; workspaceLayout.needsLayout = true
            DispatchQueue.main.async { [weak self] in self?.renderSupportingContent() }
        }
        if let workspace = store.state.selected, let primary = workspace.primaryTerminalID, let item = tabPairs[primary] {
            let joined = workspace.support?.layout == .fullWidth || compact && workspaceLayout.requestsSplit
            item.isHeading = !joined
            if !joined { item.move(to: tabs) }
            workspaceLayout.setPrimaryItem(item, joined: joined)
            item.selected = !joined || workspace.support?.resolvedFullWidthSelection == .primary
        }
        let expanded = supportingPanelExpanded
        compactHeader = content.bounds.width - tabStart < SpookkyStyle.points(240)
        workspaceLayout.compactHeader = compactHeader
        threadDetails.isHidden = compactHeader
        threadChanges.isHidden = compactHeader
        changesWidth.constant = compactHeader ? 0 : SpookkyStyle.points(28)
        threadActions.isEnabled = compactHeader ? store.state.selected != nil : store.state.selected?.isLanding == false
        threadActions.toolTip = compactHeader ? "Tabs and thread actions" : "Thread actions"
        threadActions.setAccessibilityLabel(threadActions.toolTip!)
        let utilityWidth = [threadChanges, supportingToggle].filter { !$0.isHidden }.reduce(CGFloat.zero) { $0 + $1.intrinsicContentSize.width }
        let headerEnd = content.bounds.width - utilityWidth - SpookkyStyle.points(24)
        let splitStart = width + workspaceLayout.primaryPaneWidth(in: max(0, content.bounds.width - width)) + 5
        let preferredMainWidth = tabs.arrangedSubviews.compactMap { ($0 as? WorkspaceTabView)?.preferredWidth }.reduce(0, +) + tabs.edgeInsets.left + tabs.edgeInsets.right
        func widths(overflow: CGFloat) -> (main: CGFloat, supportStart: CGFloat, support: CGFloat) {
            let available = max(0, headerEnd - tabStart - overflow)
            let main = workspaceLayout.joinsPrimary ? 0 : expanded && workspaceLayout.isSplit ? min(available, max(0, splitStart - tabStart - 5)) :
                min(preferredMainWidth, max(0, available - (expanded ? workspaceLayout.headerControlsWidth : 0)))
            let start = workspaceLayout.joinsPrimary ? tabStart : expanded && workspaceLayout.isSplit ? splitStart : tabStart + main
            return (main, start, max(0, headerEnd - overflow - start))
        }
        let initial = widths(overflow: 0)
        let overflowing = expanded && ((!workspaceLayout.joinsPrimary && preferredMainWidth > initial.main) || workspaceLayout.headerFittingWidth > initial.support)
        tabOverflow.isHidden = compactHeader || !overflowing
        let overflow = !compactHeader && overflowing
        let overflowButtonWidth = overflow ? SpookkyStyle.points(28) : 0
        if overflowWidth.constant != overflowButtonWidth { overflowWidth.constant = overflowButtonWidth }
        let resolved = widths(overflow: overflow ? SpookkyStyle.points(32) : 0)
        if !workspaceLayout.joinsPrimary { for item in tabPairs.values { item.availableWidth = resolved.main } }
        if tabsWidth.constant != resolved.main { tabsWidth.constant = resolved.main }
        if supportHeaderLeading.constant != resolved.supportStart { supportHeaderLeading.constant = resolved.supportStart }
        tabScroll.isHidden = store.state.selected == nil || workspaceLayout.joinsPrimary
        workspaceLayout.headerView.isHidden = store.state.selected == nil || !expanded
        supportingToggle.toolTip = expanded ? "Hide side panel" : "Show side panel"
        supportingToggle.setAccessibilityLabel(supportingToggle.toolTip!)
        supportingToggle.setAccessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
    func showTabOverflow() {
        guard let workspace = store.state.selected else { return }
        tabOverflowMenu(workspace).popUp(positioning: nil, at: NSPoint(x: 0, y: tabOverflow.bounds.height), in: tabOverflow)
    }
    func headerActionsMenu(_ id: UUID) -> NSMenu {
        let actions = store.state.workspaces.first(where: { $0.id == id })?.isLanding == true ? NSMenu() : sidebar.workspaceContextMenu(id)
        guard compactHeader, let workspace = store.state.selected, workspace.id == id else { return actions }
        let menu = tabOverflowMenu(workspace)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New tab") { [weak self] in self?.newTab() })
        menu.addItem(ClosureMenuItem("View changes") { [weak self] in self?.showChanges() })
        menu.addItem(ClosureMenuItem("Thread details") { [weak self] in self?.showThreadDetails() })
        let layout = ClosureMenuItem(workspaceLayout.layoutActionTitle) { [weak self] in self?.workspaceLayout.toggleLayout() }
        layout.isEnabled = workspaceLayout.canToggleLayout; menu.addItem(layout)
        if !actions.items.isEmpty { menu.addItem(.separator()) }
        for item in actions.items { actions.removeItem(item); menu.addItem(item) }
        return menu
    }
    func tabOverflowMenu(_ workspace: Workspace) -> NSMenu {
        let menu = NSMenu()
        let primary = ClosureMenuItem(workspace.displayTitle) { [weak self] in self?.focusSelectedContent() }
        primary.image = SpookkyStyle.toolImage(workspace.displayProvider); menu.addItem(primary)
        for tab in workspace.support?.tabs ?? [] {
            let item = ClosureMenuItem(tab.displayTitle) { [weak self] in
                self?.store.update { $0.selectSupport(tab.id) }; self?.focusSupportingContent()
            }
            item.representedObject = tab.id
            item.image = SpookkyStyle.supportingImage(tab.target)
            item.state = tab.id == workspace.support?.selectedTabID ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New chat") { [weak self] in self?.newWorkspace() })
        return menu
    }
    @objc func toggleWorkspaceSidebar() { store.update { $0.sidebarCollapsed.toggle() } }
    func showChanges() {
        store.update { $0.openSupport(.changes, title: "Changes") }
        focusSupportingContent()
    }
    var supportingPanelExpanded: Bool {
        guard let panel = store.state.selected?.support else { return false }
        return panel.layout != .collapsed && !panel.tabs.isEmpty
    }
    func toggleSupportingPanel() {
        guard let workspace = store.state.selected else { return }
        if supportingPanelExpanded {
            store.update { $0.setSupportingLayout(.collapsed) }
            focusSelectedContent()
        } else {
            store.update {
                if let selected = workspace.support?.selectedTabID { $0.selectSupport(selected) }
                else { $0.openSupport(.startPage, title: "New tab") }
            }
            focusSupportingContent()
        }
    }
    @objc func toggleCodeSidebar() {
        if (supportingContentHost as? BrowserArtifactContentHost)?.focusAddress(in: window) == true { return }
        toggleSupportingPanel()
    }
    func chooseSupportingFile(replacing tabID: UUID? = nil) {
        guard let workspace = store.state.selected else { return }
        let root = (workspace.anchor ?? workspace.selectedLocation).scopePath
        let picker = WorkspaceFilePicker(root: root); filePicker = picker
        picker.onChoose = { [weak self] path in
            guard let self, store.state.selectedWorkspaceID == workspace.id else { return }
            store.update { state in
                let target = SupportingTarget.file(path: path)
                if let existing = state.selected?.support?.tabs.first(where: { $0.target == target }) {
                    state.selectSupport(existing.id)
                    if let tabID, tabID != existing.id { state.closeSupport(tabID) }
                } else if let tabID {
                    state.updateSupport(tabID, target: target, title: (path as NSString).lastPathComponent)
                } else { state.openSupport(target, title: (path as NSString).lastPathComponent) }
            }
            focusSupportingContent()
        }
        picker.onDismiss = { [weak self] in self?.filePicker = nil }
        picker.show(relativeTo: compactHeader ? threadActions : threadDetails)
    }
    func renderSupportingContent() {
        let workspace = store.state.selected
        workspaceLayout.update(workspace?.support ?? SupportingPanelState())
        workspaceLayout.layoutSubtreeIfNeeded()
        let retainedTabs = store.state.workspaces.flatMap { $0.support?.tabs ?? [] }
        let retainedIDs = Set(retainedTabs.map(\.id))
        let startPageIDs = Set(retainedTabs.filter { $0.target == .startPage }.map(\.id))
        startPages = startPages.filter { startPageIDs.contains($0.key) }
        supportingContentHost?.retainTabs(retainedIDs)
        guard let workspace, let tab = workspace.support?.selected, workspaceLayout.showsSupportingContent else {
            workspaceLayout.show(nil); supportContentKey = ""; return
        }
        let key = workspace.id.uuidString + tab.id.uuidString
        switch tab.target {
        case .startPage:
            let page = startPages[tab.id] ?? SupportingStartPage(recent: workspace.support?.tabs ?? [], retainedTerminals: workspace.retainedSupportingTerminals)
            startPages[tab.id] = page
            page.updateRetainedTerminals(workspace.retainedSupportingTerminals)
            page.onAddress = { [weak self] input in
                guard let self, let url = BrowserAddress.submitted(input) else { return }
                store.update { $0.updateSupport(tab.id, target: .browser(url: url), title: "Browser", workspaceID: workspace.id) }
                focusSupportingContent()
            }
            page.onTool = { [weak self] tool in self?.openSupportingTool(tool, replacing: tab.id) }
            page.onRecent = { [weak self] target, title in
                self?.store.update {
                    if case .terminal = target { $0.closeSupport(tab.id) }
                    $0.openSupport(target, title: title)
                }; self?.focusSupportingContent()
            }
            workspaceLayout.show(page)
        case .changes, .file:
            workspaceLayout.show(files.layout)
        case .terminal:
            workspaceLayout.show(supportingTerminal)
        case .browser, .artifact:
            if let view = supportingContentHost?.view(for: tab, workspace: workspace, update: { [weak self, tabID = tab.id, workspaceID = workspace.id] target, title in
                self?.store.update(debounced: true) { $0.updateSupport(tabID, target: target, title: title, workspaceID: workspaceID) }
            }) { workspaceLayout.show(view) }
            else if key != supportContentKey {
                let label = ChromeTextField(wrappingLabelWithString: "This supporting view is unavailable in this build.")
                label.alignment = .center; workspaceLayout.show(label)
            }
        }
        supportContentKey = key
    }
    func buildMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), app = NSMenu()
        services.populate(app)
        app.addItem(withTitle: "Quit Spookky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app; main.addItem(appItem)
        let item = NSMenuItem(title: "File", action: nil, keyEquivalent: ""), file = NSMenu(title: "File")
        for (title, action, key) in [("New chat", #selector(newWorkspace), "n"), ("New tab", #selector(newTab), "t"),
            ("Close", #selector(closeSelectedTab), "w"), ("Start selected CLI", #selector(launchSelected), "\r"),
            ("Find workspace", #selector(findWorkspace), "k")] {
            let entry = file.addItem(withTitle: title, action: action, keyEquivalent: key); entry.target = self
        }
        file.addItem(ClosureMenuItem("Stop primary terminal…") { [weak self] in self?.stopPrimaryAgent() })
        let projectItem = NSMenuItem(title: "Add project", action: nil, keyEquivalent: "")
        projectItem.submenu = makeProjectMenu(); file.addItem(projectItem)
        file.addItem(ClosureMenuItem("Project operations…") { [weak self] in self?.showLocationOperations() })
        item.submenu = file; main.addItem(item)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""), edit = NSMenu(title: "Edit")
        let undo = NSMenuItem(title: "Undo", action: #selector(undoInput), keyEquivalent: "z"); undo.target = self
        let redo = NSMenuItem(title: "Redo", action: #selector(redoInput), keyEquivalent: "z"); redo.target = self; redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(undo); edit.addItem(redo); edit.addItem(.separator())
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem)
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: ""), view = NSMenu(title: "View")
        view.addItem(ClosureMenuItem("Refresh conversations") { [weak self] in self?.history.requestCatalogRefresh(force: true) })
        for appearance in [WorkspaceAppearance.system, .light, .dark] {
            view.addItem(ClosureMenuItem(appearance.rawValue.capitalized + " appearance") { [weak self] in self?.store.update { $0.appearance = appearance } })
        }
        view.addItem(ClosureMenuItem("Retry saving") { [weak self] in Task { try? await self?.store.flush() } })
        for (title, action, key) in [("Next tab", #selector(nextTab), "]"), ("Previous tab", #selector(previousTab), "["),
            ("Rename tab…", #selector(renameSelectedTab), ""), ("Focus sidebar", #selector(focusSidebar), ""),
            ("Focus tab strip", #selector(focusTabStrip), ""), ("Focus other pane", #selector(focusOtherPane), "")] {
            let entry = view.addItem(withTitle: title, action: action, keyEquivalent: key)
            entry.target = self; entry.keyEquivalentModifierMask = [.command, .shift]
        }
        view.addItem(ClosureMenuItem("Archived threads") { [weak self] in self?.sidebar.showingArchived.toggle(); self?.chromeRevision = ""; self?.render() })
        view.addItem(ClosureMenuItem("Open file…") { [weak self] in self?.chooseSupportingFile() })
        view.addItem(ClosureMenuItem("Toggle file tree") { [weak self] in self?.files.toggle() })
        view.addItem(ClosureMenuItem("Reset activity status") { [weak self] in if let ids = self?.store.state.selected?.tabs.map(\.id) { self?.changeAgentAttention(ids, action: "reset") } })
        view.addItem(ClosureMenuItem("Thread details") { [weak self] in self?.showThreadDetails() })
        view.addItem(ClosureMenuItem("Review changes") { [weak self] in self?.showChanges() })
        for (title, action, key) in [("Toggle workspace sidebar", #selector(toggleWorkspaceSidebar), "b"),
                                     ("Show or hide supporting panel", #selector(toggleCodeSidebar), "l")] {
            let entry = view.addItem(withTitle: title, action: action, keyEquivalent: key)
            entry.target = self; entry.keyEquivalentModifierMask = .command
        }
        view.addItem(.separator())
        for (title, action, key) in [("Zoom In", #selector(zoomIn), "+"), ("Zoom Out", #selector(zoomOut), "-"), ("Actual Size", #selector(actualSize), "0")] {
            let entry = view.addItem(withTitle: title, action: action, keyEquivalent: key); entry.target = self
        }
        viewItem.submenu = view; main.addItem(viewItem); NSApp.mainMenu = main
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoInput) { return activeInputEditor?.undoManager?.canUndo == true }
        if menuItem.action == #selector(redoInput) { return activeInputEditor?.undoManager?.canRedo == true }
        if window.attachedSheet != nil { return false }
        if menuItem.action == #selector(launchSelected) {
            return store.state.selectedTab?.isEditable == true && composers[store.state.selectedTab!.id]?.hasInputFocus == true
        }
        return true
    }
    var activeInputEditor: NSTextView? {
        guard let editor = (window.attachedSheet?.firstResponder ?? window.firstResponder) as? NSTextView,
              editor.isEditable, editor is PromptTextView || editor.isFieldEditor else { return nil }
        return editor
    }
    @objc func undoInput() { activeInputEditor?.undoManager?.undo() }
    @objc func redoInput() { activeInputEditor?.undoManager?.redo() }
    @objc func zoomIn() { services.changeDisplay { $0.stepZoom(1) } }
    @objc func zoomOut() { services.changeDisplay { $0.stepZoom(-1) } }
    @objc func actualSize() { services.changeDisplay { $0.zoom = 1 } }
    func handleCommand(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, window.attachedSheet == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command || modifiers == [.command, .shift] {
            if key == "+" || key == "=" { zoomIn(); return true }
            if key == "-" { zoomOut(); return true }
            if key == "0" { actualSize(); return true }
        }
        if modifiers == .command {
            switch key {
            case "b": toggleWorkspaceSidebar()
            case "l": toggleCodeSidebar()
            case "n": newWorkspace()
            case "t": newTab()
            case "w": closeSelectedTab()
            case "k": findWorkspace()
            case "p": chooseSupportingFile()
            case "[": navigateThread(-1)
            case "]": navigateThread(1)
            case "\r":
                guard let id = store.state.selectedTab?.id, store.state.selectedTab?.isEditable == true,
                      composers[id]?.hasInputFocus == true else { return false }
                if !event.isARepeat { composers[id]?.submit() }
            default:
                if let number = Int(key), (1...9).contains(number) { selectDisplayTab(number - 1) }
                else { return false }
            }
            return true
        }
        if modifiers == [.command, .shift] {
            switch key {
            case "[", "{": previousTab()
            case "]", "}": nextTab()
            default: return false
            }
            return true
        }
        return false
    }
    func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }
    var retainsInputFocusOutsideTerminals: Bool {
        if window.attachedSheet != nil || filePicker?.popover.isShown == true { return true }
        guard let view = window.firstResponder as? NSView, view.window === window,
              view !== window.contentView else { return false }
        return !view.isDescendant(of: body) && !view.isDescendant(of: supportingTerminal)
    }
    func render() {
        let state = store.state
        let activeLocation = state.locations?.operations.first { $0.status == .running && $0.request.workspaceID == state.selectedWorkspaceID }
        cancelLocation.isHidden = activeLocation == nil
        let appearanceName: NSAppearance.Name? = state.appearance == .system ? nil : state.appearance == .dark ? .darkAqua : .aqua
        if window.appearance?.name != appearanceName { window.appearance = appearanceName.flatMap(NSAppearance.init(named:)) }
        surfaces.setTheme(dark: window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        updateHeaderGeometry()
        window.contentView?.layoutSubtreeIfNeeded()
        renderSupportingContent()
        files.update(state.selected, operation: state.locations?.operations.last(where: { $0.status == .complete })?.request.id)
        files.layout.layoutSubtreeIfNeeded()
        warning.stringValue = store.saveError ?? activeLocation.map { $0.request.kind.rawValue.capitalized + " · " + $0.request.destination } ?? ""
        warning.lineBreakMode = .byTruncatingTail; warning.toolTip = warning.stringValue
        warning.isHidden = warning.stringValue.isEmpty
        workspaceBottom.constant = warning.isHidden && cancelLocation.isHidden ? 0 : -28
        warning.textColor = activeLocation != nil && store.saveError == nil ? SpookkyPalette.secondary : SpookkyPalette.warning
        let error = store.saveError ?? state.selectedTab?.failure?.message
        if error != announcedError {
            announcedError = error
            if let error { NSAccessibility.post(element: NSApp!, notification: .announcementRequested,
                userInfo: [.announcement: error, .priority: NSAccessibilityPriorityLevel.medium.rawValue]) }
        }
        let workspaceChrome = state.workspaces.map { w -> String in
            let identity = w.id.uuidString + w.displayTitle + w.displayProvider.rawValue + w.directory + String(w.support?.tabs.count ?? 0)
            let anchor = (w.anchor?.branch ?? "") + String(describing: w.projectID)
            let tabs = w.tabs.map { tab -> String in
                let activity = tab.activity
                let children = activity?.children.map(\.id).joined() ?? ""
                return [tab.id.uuidString, tab.title, tab.status.rawValue, tab.draft.tool.rawValue,
                        String(describing: activity?.displayState), String(activity?.unread ?? false),
                        children, tab.displayTool.rawValue, String(activity?.attached ?? false), activity?.preview ?? ""].joined(separator: "|")
            }.joined()
            let association = (w.currentProjectAssociation?.message ?? "") + String(describing: w.conversationID) + String(describing: w.primaryTerminalID) + String(w.conversationOwnershipAmbiguous == true)
            return identity + anchor + w.selectedTabID.uuidString + tabs + association
        }.joined()
        let projectChrome = state.projects.map { project -> String in
            let identity = project.id.uuidString + project.name + project.location.scopePath
            return identity + String(project.location.isGit) + String(project.isCollapsed == true)
        }.joined()
        let selectionChrome = String(describing: state.selectedWorkspaceID) + String(state.sidebarCollapsed) +
            String(describing: state.selected?.support?.layout) + String(describing: state.selected?.support?.fullWidthSelection)
        let historyChrome = history.historyRecords.keys.sorted().map { key in key + (history.historyRecords[key] ?? []).map { $0.id.sessionID + $0.displayTitle }.joined() }.joined() + history.historyHasMore.sorted().joined()
        let chrome = historyChrome + historySearch.stringValue + workspaceChrome + projectChrome + selectionChrome + String(describing: window.effectiveAppearance.name) + state.workspaces.map { String($0.viewClosed == true) }.joined()
        if chrome != chromeRevision {
            chromeRevision = chrome
            window.effectiveAppearance.performAsCurrentDrawingAppearance { renderChrome() }
        }
        for (id, header) in paneHeaders { header.selected = state.selected?.split != nil && state.selectedTab?.id == id }
        for (id, label) in paneTitles {
            guard let workspace = state.workspace(containing: id), let tab = state.tab(id) else { continue }
            let name = workspace.primaryTerminalID == id ? workspace.displayTitle : tab.title
            label.stringValue = name + " · " + SpookkyStyle.abbreviatedPath(workspace.directory)
        }
        for (id, label) in agentHeaderLabels {
            let activity = state.tab(id)?.activity
            let value = activity?.displayState ?? .idle
            label.stringValue = value == .idle ? "" : value.label + ((activity?.children.isEmpty == false) ? " · " + AgentIndicator.childLabel(activity!.children.count) : "")
            label.textColor = AgentIndicator.color(value); label.isHidden = label.stringValue.isEmpty
            label.toolTip = activity.map(AgentIndicator.detail); label.setAccessibilityLabel(label.stringValue)
        }
        let key = state.visibleTabIDs.map { id in id.uuidString + (state.tab(id)?.status.rawValue ?? "") + String(describing: state.tab(id)?.binding?.id) }.joined() + String(describing: state.selectedWorkspaceID) + String(describing: state.selected?.support?.selectedTabID) + String(describing: state.selected?.support?.layout) + String(describing: state.selected?.support?.fullWidthSelection)
        for id in state.visibleTabIDs {
            if let tab = state.tab(id), let w = state.workspace(containing: id) {
                composers[id]?.repositorySnapshot = repositorySnapshots[w.projectID ?? w.id]
                composers[id]?.update(tab, workspace: w, state: state)
            }
        }
        sessionLaunch.updateStartupFeedback()
        guard key != contentKey else { return }
        contentKey = key; renderTask?.cancel(); surfaces.invalidate()
        if !workspaceLayout.hasFocus && !retainsInputFocusOutsideTerminals { window.makeFirstResponder(nil) }
        let started = ProcessInfo.processInfo.systemUptime
        renderTask = Task { [weak self] in await self?.renderContent(started: started) }
    }
    func renderChrome() {
        let state = store.state, collapsed = state.sidebarCollapsed
        recordNavigation()
        threadActions.isEnabled = state.selected?.isLanding == false
        threadChanges.isEnabled = state.selected != nil
        supportingToggle.isEnabled = state.selected != nil
        sidebar.renderConversationSidebar(state, collapsed: collapsed)
        let tabsKey = String(describing: state.selectedWorkspaceID) + String(describing: state.selected?.primaryTerminalID)
        if tabsKey != tabRevision {
            renameEditor?.cancel(); renameEditor = nil
            tabRevision = tabsKey; tabPairs.removeAll(); clear(tabs)
            if let workspace = state.selected, let terminal = workspace.primaryTerminal {
                let item = WorkspaceTabView(title: workspace.displayTitle,
                    image: SpookkyStyle.toolImage(workspace.displayProvider), closable: false, trailingActions: [threadActions, threadDetails],
                    onSelect: { [weak self] in self?.selectTab(terminal.id) })
                item.titleButton.onDoubleClick = { [weak self] in if !workspace.isLanding { self?.rename(workspaceID: workspace.id) } }
                item.titleButton.onNavigate = { [weak self] key in self?.moveTabFocus(from: terminal.id, offset: key == 123 || key == 126 ? -1 : 1) }
                tabPairs[terminal.id] = item
            }
        }
        if let workspace = state.selected, let terminal = workspace.primaryTerminal, let item = tabPairs[terminal.id] {
            item.update(title: workspace.isLanding ? "New chat" : workspace.displayTitle,
                image: SpookkyStyle.toolImage(workspace.displayProvider),
                help: workspace.displayTitle + " · " + workspace.displayProvider.displayName + "\n" + workspace.directory,
                selected: workspace.support?.layout != .fullWidth || workspace.support?.resolvedFullWidthSelection == .primary,
                closable: false)
            item.titleButton.onContextMenu = { [weak self] in
                guard let self else { return nil }; return self.sidebar.workspaceContextMenu(workspace.id)
            }
        }
        updateHeaderGeometry()
    }
#if SPOOKKY_HARNESS
    func historyFixtureRecords(_ key: String) -> [ConversationCatalogRecord] { history.historyRecords[key] ?? [] }
#endif

    func renderContent(started: Double) async {
        guard window.isVisible else { return }
        let ids = store.state.visibleTabIDs, records = ids.compactMap { store.state.tab($0) }
        let terminals = records.filter { $0.status == .running || $0.status == .ended }
#if SPOOKKY_HARNESS
        let warm = !terminals.isEmpty && terminals.allSatisfy { surfaces.view($0.id) != nil }
#endif
        do {
            var sizes: [UUID: NSSize] = [:]
            for tab in records {
                let bounds = tab.id == store.state.primaryTerminalID ? body.bounds : supportingTerminal.bounds
                sizes[tab.id] = NSSize(width: max(1, bounds.width), height: max(1, bounds.height - (tab.status == .running ? 0 : SpookkyStyle.headerHeight)))
            }
            let prepared = try await surfaces.prepare(terminals, sizes: sizes)
            guard !Task.isCancelled, let prepared, ids == store.state.visibleTabIDs else { return }
            body.subviews.forEach { $0.removeFromSuperview() }; paneHeaders.removeAll(); paneTitles.removeAll(); agentHeaderLabels.removeAll(); sessionLaunch.startupNotices.removeAll()
            guard !records.isEmpty else {
                if store.state.selected == nil {
                    store.update { $0.showLanding(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path) }
                    contentKey = ""; render()
                }
                return
            }
            if let primary = records.first(where: { $0.id == store.state.primaryTerminalID }) {
                install(pane(primary, surface: prepared[primary.id]), in: body)
            }
            supportingTerminal.subviews.forEach { $0.removeFromSuperview() }
            if case .terminal(let id) = store.state.selected?.support?.selected?.target,
               let terminal = records.first(where: { $0.id == id }) { install(pane(terminal, surface: prepared[id]), in: supportingTerminal) }
            let active = store.state.selectedTab?.id
            if !workspaceLayout.hasFocus && !retainsInputFocusOutsideTerminals {
                if let active, let surface = prepared[active] { window.makeFirstResponder(surface) }
                else if let active { composers[active]?.focus() }
            }
            body.layoutSubtreeIfNeeded()
            try await surfaces.restoreViewports(ids)
            guard !Task.isCancelled, ids == store.state.visibleTabIDs else { return }
#if SPOOKKY_HARNESS
            if !terminals.isEmpty { diagnostics?.record(elapsed: ProcessInfo.processInfo.systemUptime - started, warm: warm, surfaces: surfaces.count) }
#endif
            let retained = Set(store.state.workspaces.flatMap(\.tabs).map(\.id))
            composers = composers.filter { retained.contains($0.key) }
            refreshAgentAttention()
            sessionLaunch.updateStartupFeedback()
        } catch {
            guard !Task.isCancelled, ids == store.state.visibleTabIDs else { return }
            for tab in records where tab.binding != nil {
                store.update { $0.apply(.failure(.failed, TabFailure(.attachment, error.localizedDescription), clearIntent: false), to: tab.id) }
            }
        }
    }
    func pane(_ tab: WorkspaceTab, surface: TerminalHostView?) -> NSView {
        let container = NSView()
        if let workspace = store.state.workspace(containing: tab.id), workspace.primaryTerminalID == tab.id,
           workspace.catalogMetadata != nil, tab.binding == nil, tab.launch == nil {
            let message = ChromeTextField(wrappingLabelWithString: workspace.catalogMetadata?.displayTitle ?? workspace.title)
            message.font = .systemFont(ofSize: SpookkyStyle.points(15), weight: .medium)
            let identity = workspace.conversationID
            let opening = identity.map { sessionLaunch.continuingConversations.contains($0) } ?? false
            let error = identity.flatMap { sessionLaunch.continuationErrors[$0] }
            let action = ActionButton(opening ? "Opening conversation…" : error == nil ? "Continue saved conversation" : "Retry", symbol: opening ? "clock" : "arrow.up.forward") { [weak self] in self?.sessionLaunch.openConversationWorkspace(workspace.id) }
            action.isEnabled = !opening
            let details = ChromeTextField(wrappingLabelWithString: error ?? "Open this saved conversation in its original folder.")
            details.textColor = SpookkyPalette.secondary
            let stack = NSStackView(views: [message, details, action]); stack.orientation = .vertical; stack.alignment = .leading
            stack.spacing = SpookkyStyle.points(12); stack.edgeInsets = NSEdgeInsets(top: SpookkyStyle.points(24), left: SpookkyStyle.points(24), bottom: SpookkyStyle.points(24), right: SpookkyStyle.points(24))
            install(stack, in: container)
        } else if tab.isEditable || tab.status == .preparing || tab.status == .launching {
#if SPOOKKY_HARNESS
            let catalog: any ProviderModelDiscovering = ComposerFixtureModels()
#else
            let catalog: any ProviderModelDiscovering = ProviderModelCatalog.shared
#endif
            let composer = composers[tab.id] ?? LaunchComposerView(tabID: tab.id, imageDirectory: promptImageDirectory, modelCatalog: catalog); composers[tab.id] = composer
            composer.onDraft = { [weak self] tool, prompt in self?.store.update(debounced: prompt != nil) { $0.editDraft(tab.id, tool: tool, prompt: prompt) } }
            composer.onImages = { [weak self, id = tab.id] images in self?.editPromptImages(images, for: id) }
            composer.onError = { [weak self] message in self?.alert("Could not update draft", message) }
            composer.onModel = { [weak self] selection in self?.store.update { $0.editModelSelection(tab.id, selection: selection) } }
            composer.onFullAccess = { [weak self] enabled in self?.store.update { $0.editFullAccess(tab.id, enabled: enabled) } }
            composer.onNoProject = { [weak self] in
                guard let self, let workspace = store.state.workspace(containing: tab.id) else { return }
                store.update { $0.setLocation(WorkspaceLocation(path: FileManager.default.homeDirectoryForCurrentUser.path), projectID: nil, workspaceID: workspace.id) }
                scheduleRepositoryRefresh()
            }
            composer.onRecallModel = { [weak self] model in
                guard let self, let tool = store.state.tab(tab.id)?.draft.tool else { return nil }
                return store.state.rememberedModelSelection(for: tool, model: model)
            }
            composer.onLaunch = { [weak self] in self?.sessionLaunch.launch(tab.id) }
            composer.onRetryError = { [weak self] in self?.sessionLaunch.launch(tab.id) }
            composer.onUseLocal = { [weak self] in
                guard let self, let current = store.state.workspace(containing: tab.id) else { return }
                var draft = current.locationDraft ?? LocationDraft(); draft.mode = .local
                store.update { state in
                    if let id = current.locationOperationID { state.dismissOperationNotice(id) }
                    state.editLocation(draft, workspaceID: current.id)
                }
            }
            composer.onDismissError = { [weak self] in
                guard let self, let current = store.state.workspace(containing: tab.id) else { return }
                store.update { state in
                    if let id = current.locationOperationID { state.dismissOperationNotice(id) }
                    state.dismissFailureNotice(tab.id)
                }
            }
            composer.onTerminal = { [weak self] in self?.openTerminal(from: tab.id) }
            composer.onChooseFolder = { [weak self] in self?.chooseFolder(register: false) }
            composer.onAddProject = { [weak self] anchor in self?.addProjectMenu(anchor: anchor) }
            composer.onLocate = { [weak self] in self?.chooseFolder(register: false, relocate: true) }
            composer.onProject = { [weak self] id in self?.chooseProject(id) }
            composer.onFocus = { [weak self] in
                guard let self else { return }
                let selection = store.state.selected?.support?.fullWidthSelection
                if store.state.selectedTab?.id != tab.id || (selection != nil && selection != .primary) { selectTab(tab.id) }
            }
            if let w = store.state.workspace(containing: tab.id) {
                composer.repositorySnapshot = repositorySnapshots[w.projectID ?? w.id]
                composer.locationOptions.onDraft = { [weak self] draft in
                    guard let self, let current = store.state.workspace(containing: tab.id) else { return }
                    store.update(debounced: true) { state in
                        state.editLocation(draft, workspaceID: current.id)
                        if let projectID = current.projectID { state.preferSource(draft.source, projectID: projectID) }
                    }
                }
                composer.locationOptions.onCheckout = { [weak self] location in
                    guard let self, let current = store.state.workspace(containing: tab.id),
                          current.selectedLocation.commonRepository == location.commonRepository else { return }
                    store.update { $0.setLocation(location, projectID: current.projectID, workspaceID: current.id) }
                    self.scheduleRepositoryRefresh()
                }
                composer.update(tab, workspace: w, state: store.state)
            }
            install(composer, in: container)
        } else {
            if tab.status == .running, let surface {
                if tab.pendingStartup != nil, store.state.primaryTerminalID == tab.id {
                    let notice = ProviderStartupNoticeView(focus: { [weak self] in self?.focusSelectedContent() },
                        details: { [weak self] in self?.showThreadDetails() })
                    sessionLaunch.startupNotices[tab.id] = notice
                    let stack = NSStackView(views: [notice, surface]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
                    notice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                    surface.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                    surface.setContentHuggingPriority(.defaultLow, for: .vertical)
                    surface.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
                    install(stack, in: container)
                } else { install(surface, in: container) }
                return container
            }
            let directory = store.state.workspace(containing: tab.id)?.directory ?? ""
            let owner = store.state.workspace(containing: tab.id)
            let isPrimary = owner?.primaryTerminalID == tab.id
            let title = SpookkyStyle.label( (isPrimary ? owner?.displayTitle ?? tab.title : tab.title) + " · " + SpookkyStyle.abbreviatedPath(directory))
            title.font = .monospacedSystemFont(ofSize: SpookkyStyle.points(11), weight: .regular); title.textColor = SpookkyPalette.metadata; title.lineBreakMode = .byTruncatingMiddle
            title.toolTip = directory; paneTitles[tab.id] = title
            let split = ActionButton("", symbol: "rectangle.split.2x1", help: "Split terminal") { [weak self] in self?.split(tab.id) }
            split.isEnabled = tab.status == .running
            let activityLabel = SpookkyStyle.label( tab.activity?.displayState == .idle ? "" : tab.activity?.displayState.label ?? "")
            activityLabel.font = .systemFont(ofSize: SpookkyStyle.points(11)); activityLabel.textColor = tab.activity.map { AgentIndicator.color($0.displayState) } ?? SpookkyPalette.metadata
            activityLabel.isHidden = activityLabel.stringValue.isEmpty; activityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            agentHeaderLabels[tab.id] = activityLabel
            var headerViews: [NSView] = [title, NSView(), activityLabel, split]
            if tab.status == .ended {
                if let workspace = store.state.workspace(containing: tab.id), workspace.primaryTerminalID == tab.id,
                   let identity = workspace.conversationID {
                    let opening = sessionLaunch.continuingConversations.contains(identity)
                    let resume = ActionButton(opening ? "Resuming…" : "Resume conversation", symbol: "arrow.clockwise") { [weak self] in
                        self?.sessionLaunch.openConversationWorkspace(workspace.id)
                    }
                    resume.isEnabled = !opening
                    resume.toolTip = sessionLaunch.continuationErrors[identity] ?? "Resume this exact conversation in its original folder"
                    headerViews.append(resume)
                    if let error = sessionLaunch.continuationErrors[identity] {
                        let message = ChromeTextField(wrappingLabelWithString: error)
                        message.textColor = SpookkyPalette.warning; message.toolTip = error
                        headerViews.append(message)
                    }
                } else {
                    headerViews.append(ActionButton("Session ended · New terminal", symbol: "plus") { [weak self] in self?.openTerminal(from: tab.id) })
                }
            }
            if store.state.selected?.split != nil {
                headerViews.append(ActionButton("", symbol: "rectangle", help: "Show one terminal; keep both sessions") { [weak self] in self?.store.update { $0.collapseSplit() } })
            }
            let header = ChromeStackView(views: headerViews); header.spacing = SpookkyStyle.points(8); header.cornerRadius = 0
            header.selected = store.state.selected?.split != nil && store.state.selectedTab?.id == tab.id
            paneHeaders[tab.id] = header
            header.edgeInsets = NSEdgeInsets(top: SpookkyStyle.points(4), left: SpookkyStyle.points(12), bottom: SpookkyStyle.points(4), right: SpookkyStyle.points(8))
            let content: NSView
            if let surface, tab.status == .running || tab.status == .ended { content = surface }
            else {
                let message = ChromeTextField(wrappingLabelWithString: tab.failure?.message ?? "Session " + tab.status.rawValue)
                message.font = .systemFont(ofSize: SpookkyStyle.points(13)); message.textColor = SpookkyPalette.text
                let stack = NSStackView(views: [message])
                stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = SpookkyStyle.points(12); stack.edgeInsets = NSEdgeInsets(top: SpookkyStyle.points(24), left: SpookkyStyle.points(24), bottom: SpookkyStyle.points(24), right: SpookkyStyle.points(24))
                if tab.status != .ended || tab.binding != nil {
                    stack.addArrangedSubview(ActionButton(tab.binding != nil ? "Reconnect" : "Check session", symbol: "arrow.clockwise") { [weak self] in self?.sessionLaunch.reconnect(tab.id) })
                }
                stack.addArrangedSubview(ActionButton("Open a new Terminal", symbol: "terminal") { [weak self] in
                    guard let self else { return }; self.store.update { $0.newTab() }; if let id = self.store.state.selectedTab?.id { self.sessionLaunch.launch(id, tool: .shell) }
                })
                content = stack
            }
            header.translatesAutoresizingMaskIntoConstraints = false; content.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(header); container.addSubview(content)
            NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: container.leadingAnchor), header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                header.topAnchor.constraint(equalTo: container.topAnchor), header.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).displayScaled(alreadyScaled: true),
                content.leadingAnchor.constraint(equalTo: container.leadingAnchor), content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                content.topAnchor.constraint(equalTo: header.bottomAnchor), content.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        }
        return container
    }
    func install(_ view: NSView, in parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: parent.leadingAnchor), view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.topAnchor), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
    }
    func focusSelectedContent() {
        guard let id = store.state.primaryTerminalID else { return }
        store.update { $0.selectPrimaryContent() }
        if let view = surfaces.view(id), [.running, .ended].contains(store.state.tab(id)?.status) {
            window.makeFirstResponder(view)
        } else { composers[id]?.focus() }
    }
    func selectWorkspace(_ id: UUID) {
        if store.state.selectedWorkspaceID != id { sessionLaunch.cancelLaunchPreflight() }
        renameEditor?.cancel(); renameEditor = nil
        if store.state.selectedWorkspaceID == id { focusSelectedContent() }
        else { window.makeFirstResponder(nil); store.update { $0.selectWorkspace(id) } }
        scheduleRepositoryRefresh()
        refreshAgentAttention(clearManual: true)
    }
    func selectTab(_ id: UUID) {
        renameEditor?.cancel(); renameEditor = nil
        if id == store.state.primaryTerminalID { focusSelectedContent(); refreshAgentAttention(clearManual: true); return }
        if let supportID = store.state.selected?.support?.tabs.first(where: { if case .terminal(let terminalID) = $0.target { return terminalID == id }; return false })?.id {
            store.update { $0.selectSupport(supportID) }
            focusSupportingContent()
        } else {
            store.update { $0.selectTab(id) }
        }
        refreshAgentAttention(clearManual: true)
    }
    func moveTabFocus(from id: UUID, offset: Int) {
        guard let tabs = store.state.selected?.tabs, let index = tabs.firstIndex(where: { $0.id == id }), !tabs.isEmpty else { return }
        let target = tabs[(index + offset + tabs.count) % tabs.count].id
        guard let pair = tabPairs[target] else { return }
        pair.scrollToVisible(pair.bounds); window.makeFirstResponder(pair.titleButton)
    }
    func cycleTab(_ offset: Int) {
        guard let panel = store.state.selected?.support, !panel.tabs.isEmpty else { return }
        if panel.layout == .fullWidth {
            let targets: [FullWidthSelection] = [.primary] + panel.tabs.map { .support($0.id) }
            let index = targets.firstIndex(of: panel.resolvedFullWidthSelection) ?? 0
            switch targets[(index + offset + targets.count) % targets.count] {
            case .primary: focusSelectedContent()
            case .support(let id): store.update { $0.selectSupport(id) }; focusSupportingContent()
            }
            return
        }
        let index = panel.tabs.firstIndex { $0.id == panel.selectedTabID } ?? 0
        let target = panel.tabs[(index + offset + panel.tabs.count) % panel.tabs.count].id
        store.update { $0.selectSupport(target) }; focusSupportingContent()
    }
    @objc func nextTab() { cycleTab(1) }
    @objc func previousTab() { cycleTab(-1) }
    @objc func renameSelectedTab() { if let id = store.state.selectedWorkspaceID { rename(workspaceID: id) } }
    @objc func focusSidebar() {
        conversationSidebar.focusItem()
    }
    @objc func focusTabStrip() { if let id = store.state.selectedTab?.id { moveTabFocus(from: id, offset: 0) } }
    @objc func focusOtherPane() {
        if workspaceLayout.hasFocus { focusSelectedContent(); return }
        guard let selected = store.state.selected?.support?.selectedTabID else { return }
        store.update { $0.selectSupport(selected) }
        focusSupportingContent()
    }
    func focusSupportingContent() {
        guard workspaceLayout.showsSupportingContent, store.state.selected?.support?.selected != nil else { focusSelectedContent(); return }
        if case .terminal(let id) = store.state.selected?.support?.selected?.target, let view = surfaces.view(id), view.window === window {
            window.makeFirstResponder(view)
        } else if let content = workspaceLayout.content.subviews.first, content.acceptsFirstResponder {
            window.makeFirstResponder(content)
        } else { window.makeFirstResponder(workspaceLayout.panel) }
    }
    func handleClientExit(_ id: UUID) {
        guard store.state.tab(id)?.status == .running, surfaces.clientExited(id) else { return }
        surfaces.release(id)
        store.update { $0.apply(.failure(.failed, TabFailure(.attachment, "Terminal view disconnected. Your session is still running."), clearIntent: false), to: id) }
    }

    @objc func newWorkspace() {
        let hidden = !window.isVisible
        let context = store.state.selected
        window.makeFirstResponder(nil)
        sessionLaunch.cancelLaunchPreflight()
        store.update { $0.showLanding(projectID: context?.projectID,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path, inheriting: context?.primaryTerminal?.draft) }
        scheduleRepositoryRefresh()
        if hidden { reopen() }
        if let id = store.state.primaryTerminalID { composers[id]?.focus() }
    }
    func addBlankTab() { files.revealTerminal(); if store.state.selected == nil { newWorkspace() } else { store.update { $0.newTab() } } }
    @objc func newTab() {
        if store.state.selected == nil { newWorkspace() }
        if !window.isVisible { showWindow() }
        store.update { $0.openSupport(.startPage, title: "New tab") }; focusSupportingContent()
    }
    func openTerminal(from id: UUID) {
        guard let tab = store.state.tab(id) else { return }
        window.makeFirstResponder(nil)
        if let workspace = store.state.workspace(containing: id), workspace.isLanding, workspace.primaryTerminalID == id {
            var shellID: UUID!
            store.update {
                $0.newWorkspace(location: workspace.anchor ?? workspace.selectedLocation, projectID: workspace.projectID)
                shellID = $0.primaryTerminalID; $0.editDraft(shellID, tool: .shell, prompt: "")
            }
            sessionLaunch.launch(shellID, tool: .shell); return
        }
        if !tab.draft.isEmpty || !tab.isEditable || store.state.workspace(containing: id)?.primaryTerminalID == id && tab.binding != nil {
            store.update { $0.newTab() }; if let id = store.state.selectedTab?.id { sessionLaunch.launch(id, tool: .shell) }
        } else { sessionLaunch.launch(id, tool: .shell) }
    }
    @objc func launchSelected() {
        guard let id = store.state.selectedTab?.id else { return }; composers[id]?.submit()
    }
    func editPromptImages(_ images: [String], for id: UUID) {
        let previous = store.state.tab(id)?.draft.images ?? []
        store.update { $0.editDraft(id, images: images) }
        let candidates = Set(previous + images).subtracting(store.state.tab(id)?.draft.images ?? [])
        guard !candidates.isEmpty else { return }
        let tabs = store.state.workspaces.flatMap(\.tabs)
        let retained = Set(tabs.flatMap { $0.draft.images })
        let arguments = tabs.flatMap { $0.launch?.arguments ?? [] }
        let unused = candidates.filter { path in
            !retained.contains(path) && !arguments.contains(where: { $0.contains(path) })
        }
        guard !unused.isEmpty else { return }
        let directory = promptImageDirectory
        Task.detached {
            for path in unused {
                let file = URL(fileURLWithPath: path)
                guard file.deletingLastPathComponent().path == directory.path, file.pathExtension == "png",
                      UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func split(_ id: UUID) {
        guard store.state.tab(id)?.status == .running else { return }
        var newID: UUID?
        store.update { state in newID = state.newTab() }
        if let newID { sessionLaunch.launch(newID, tool: .shell) }
    }
    func windowDidResize(_ notification: Notification) { renameEditor?.cancel(); renameEditor = nil;
        updateHeaderGeometry(); rememberWindowFrame()
    }
    func windowDidMove(_ notification: Notification) { rememberWindowFrame() }
    func windowWillEnterFullScreen(_ notification: Notification) {
        fullscreenTransition = true
        window.allowsHeaderDragging = false
    }
    func windowDidEnterFullScreen(_ notification: Notification) { fullscreenTransition = false; updateHeaderGeometry() }
    func windowWillExitFullScreen(_ notification: Notification) { fullscreenTransition = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        fullscreenTransition = false
        window.allowsHeaderDragging = true
        updateHeaderGeometry(); rememberWindowFrame()
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullscreenTransition = false
        self.window.allowsHeaderDragging = true
        updateHeaderGeometry()
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullscreenTransition = false
        self.window.allowsHeaderDragging = false
        updateHeaderGeometry()
    }
    func rememberWindowFrame() {
        guard store.onChange != nil, let window, !fullscreenTransition, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        store.update(debounced: true) { $0.windowFrame = WorkspaceWindowFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height) }
    }
    func newProjectWorkspace(_ id: UUID) {
        guard store.state.projects.contains(where: { $0.id == id }) else { return }
        let draft = store.state.selected?.primaryTerminal?.draft
        window.makeFirstResponder(nil)
        sessionLaunch.cancelLaunchPreflight()
        store.update { $0.showLanding(projectID: id, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path, inheriting: draft) }
        scheduleRepositoryRefresh()
    }
    func chooseProject(_ id: UUID) {
        guard let project = store.state.projects.first(where: { $0.id == id }), let w = store.state.selected else { return }
        store.update { $0.setLocation(project.location, projectID: id, workspaceID: w.id) }
        scheduleRepositoryRefresh()
    }
    func scheduleRepositoryRefresh() {
        repositoryRefreshTask?.cancel()
        repositoryRefreshTask = Task { await refreshSelectedRepository() }
    }
    func refreshSelectedRepository() async {
        guard let workspace = store.state.selected, workspace.selectedLocation.isGit else { return }
        let key = workspace.projectID ?? workspace.id
        let generation = UUID(); repositoryGenerations[key] = generation
        do {
            let snapshot = try await locations.git.snapshot(workspace.selectedLocation)
            guard repositoryGenerations[key] == generation, store.state.selectedWorkspaceID == workspace.id,
                  store.state.selected?.selectedLocation.path == workspace.selectedLocation.path else { return }
            repositorySnapshots[key] = snapshot
            store.update { state in
                if let projectID = workspace.projectID { state.refreshProject(projectID, location: snapshot.location) }
                for checkout in snapshot.checkouts where checkout.available {
                    state.recordCheckout(WorkspaceLocation(path: checkout.path, checkoutIdentity: checkout.identity,
                        branch: checkout.branch, commonRepository: snapshot.location.commonRepository))
                }
                if let current = state.workspaces.first(where: { $0.id == workspace.id }), current.anchor == nil, current.locationDraft == nil {
                    var draft = LocationDraft()
                    draft.source = state.projects.first { $0.id == workspace.projectID }?.preferredSource ?? snapshot.defaultSource
                    state.editLocation(draft, workspaceID: workspace.id)
                }
            }
            render()
        } catch is CancellationError { return }
        catch { if store.state.selectedWorkspaceID == workspace.id { alert("Could not read repository", error.localizedDescription) } }
    }
    func makeProjectMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open folder…") { [weak self] in self?.chooseFolder(register: true) })
        let create = ClosureMenuItem("Create project…") { [weak self] in DispatchQueue.main.async { self?.showProjectCreation(.create) } }
        let clone = ClosureMenuItem("Clone repository…") { [weak self] in DispatchQueue.main.async { self?.showProjectCreation(.clone) } }
        menu.autoenablesItems = false
        create.isEnabled = projectCreation?.isWorking != true; clone.isEnabled = create.isEnabled
        menu.addItem(create); menu.addItem(clone)
        return menu
    }
    func addProjectMenu(anchor: NSView?) {
        let menu = makeProjectMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor?.bounds.height ?? 28), in: anchor ?? rail)
    }
    func showProjectCreation(_ mode: ProjectCreationMode) {
        if let projectCreation {
            if !projectCreation.isWorking { projectCreation.show(relativeTo: window) }
            return
        }
        var draft = store.state.projectDraft ?? ProjectCreationDraft()
        draft.mode = mode
        store.update { $0.projectDraft = draft }
        let form = ProjectCreationController(draft: draft, store: store, coordinator: locations)
        projectCreation = form
        let startingWorkspaceID = store.state.selectedWorkspaceID
        form.onSuccess = { [weak self] location in
            guard let self else { return }
            openDiscoveredProject(location, ifSelected: startingWorkspaceID)
            self.scheduleRepositoryRefresh()
        }
        form.onClose = { [weak self] in self?.projectCreation = nil; self?.focusSelectedContent() }
        form.show(relativeTo: window)
    }
    func deleteWorktree(_ record: CheckoutRecord) {
        do {
            let request = try locations.deletionRequest(record)
            let alert = ChromeAlert(); alert.messageText = "Delete worktree?"
            alert.informativeText = request.destination + "\n\nType the exact folder path. Spookky checks session ownership, edits, locks, and merged/pushed commits. The branch is kept."
            let field = ChromeTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
            field.placeholderString = "Exact folder path"; field.setAccessibilityLabel("Confirm exact worktree path")
            alert.accessoryView = field; alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "Delete worktree").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                guard field.stringValue == request.destination else { self.alert("Worktree was kept", "The typed path did not match."); return }
                Task {
                    do { _ = try await self.locations.start(request); await self.refreshSelectedRepository() }
                    catch { self.alert("Worktree operation needs attention", error.localizedDescription + "\n" + request.destination) }
                }
            }
        } catch { self.alert("Worktree was kept", error.localizedDescription) }
    }
    func showLocationOperations() {
        let operations = store.state.locations?.operations ?? []
        let text = operations.suffix(10).map { operation -> String in
            let heading = operation.request.kind.rawValue + " · " + operation.status.rawValue
            let phase = operation.error ?? operation.receipts.last?.phase.rawValue ?? "intent"
            return heading + "\n" + operation.request.destination + "\n" + phase
        }.joined(separator: "\n\n")
        alert("Project operations", text.isEmpty ? "No project operations yet." : text)
    }
    func openDiscoveredProject(_ location: WorkspaceLocation, ifSelected workspaceID: UUID?) {
        if store.state.selectedWorkspaceID == workspaceID {
            sessionLaunch.cancelLaunchPreflight()
            window.makeFirstResponder(nil)
        }
        store.update { $0.openProject(location, ifSelected: workspaceID, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path) }
    }
    func chooseFolder(register: Bool, relocate: Bool = false) {
        guard window.attachedSheet == nil else { return }
        if !window.isVisible { reopen() }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = register ? "Add project" : "Open"; let workspaceID = store.state.selectedWorkspaceID
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    let location = try await LocationDiscovery.discover(url)
                    if register { self.openDiscoveredProject(location, ifSelected: workspaceID) }
                    else {
                        self.store.update {
                            guard let workspaceID, $0.selectedWorkspaceID == workspaceID else { return }
                            if relocate { $0.relocateWorkspace(workspaceID, location: location) }
                            else { $0.setLocation(location, projectID: nil, workspaceID: workspaceID) }
                        }
                    }
                    await self.refreshSelectedRepository()
                } catch { self.alert("Could not open folder", error.localizedDescription) }
            }
        }
    }
    func rename(tabID: UUID? = nil, workspaceID: UUID? = nil) {
        renameEditor?.cancel(); renameEditor = nil
        if store.state.sidebarCollapsed, workspaceID != nil { store.update { $0.sidebarCollapsed = false } }
        if let workspaceID, let projectID = store.state.workspaces.first(where: { $0.id == workspaceID })?.projectID {
            store.update { $0.setProjectCollapsed(projectID, false) }
        }
        let button = tabID.flatMap { tabPairs[$0]?.titleButton }
        guard let button else {
            if let workspaceID, let workspace = store.state.workspaces.first(where: { $0.id == workspaceID }) {
                sidebar.presentThreadName(workspace.displayTitle) { [weak self] name in
                    guard let self else { return }
                    store.update { $0.renameWorkspace(workspaceID, name) }
                    if let metadata = workspace.catalogMetadata {
                        Task {
                            do { try await self.history.historyCatalog.rename(metadata.id, alias: name) }
                            catch { self.alert("Could not save provider alias", error.localizedDescription) }
                        }
                    }
                }
            }
            return
        }
        window.contentView?.layoutSubtreeIfNeeded()
        button.scrollToVisible(button.bounds)
        renameEditor = InlineRenameEditor(button: button) { [weak self, weak button] name, restoreFocus in
            guard let self else { return }; self.renameEditor = nil
            if let name { self.store.update { if let tabID { $0.renameTab(tabID, name) }; if let workspaceID { $0.renameWorkspace(workspaceID, name) } } }
            if restoreFocus, let button { self.window.makeFirstResponder(button) }
        }
    }
    @objc func findWorkspace() {
        if !window.isVisible { reopen() }
        if store.state.sidebarCollapsed { store.update { $0.sidebarCollapsed = false } }
        window.makeFirstResponder(historySearch)
    }
    @objc func closeSelectedTab() {
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            keyWindow.performClose(nil)
            return
        }
        if workspaceLayout.hasFocus, workspaceLayout.showsSupportingContent, let id = store.state.selected?.support?.selectedTabID {
            store.update { $0.closeSupport(id) }; focusSupportingContent()
        } else { window.performClose(nil) }
    }
    func stopPrimaryAgent(_ workspaceID: UUID? = nil) {
        guard let workspace = store.state.workspaces.first(where: { $0.id == (workspaceID ?? store.state.selectedWorkspaceID) }),
              let primary = workspace.primaryTerminal, !closing.contains(primary.id), window.attachedSheet == nil,
              (workspace.conversationID?.provider ?? (primary.activity?.attached == true ? primary.activity?.provider : nil) ?? primary.binding?.tool ?? primary.launch?.tool ?? primary.draft.tool) != .shell else { return }
        closing.insert(primary.id)
        Task {
            defer { closing.remove(primary.id) }
            guard await confirm("Stop primary terminal?", "This ends only Spookky’s owned terminal session. Work on a shared provider server or in the background may continue. To stop ongoing work, save unsent input and use the provider’s own Stop or Interrupt control in the surface running that conversation first. Conversation history and supporting tabs remain.", action: "Stop") else { return }
            await observationTask?.value
            do { try await launches.terminate(primary.id); surfaces.release(primary.id); try await store.flush() }
            catch { alert("Could not stop terminal", error.localizedDescription) }
        }
    }
    func confirm(_ title: String, _ message: String, action: String = "Close") async -> Bool {
        let alert = ChromeAlert(); alert.messageText = title; alert.informativeText = message
        let close = alert.addButton(withTitle: action)
        close.keyEquivalent = "\r"; close.keyEquivalentModifierMask = []
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        alert.window.defaultButtonCell = close.cell as? NSButtonCell
        return await present(alert) == .alertFirstButtonReturn
    }
    func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if !window.isVisible { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
    func alert(_ title: String, _ message: String) {
        let alert = ChromeAlert(); alert.messageText = title; alert.informativeText = message
        if window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    func prepareForUpdate() async throws {
        guard !(store.state.locations?.operations.contains(where: { $0.status == .running }) ?? false),
              !store.state.workspaces.flatMap(\.tabs).contains(where: { launches.isBusy($0.id) }) else {
            throw LaunchError.invalid("Finish the current launch or project operation before updating.")
        }
        try await store.flush()
        await surfaces.captureViewports()
        try await store.flush()
    }
    func prepareToQuit(context: [String: String] = [:]) -> NSApplication.TerminateReply {
#if SPOOKKY_HARNESS
        recordBenchmarkQuit("requested", context: context)
#endif
        services.flushDisplayPreferences()
        sessionLaunch.cancelLaunchPreflight()
        guard !(store.state.locations?.operations.contains(where: { $0.status == .running }) ?? false),
              !store.state.workspaces.flatMap(\.tabs).contains(where: { launches.isBusy($0.id) }) else {
#if SPOOKKY_HARNESS
            recordBenchmarkQuit("busy")
#endif
            return .terminateCancel
        }
        let live = store.state.workspaces.flatMap(\.tabs).contains {
            [.running, .preparing, .launching, .uncertain, .unavailable].contains($0.status) ||
                ($0.status == .failed && $0.binding != nil)
        }
        Task {
            do {
                try await store.flush()
                let hasBrowser = store.state.workspaces.contains { workspace in
                    workspace.support?.tabs.contains { if case .browser = $0.target { return true }; return false } == true
                }
                if (live || hasBrowser) && !services.installingUpdate {
                    let alert = ChromeAlert(); alert.messageText = "Quit Spookky?"
                    alert.informativeText = (hasBrowser ? "Browser URLs and website storage are retained. Unsent browser forms may be lost. Cancel to finish them first.\n\n" : "") + "Choose whether your terminal sessions should keep running. Ending terminals may leave work running on a shared provider server or in the background. Use the provider’s own Stop or Interrupt control to stop that work first."
                    alert.addButton(withTitle: live ? "Keep running and quit" : "Quit"); alert.addButton(withTitle: "Cancel")
                    if live { alert.addButton(withTitle: "End terminals and quit").hasDestructiveAction = true }
                    let result = await present(alert)
#if SPOOKKY_HARNESS
                    recordBenchmarkQuit("decision", context: ["response": String(result.rawValue)])
#endif
                    if result == .alertSecondButtonReturn { NSApp.reply(toApplicationShouldTerminate: false); return }
                    if result == .alertThirdButtonReturn {
                        for tab in store.state.workspaces.flatMap(\.tabs) { try await launches.terminate(tab.id) }
                    }
                }
                await surfaces.captureViewports()
                try await store.flush(); surfaces.releaseAll()
#if SPOOKKY_HARNESS
                recordBenchmarkQuit("approved")
#endif
                NSApp.reply(toApplicationShouldTerminate: true)
            } catch {
#if SPOOKKY_HARNESS
                recordBenchmarkQuit("failed", context: ["message": String(error.localizedDescription.prefix(512))])
#endif
                alert("Could not quit safely", error.localizedDescription); NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
    func windowWillClose(_ notification: Notification) {
        sessionLaunch.cancelLaunchPreflight()
        sessionLaunch.startupDeadlineTask?.cancel(); sessionLaunch.startupDeadlineTask = nil; sessionLaunch.startupDeadline = nil
        continuationTask?.cancel()
        files.suspend()
        renderTask?.cancel(); surfaces.invalidate(); contentKey = ""
        Task { await surfaces.captureViewports(); if !window.isVisible { surfaces.releaseAll() }; try? await store.flush() }
    }
    func reopen() {
        startActivityMonitoring()
        if store.state.selected == nil {
            store.update { $0.showLanding(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path) }
        }
        showWindow()
        contentKey = ""; render(); observeRuntimeEvent() }
    func showWindow() {
        let wasVisible = window.isVisible
        if backgroundFixture { window.orderBack(nil) }
        else {
            window.makeKeyAndOrderFront(nil)
            if !wasVisible { window.makeFirstResponder(nil) }
        }
    }
    func setFocus(_ focused: Bool) {
        surfaces.setFocus(focused)
        if focused { startActivityMonitoring(); observeRuntimeEvent() }
    }


    func recordNavigation() {
        guard let id = store.state.selectedWorkspaceID else { return }
        if let occurrence = sidebar.selectedSidebarOccurrence,
           sidebar.sidebarRecords[occurrence]?.id != store.state.selected?.conversationID && sidebar.sidebarWorkspaceIDs[occurrence] != id {
            sidebar.selectedSidebarOccurrence = nil
        }
        if !navigating, navigationIndex < 0 || navigation.indices.contains(navigationIndex) && navigation[navigationIndex] != id {
            navigation = Array(navigation.prefix(navigationIndex + 1)); navigation.append(id)
            if navigation.count > 64 { navigation.removeFirst(navigation.count - 64) }
            navigationIndex = navigation.count - 1
        }
        navigationBack.isEnabled = navigationIndex > 0
        navigationForward.isEnabled = navigationIndex + 1 < navigation.count
    }
    func navigateThread(_ offset: Int) {
        let next = navigationIndex + offset
        guard navigation.indices.contains(next) else { return }
        navigating = true; navigationIndex = next; sidebar.selectedSidebarOccurrence = nil
        sessionLaunch.openConversationWorkspace(navigation[next]); navigating = false; recordNavigation()
    }
    func selectDisplayTab(_ index: Int) {
        guard let workspace = store.state.selected else { return }
        if index == 0 { focusSelectedContent() }
        else if let tabs = workspace.support?.tabs, tabs.indices.contains(index - 1) { store.update { $0.selectSupport(tabs[index - 1].id) }; focusSupportingContent() }
    }
    func openSupportingTool(_ tool: SupportingTool, replacing tabID: UUID) {
        switch tool {
        case .files: chooseSupportingFile(replacing: tabID)
        case .changes: store.update { $0.updateSupport(tabID, target: .changes, title: "Changes") }
        case .terminal: store.update { $0.closeSupport(tabID); $0.newTab() }; if let id = store.state.selectedTab?.id { sessionLaunch.launch(id, tool: .shell) }
        case .artifact: BrowserArtifactContentHost.chooseArtifact(in: window) { [weak self] path in
            self?.store.update { $0.updateSupport(tabID, target: .artifact(path: path), title: (path as NSString).lastPathComponent) }
        }
        }
        focusSupportingContent()
    }
    func showThreadDetails() {
        guard let workspace = store.state.selected else { return }
        let popover = NSPopover(), controller = NSViewController(); detailsPopover = popover
        let title = SpookkyStyle.label(workspace.displayTitle); title.font = .boldSystemFont(ofSize: SpookkyStyle.points(13))
        let provider = SpookkyStyle.label(workspace.displayProvider.displayName)
        let folder = ChromeTextField(wrappingLabelWithString: workspace.directory); folder.isSelectable = true; folder.textColor = SpookkyPalette.secondary
        let review = ActionButton("Changes") { [weak self] in self?.detailsPopover?.performClose(nil); self?.showChanges() }
        review.image = SpookkyStyle.changesImage; review.imagePosition = .imageLeading
        var views: [NSView] = [title, provider, folder]
        if let activity = workspace.activityState { views.append(SpookkyStyle.label(activity.label)) }
        if workspace.displayProvider != .shell && workspace.primaryTerminal?.activity?.displayState == .unknown {
            let help = ChromeTextField(wrappingLabelWithString: "Activity monitoring is unavailable. The provider’s Review action shows Spookky’s local callback definitions before you trust them. They report activity and optional previews to this Mac. Declining keeps the terminal usable, but Working and Needs input cannot be reported.")
            help.font = .systemFont(ofSize: SpookkyStyle.points(11)); help.textColor = SpookkyPalette.secondary
            views.append(help)
        }
        if let primary = workspace.primaryTerminal, primary.binding != nil {
            views.append(ActionButton("Reconnect terminal", symbol: "arrow.clockwise") { [weak self] in
                self?.sessionLaunch.reconnect(primary.id); self?.detailsPopover?.performClose(nil)
            })
            if workspace.displayProvider != .shell, workspace.conversationID == nil {
                let identity = ChromeTextField(wrappingLabelWithString: "The provider has not reported this conversation’s saved ID yet. Keep using this terminal; its saved history will link when the provider reports it.")
                identity.font = .systemFont(ofSize: SpookkyStyle.points(11)); identity.textColor = SpookkyPalette.secondary
                views.append(identity)
            }
            if let startup = primary.startup {
                let text = startup.interactionObserved ? "Native provider activity was observed. This does not prove task success." :
                    "The terminal process is connected. Provider startup and starting-prompt acceptance are not confirmed. Check macOS file-access prompts if the CLI waits while reading other folders. Spookky will not replay input or restart it automatically."
                let status = ChromeTextField(wrappingLabelWithString: text)
                status.font = .systemFont(ofSize: SpookkyStyle.points(11)); status.textColor = SpookkyPalette.secondary
                views.append(status)
                if !primary.draft.prompt.isEmpty {
                    views.append(ActionButton("Copy starting prompt", symbol: "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(primary.draft.prompt, forType: .string)
                    })
                }
                views.append(ActionButton("Focus terminal", symbol: "terminal") { [weak self] in
                    self?.detailsPopover?.performClose(nil); self?.focusSelectedContent()
                })
                if primary.pendingStartup != nil {
                    views.append(ActionButton("Dismiss startup notice") { [weak self] in
                        self?.store.update { $0.dismissStartupNotice(primary.id) }; self?.detailsPopover?.performClose(nil)
                    })
                }
            }
        }
        views.append(review)
        if let branch = (workspace.anchor ?? workspace.selectedLocation).branch { views.append(SpookkyStyle.label("Branch: " + branch)) }
        for warning in sidebar.providerHistoryNotices.sorted() {
            let field = ChromeTextField(wrappingLabelWithString: warning); field.font = .systemFont(ofSize: SpookkyStyle.points(11)); field.textColor = SpookkyPalette.secondary; views.append(field)
        }
        for tab in workspace.support?.tabs ?? [] {
            if case .artifact = tab.target { views.append(ActionButton(tab.displayTitle, symbol: "doc.richtext") { [weak self] in self?.store.update { $0.selectSupport(tab.id) }; self?.detailsPopover?.performClose(nil) }) }
        }
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = SpookkyStyle.points(12)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.widthAnchor.constraint(equalToConstant: 320).displayScaled().isActive = true
        controller.view = stack; popover.contentViewController = controller; popover.behavior = .transient
        let anchor = compactHeader ? threadActions : threadDetails
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

}
