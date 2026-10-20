import AppKit
import Darwin
import SpookkyCore
import SpookkyFiles
import SpookkyRuntime
import SpookkyWorkspace
import SpookkyGit

@MainActor final class WorkspaceWindowController: NSObject, NSWindowDelegate, NSMenuItemValidation, NSSearchFieldDelegate {
    private(set) var window: WorkspaceNativeWindow!
    let store: WorkspaceStore
    let services = AppServices()
    private let locations: LocationCoordinator
    private var repositoryRefreshTask: Task<Void, Never>?
    private var repositorySnapshots: [UUID: RepositorySnapshot] = [:]
    private var repositoryGenerations: [UUID: UUID] = [:]
    private var projectCreation: ProjectCreationController?
    private let sessionCatalog: any SessionCatalogReading
    private let associationResolver = ProjectAssociationResolver()
    var historyRefreshTask: Task<Void, Never>?
    private var historyGeneration = UUID()
    private var historyProjectSignature = ""
    private var historyQuerySignature = ""
    private var historyActivationObserver: NSObjectProtocol?
    private var historyRefreshedAt: Date?
    private let savedConversationResolver: any ExecutableResolver
    private var continuingConversations = Set<ConversationID>()
    private var pendingIdentities = Set<UUID>()
    private var conversationOpenTask: Task<Void, Never>?
    private var preflightConversation: ConversationID?
    private var continuationTokens: [ConversationID: UUID] = [:]
    private var historySearchTask: Task<Void, Never>?
    private var initialLaunchTasks: [UUID: Task<Void, Never>] = [:]
    private var continuationErrors: [ConversationID: String] = [:]
    private lazy var historyCatalog = ConversationHistoryCatalog(reader: sessionCatalog, persistence: store.historyPersistence)
    private var historyRecords: [String: [ConversationCatalogRecord]] = [:]
    private var historyPageLimits: [String: Int] = [:]
    private var historyCursors: [String: String] = [:]
    private var historyHasMore = Set<String>()
    private var historyIssues: [String: String] = [:]
    private let historyWatcher = HistorySourceWatcher()
    let conversationSidebar = WorkspaceSidebarView(frame: .zero)
    private var sidebarRecords: [String: ConversationCatalogRecord] = [:]
    private let sidebarPRService = GitHubPullRequestService()
    private var sidebarGit: [String: (checkout: SidebarCheckoutInfo?, pr: PullRequestStatus?, date: Date)] = [:]
    private var sidebarGitTask: Task<Void, Never>?
    private var sidebarGitTimer: Timer?
    private var sidebarGitGeneration = UUID()
    private var sidebarVisibleItems: [WorkspaceSidebarItem] = []
    let historySearch = ChromeSearchField()
    let launches: LaunchCoordinator
    let surfaces: TerminalSurfaceManager
    private lazy var projectAssociations = ProjectAssociationCoordinator(store: store)
    private let diagnostics: WorkspaceDiagnostics?
    private let rail = NSStackView()
    private let tabs = NSStackView()
    private let body = NSView()
    private let supportingTerminal = NSView()
    private lazy var workspaceLayout = SupportingWorkspaceView(primary: body)
    var supportingContentHost: (any SupportingContentHost)? { didSet { supportContentKey = ""; render() } }
    private var supportContentKey = ""

    private lazy var files = FileWorkspaceController(store: store, terminal: NSView()) { [weak self] in
        guard let self, let id = store.state.selectedTab?.id else { return }
        if let surface = surfaces.view(id) { window.makeFirstResponder(surface) }
        else { composers[id]?.focus() }
    }
    private let sidebarToggle = ActionButton("", symbol: "sidebar.left", help: "Collapse workspace sidebar · ⌘B", action: {})
    private let tabOverflow = ActionButton("", symbol: "chevron.down", help: "All tabs", action: {})
    private let header = WorkspaceHeaderView()
    private var toggleLeading: NSLayoutConstraint!
    private var navigationLeading: NSLayoutConstraint!
    private var tabsLeading: NSLayoutConstraint!
    private var tabsWidth: NSLayoutConstraint!
    private var supportHeaderLeading: NSLayoutConstraint!
    private var workspaceBottom: NSLayoutConstraint!
    private var overflowWidth: NSLayoutConstraint!
    private var updatingHeader = false
    private let cancelLocation = ActionButton("Cancel operation", action: {})
    private let warning = SpookkyStyle.label( "")
    private let railScroll = NSScrollView()
    private let tabScroll = TabStripScrollView()
    private let sidebarDivider = FileDivider()
    private var railWidth: NSLayoutConstraint!
    private var composers: [UUID: LaunchComposerView] = [:]
    private var contentKey = ""
    private var navigation: [UUID] = []
    private var navigationIndex = -1
    private var navigating = false
    private var filePicker: WorkspaceFilePicker?
    private var detailsPopover: NSPopover?
    private var startPages: [UUID: SupportingStartPage] = [:]
    private var selectedSidebarOccurrence: String?
    private var sectionLimits: [String: Int] = [:]
    private var sidebarWorkspaceIDs: [String: UUID] = [:]
    private var showingArchived = false
    private var providerHistoryNotices = Set<String>()
    private let navigationBack = ActionButton("", symbol: "chevron.left", help: "Previous thread", action: {})
    private let navigationForward = ActionButton("", symbol: "chevron.right", help: "Next thread", action: {})
    private let threadDetails = ActionButton("", symbol: "slider.horizontal.3", help: "Thread details", action: {})
    private let threadActions = ActionButton("", symbol: "ellipsis", help: "Thread actions", action: {})

    var renderTask: Task<Void, Never>?
    private var closing = Set<UUID>()
    private let runtimeEvents: RuntimeEventMonitor
    private var observationTask: Task<Void, Never>?
    private var observationRequested = false
    private var continuationTask: Task<Void, Never>?
    private lazy var continuations = ConversationContinuationCoordinator(store: store)
    var continuationMetadata: ((ConversationID) -> ConversationMetadata?)? {
        didSet { continuations.metadata = continuationMetadata }
    }
    private var wakeObserver: NSObjectProtocol?
    private var displayOptionsObserver: NSObjectProtocol?
    var chromeRevision = ""
    private var sidebarRevision = ""
    private var tabRevision = ""
    private var tabPairs: [UUID: WorkspaceTabView] = [:]
    private var fullscreenTransition = false
    private var announcedError: String?
    private var renameEditor: InlineRenameEditor?
    private var paneHeaders: [UUID: ChromeStackView] = [:]
    private var paneTitles: [UUID: NSTextField] = [:]
    private var agentHeaderLabels: [UUID: NSTextField] = [:]
    private var activityReceiver: AgentActivityReceiver?
    private let agentNotifications = AgentNotifications()
    private let activityRoot: URL
    private var knownActivityBindings = Set<UUID>()
    private var knownActivityTabs = Set<UUID>()
    private var acknowledgmentTasks: [UUID: Task<Void, Never>] = [:]
    private var agentPreferencesTask: Task<Void, Never>?
    private let backgroundFixture: Bool
    private var fixtureCloseRequests: [[String: String]] = []

    init(root: URL, initialStore: WorkspaceStore? = nil,
         resolver: any ExecutableResolver = CLIResolver(), backgroundFixture: Bool = false,
         catalog: (any SessionCatalogReading)? = nil) throws {
        let paths = AppPaths(bundleID: Bundle.main.bundleIdentifier, home: FileManager.default.homeDirectoryForCurrentUser, userID: getuid())
        self.backgroundFixture = backgroundFixture
        let fixture = backgroundFixture || CommandLine.arguments.contains { $0.hasPrefix("--workspace-benchmark") }
        let historyFixture = CommandLine.arguments.contains("--workspace-benchmark-history")
        sessionCatalog = catalog ?? (historyFixture ? SyntheticHistoryCatalog(root: root) as any SessionCatalogReading : (fixture ? EmptySessionCatalog() as any SessionCatalogReading : SessionCatalog()))
        savedConversationResolver = historyFixture ? HistoryFixtureResolver(root: root) : resolver
        activityRoot = root
        let store = initialStore ?? WorkspaceStore()
        self.store = store
        try PrivateFiles.directory(root)
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("spookky-launch").path
        runtimeEvents = try RuntimeEventMonitor(root: root)
        let tmux = try PackagedRuntime.tmux()
        let actionLog = CommandLine.arguments.contains("--workspace-benchmark-continuity") ? root.appendingPathComponent("runtime-actions.json") : nil
        let baseRuntime = try TmuxRuntime(executable: tmux, helper: helper, root: root, eventFile: runtimeEvents.eventFile, actionLog: actionLog)
        let runtime: any SessionViewportRuntime
        if (CommandLine.arguments.contains("--workspace-benchmark-races") || CommandLine.arguments.contains("--workspace-benchmark-sidebar")), CommandLine.arguments.contains("--workspace-benchmark-count"),
           root.path.hasPrefix("/tmp/spookky-m1-"), ProcessInfo.processInfo.environment["SPOOKKY_M1_DATA"] != nil {
            runtime = WorkspaceViewportFixtureRuntime(baseRuntime)
        } else { runtime = baseRuntime }
        locations = LocationCoordinator(store: store, runtime: runtime, operationRoot: root.appendingPathComponent("git-operations"))
        let clipboard = CommandLine.arguments.contains("--workspace-benchmark-selection")
            ? NSPasteboard(name: NSPasteboard.Name("dev.spookky.selection-fixture." + root.lastPathComponent)) : .general
        let engine = try GhosttyEngine(root: root, clipboard: clipboard)
        launches = LaunchCoordinator(store: store, runtime: runtime,
            resolver: AgentActivityResolver(base: savedConversationResolver, root: root, helper: helper))
        surfaces = TerminalSurfaceManager(engine: engine, runtime: runtime, executable: tmux, root: root)
        diagnostics = WorkspaceDiagnostics(root: root)
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
        activityReceiver = try? AgentActivityReceiver(root: root) { [weak self] event in
            Task { @MainActor [weak self] in self?.receiveAgentEvent(event) }
        }
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
        diagnostics?.visibility = { [weak self] in self?.window.occlusionState.contains(.visible) == true }
        historyProjectSignature = catalogProjectSignature()
        historySearch.placeholderString = "Search"; historySearch.delegate = self
        historySearch.sendsSearchStringImmediately = true
        historySearch.setAccessibilityLabel("Search all saved conversations")
        store.onChange = { [weak self] in
            guard let self else { return }; render(); refreshAgentAttention()
            if historyProjectSignature != catalogProjectSignature() { requestCatalogRefresh(force: false) }
        }
        if CommandLine.arguments.contains("--workspace-benchmark-timing") || CommandLine.arguments.contains("--workspace-benchmark-restoring") {
        diagnostics?.historyMarker = { [weak self] in
            guard let self, let id = self.store.state.selectedTab?.id else { return nil }
            return self.surfaces.fixtureHistoryMarker(id)
        }
        }
        surfaces.onExit = { [weak self] id in
            guard let self else { return }
            Task { await self.launches.reconcile(id); self.handleClientExit(id) }
        }
        surfaces.onFocus = { [weak self] id in
            guard let self, self.store.state.selectedTab?.id != id else { return }
            self.store.update { $0.selectTab(id) }
        }
        surfaces.onOpenURL = { [weak self] id, url in
            guard let self, let workspace = store.state.workspace(containing: id),
                  let target = ConversationLinks.target(for: url, scopePath: workspace.anchor?.scopePath ?? workspace.directory) else { return false }
            let title = url.isFileURL ? url.lastPathComponent : (url.host ?? "Browser")
            store.update { $0.openSupport(target, title: title, workspaceID: workspace.id) }
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
        if let host = supportingContentHost as? BrowserArtifactContentHost {
            try SupportingPreviewFixture.recordRestoration(host: host, state: store.state, root: root)
        }
        if backgroundFixture && (window.isKeyWindow || window.isMainWindow) {
            throw LaunchError.invalid("Background fixture took native window focus.")
        }
        Task {
            await locations.reconcileAll()
            await refreshSelectedRepository()
            observeRuntimeEvent()
            requestCatalogRefresh(force: false)
        }
        historyWatcher.onChange = { [weak self] in self?.requestCatalogRefresh(force: true) }
        historyWatcher.start(roots: sessionCatalog.historySourceRoots)
        historyActivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestCatalogRefresh(force: true) }
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
    private func saveAgentPreferences(_ preferences: AgentNotificationPreferences) {
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
    private func agentTargetVisible(_ id: UUID) -> Bool {
        guard NSApp.isActive, window.isKeyWindow, window.occlusionState.contains(.visible),
              store.state.visibleTabIDs.contains(id), let surface = surfaces.view(id) else { return false }
        return surface.window === window && !surface.isHiddenOrHasHiddenAncestor
    }
    private func refreshAgentAttention(clearManual: Bool = false) {
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
                defer {
                    acknowledgmentTasks[id] = nil
                    if let latest = store.state.tab(id)?.activity, latest.unread,
                       latest.completionID != receipt.completionID || latest.invocationID != receipt.invocationID ||
                       surfaces.view(id) !== observedView || observedView?.viewportRevision != viewportRevision {
                        refreshAgentAttention(clearManual: clearManual)
                    }
                }
                let atBottom = try? await surfaces.viewportAtBottom(id)
                guard !Task.isCancelled, agentTargetVisible(id) else { return }
                var acknowledged = false
                store.update(debounced: true) { acknowledged = $0.acknowledgeAgent(id, receipt: receipt, viewportAtBottom: atBottom ?? nil) }
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
    private func receiveAgentEvent(_ event: AgentEvent) {
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
        if activity.sessionID != old?.sessionID || activity.provider != old?.provider { requestCatalogRefresh(force: false) }
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
    private func changeAgentAttention(_ ids: [UUID], action: String) {
        store.update(debounced: true) { state in
            for id in ids {
                if action == "unread" { state.markAgentUnread(id) }
                else if action == "read" { state.acknowledgeAgent(id) }
                else { state.resetAgent(id) }
            }
        }
        if action != "unread" { for id in ids { agentNotifications.clear(id) } }
    }
    private func addAgentActions(_ menu: NSMenu, ids: [UUID]) {
        guard ids.contains(where: { store.state.tab($0)?.activity != nil }) else { return }
        menu.addItem(.separator())
        for (title, action) in [("Mark unread", "unread"), ("Mark read", "read"), ("Reset activity status", "reset")] {
            menu.addItem(ClosureMenuItem(title) { [weak self] in self?.changeAgentAttention(ids, action: action) })
        }
    }
    private func addContinuationAction(_ menu: NSMenu, workspaceID: UUID) {
        guard (try? continuations.capture(workspaceID: workspaceID)) != nil else { return }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Continue elsewhere…") { [weak self] in self?.showContinuation(workspaceID) })
    }
    private func showContinuation(_ workspaceID: UUID) {
        guard continuationTask == nil, window.attachedSheet == nil else { return }
        let target: ConversationContinuationTarget
        do { target = try continuations.capture(workspaceID: workspaceID) }
        catch { alert("Continuation unavailable", error.localizedDescription); return }
        continuationTask = Task { [weak self] in
            guard let self else { return }
            defer { continuationTask = nil }
            do {
                guard let presentation = try await continuations.prepare(target), window.isVisible,
                      window.attachedSheet == nil, continuations.isCurrent(target) else { return }
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
                    guard continuations.isCurrent(target) else { return }
                    await surfaces.captureViewports()
                    guard await continuations.reconnect(target, using: launches) else { return }
                    surfaces.release(target.terminalID)
                    store.update {
                        $0.selectWorkspace(target.workspaceID); $0.selectPrimaryContent(workspaceID: target.workspaceID)
                    }
                    guard let reopened = try? continuations.capture(workspaceID: target.workspaceID),
                          reopened.terminalID == target.terminalID, reopened.conversationID == target.conversationID,
                          reopened.directory == target.directory, reopened.binding == target.binding else { return }
                    contentKey = ""; render()
                    if let renderTask { await renderTask.value }
                    if continuations.isCurrent(reopened) { focusSelectedContent() }
                } else if let view = previousResponder as? NSView, view.window === window {
                    window.makeFirstResponder(view)
                }
            } catch {
                if !Task.isCancelled, window.isVisible, continuations.isCurrent(target) {
                    alert("Continuation unavailable", error.localizedDescription)
                }
            }
        }
    }
    private func observeRuntimeEvent() {
        observationRequested = true
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self else { return }
            defer { self.observationTask = nil }
            await reconcileProviderIdentities()
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
    deinit {
        sidebarGitTask?.cancel(); sidebarGitTimer?.invalidate()
        for task in acknowledgmentTasks.values { task.cancel() }
        historyRefreshTask?.cancel()
        conversationOpenTask?.cancel(); historySearchTask?.cancel()
        let watcher = historyWatcher
        Task { @MainActor in watcher.stop() }
        if let historyActivationObserver { NotificationCenter.default.removeObserver(historyActivationObserver) }
        let ownedSurfaces = surfaces
        Task { @MainActor in ownedSurfaces.stopFollowingAppearance() }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let displayOptionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver) }
        observationTask?.cancel(); continuationTask?.cancel()
    }
    private func buildWindow() {
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
        cancelLocation.handler = { [weak self] in guard let self else { return }; locations.activeOperationIDs.forEach { self.locations.cancel($0) } }
        for view in [header, railScroll, tabScroll, workspaceLayout.headerView, workspaceBody, sidebarToggle, tabOverflow, sidebarDivider, warning, cancelLocation, navigationBack, navigationForward, threadDetails, threadActions] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        rail.translatesAutoresizingMaskIntoConstraints = false; tabs.translatesAutoresizingMaskIntoConstraints = false
        navigationBack.handler = { [weak self] in self?.navigateThread(-1) }
        navigationForward.handler = { [weak self] in self?.navigateThread(1) }
        threadDetails.handler = { [weak self] in self?.showThreadDetails() }
        threadActions.handler = { [weak self] in
            guard let self, let id = store.state.selectedWorkspaceID else { return }
            workspaceContextMenu(id).popUp(positioning: nil, at: NSPoint(x: 0, y: threadActions.bounds.minY), in: threadActions)
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
            threadDetails.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8).displayScaled(),
            threadActions.trailingAnchor.constraint(equalTo: threadDetails.leadingAnchor, constant: -4).displayScaled(),
            tabOverflow.trailingAnchor.constraint(equalTo: threadActions.leadingAnchor, constant: -4).displayScaled(), overflowWidth,
            threadDetails.widthAnchor.constraint(equalToConstant: 28).displayScaled(), threadDetails.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            threadActions.widthAnchor.constraint(equalToConstant: 28).displayScaled(), threadActions.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            threadDetails.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor), threadActions.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor),
            navigationBack.widthAnchor.constraint(equalToConstant: 28).displayScaled(), navigationBack.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            navigationForward.widthAnchor.constraint(equalToConstant: 28).displayScaled(), navigationForward.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            navigationBack.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor), navigationForward.centerYAnchor.constraint(equalTo: sidebarToggle.centerYAnchor),
            navigationForward.leadingAnchor.constraint(equalTo: navigationBack.trailingAnchor),
            tabOverflow.topAnchor.constraint(equalTo: content.topAnchor, constant: 6).displayScaled(), tabOverflow.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            workspaceBody.leadingAnchor.constraint(equalTo: railScroll.trailingAnchor), workspaceBody.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            workspaceBody.topAnchor.constraint(equalTo: tabScroll.bottomAnchor), workspaceBottom,
            warning.leadingAnchor.constraint(equalTo: workspaceBody.leadingAnchor, constant: 12).displayScaled(),
            warning.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8).displayScaled(),
            warning.trailingAnchor.constraint(lessThanOrEqualTo: cancelLocation.leadingAnchor, constant: -8).displayScaled(),
            cancelLocation.trailingAnchor.constraint(equalTo: workspaceBody.trailingAnchor, constant: -12).displayScaled(),
            cancelLocation.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4).displayScaled()
        ])
    }
    private func updateHeaderGeometry() {
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
        let available = max(0, content.bounds.width - tabStart - SpookkyStyle.points(20))
        let splitStart = width + workspaceLayout.primaryPaneWidth(in: max(0, content.bounds.width - width)) + 5
        let mainWidth = workspaceLayout.joinsPrimary ? 0 : workspaceLayout.isSplit ? max(0, splitStart - tabStart - 5) : min(tabs.fittingSize.width, available)
        let supportStart = workspaceLayout.joinsPrimary ? tabStart : workspaceLayout.isSplit ? splitStart : tabStart + mainWidth
        let supportWidth = max(0, content.bounds.width - SpookkyStyle.points(20) - supportStart)
        let overflowing = (!workspaceLayout.joinsPrimary && tabs.fittingSize.width > mainWidth) || workspaceLayout.headerFittingWidth > supportWidth
        tabOverflow.isHidden = !overflowing
        if overflowWidth.constant != (overflowing ? SpookkyStyle.points(28) : 0) { overflowWidth.constant = overflowing ? SpookkyStyle.points(28) : 0 }
        if !workspaceLayout.joinsPrimary { for item in tabPairs.values { item.availableWidth = mainWidth } }
        if tabsWidth.constant != mainWidth { tabsWidth.constant = mainWidth }
        if supportHeaderLeading.constant != supportStart { supportHeaderLeading.constant = supportStart }
        tabScroll.isHidden = store.state.selected == nil || workspaceLayout.joinsPrimary
        workspaceLayout.headerView.isHidden = store.state.selected == nil
    }
    private func showTabOverflow() {
        guard let workspace = store.state.selected else { return }
        tabOverflowMenu(workspace).popUp(positioning: nil, at: NSPoint(x: 0, y: tabOverflow.bounds.height), in: tabOverflow)
    }
    private func tabOverflowMenu(_ workspace: Workspace) -> NSMenu {
        let menu = NSMenu()
        let primary = ClosureMenuItem(workspace.displayTitle) { [weak self] in self?.focusSelectedContent() }
        primary.image = SpookkyStyle.toolImage(workspace.displayProvider); menu.addItem(primary)
        for tab in workspace.support?.tabs ?? [] {
            let item = ClosureMenuItem(tab.displayTitle) { [weak self] in
                self?.store.update { $0.selectSupport(tab.id) }; self?.focusSupportingContent()
            }
            item.representedObject = tab.id
            item.image = NSImage(systemSymbolName: SpookkyStyle.supportingSymbol(tab.target), accessibilityDescription: nil)
            item.state = tab.id == workspace.support?.selectedTabID ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New chat") { [weak self] in self?.newWorkspace() })
        return menu
    }
    @objc private func toggleWorkspaceSidebar() { store.update { $0.sidebarCollapsed.toggle() } }
    @objc private func toggleCodeSidebar() {
        if (supportingContentHost as? BrowserArtifactContentHost)?.focusAddress(in: window) == true { return }
        if workspaceLayout.showsSupportingContent { store.update { $0.setSupportingLayout(.collapsed) }; focusSelectedContent() }
        else if store.state.selected?.support?.tabs.isEmpty == false { store.update { $0.setSupportingLayout(.split) } }
        else { store.update { $0.openSupport(.changes, title: "Changes") } }
    }
    private func chooseSupportingFile(replacing tabID: UUID? = nil) {
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
        picker.show(relativeTo: threadDetails)
    }
    private func renderSupportingContent() {
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
    private func buildMenu() {
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
        view.addItem(ClosureMenuItem("Refresh conversations") { [weak self] in self?.requestCatalogRefresh(force: true) })
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
        view.addItem(ClosureMenuItem("Archived threads") { [weak self] in self?.showingArchived.toggle(); self?.chromeRevision = ""; self?.render() })
        view.addItem(ClosureMenuItem("Open file…") { [weak self] in self?.chooseSupportingFile() })
        view.addItem(ClosureMenuItem("Toggle file tree") { [weak self] in self?.files.toggle() })
        view.addItem(ClosureMenuItem("Reset activity status") { [weak self] in if let ids = self?.store.state.selected?.tabs.map(\.id) { self?.changeAgentAttention(ids, action: "reset") } })
        view.addItem(ClosureMenuItem("Thread details") { [weak self] in self?.showThreadDetails() })
        view.addItem(ClosureMenuItem("Review changes") { [weak self] in self?.store.update { $0.openSupport(.changes, title: "Changes") }; self?.files.focusSidebar() })
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
    private var activeInputEditor: NSTextView? {
        guard let editor = (window.attachedSheet?.firstResponder ?? window.firstResponder) as? NSTextView,
              editor.isEditable, editor is PromptTextView || editor.isFieldEditor else { return nil }
        return editor
    }
    @objc private func undoInput() { activeInputEditor?.undoManager?.undo() }
    @objc private func redoInput() { activeInputEditor?.undoManager?.redo() }
    @objc private func zoomIn() { services.changeDisplay { $0.stepZoom(1) } }
    @objc private func zoomOut() { services.changeDisplay { $0.stepZoom(-1) } }
    @objc private func actualSize() { services.changeDisplay { $0.zoom = 1 } }
    private func handleCommand(_ event: NSEvent) -> Bool {
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
                launchSelected()
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
    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }
    func render() {
        let state = store.state
        let activeLocation = state.locations?.operations.first { $0.status == .running }
        cancelLocation.isHidden = activeLocation == nil
        let appearanceName: NSAppearance.Name? = state.appearance == .system ? nil : state.appearance == .dark ? .darkAqua : .aqua
        if window.appearance?.name != appearanceName { window.appearance = appearanceName.flatMap(NSAppearance.init(named:)) }
        surfaces.setTheme(dark: window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        updateHeaderGeometry()
        window.contentView?.layoutSubtreeIfNeeded()
        renderSupportingContent()
        files.update(state.selected, operation: state.locations?.operations.last(where: { $0.status == .complete })?.request.id)
        files.layout.layoutSubtreeIfNeeded()
        let lastOperation = state.locations?.operations.last
        let locationNotice = lastOperation.flatMap { [.failed, .uncertain, .cancelled].contains($0.status) ? $0.request.kind.rawValue.capitalized + " · " + ($0.error ?? $0.request.destination) : nil }
        warning.stringValue = store.saveError ?? activeLocation.map { $0.request.kind.rawValue.capitalized + " · " + $0.request.destination } ?? locationNotice ?? ""
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
        let historyChrome = historyRecords.keys.sorted().map { key in key + (historyRecords[key] ?? []).map { $0.id.sessionID + $0.displayTitle }.joined() }.joined() + historyHasMore.sorted().joined()
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
                composers[id]?.repositorySnapshot = w.projectID.flatMap { repositorySnapshots[$0] }
                composers[id]?.update(tab, workspace: w, state: state)
            }
        }
        guard key != contentKey else { return }
        contentKey = key; renderTask?.cancel(); surfaces.invalidate()
        if !workspaceLayout.hasFocus { window.makeFirstResponder(nil) }
        let started = ProcessInfo.processInfo.systemUptime
        renderTask = Task { [weak self] in await self?.renderContent(started: started) }
    }
    private func renderChrome() {
        let state = store.state, collapsed = state.sidebarCollapsed
        recordNavigation()
        threadActions.isEnabled = state.selected?.isLanding == false
        renderConversationSidebar(state, collapsed: collapsed)
        let tabsKey = String(describing: state.selectedWorkspaceID) + String(describing: state.selected?.primaryTerminalID)
        if tabsKey != tabRevision {
            renameEditor?.cancel(); renameEditor = nil
            tabRevision = tabsKey; tabPairs.removeAll(); clear(tabs)
            if let workspace = state.selected, let terminal = workspace.primaryTerminal {
                let item = WorkspaceTabView(title: workspace.displayTitle,
                    image: SpookkyStyle.toolImage(workspace.displayProvider), closable: false,
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
                guard let self else { return nil }; return self.workspaceContextMenu(workspace.id)
            }
        }
        updateHeaderGeometry()
    }
    func historyFixtureRecords(_ key: String) -> [ConversationCatalogRecord] { historyRecords[key] ?? [] }
    func catalogProjectSignature() -> String {
        store.state.projects.map { $0.id.uuidString + $0.location.path }.joined(separator: "\n")
    }
    private func historyExclusions(for projectID: UUID?, allProjects: Bool = false) -> Set<ConversationID> {
        let state = store.state
        var excluded = state.archivedConversationIDs
        guard !allProjects else { return excluded }
        for entry in (state.threadPresentations ?? [:]).values where entry.hasProjectOverride && entry.projectOverride != projectID {
            if let id = entry.conversation?.id { excluded.insert(id) }
        }
        for workspace in state.workspaces {
            let entry = state.presentation(for: workspace.threadKey)
            if entry.hasProjectOverride && entry.projectOverride != projectID, let id = workspace.conversationID { excluded.insert(id) }
        }
        return excluded
    }
    private func reconcileProviderIdentities() async {
        for workspace in store.state.workspaces where workspace.conversationID == nil {
            guard let primary = workspace.primaryTerminal, let binding = primary.binding, binding.tool == .codex else { continue }
            let path = activityRoot.appendingPathComponent("agent-identity-" + binding.id.uuidString + ".json").path
            let receipt = await Task.detached { try? AgentIntegration.read(ProviderIdentityReceipt.self, path: path) }.value
            guard let receipt, receipt.bindingID == binding.id, !receipt.candidates.isEmpty else { continue }
            let contextPath = activityRoot.appendingPathComponent("agent-terminal-" + binding.id.uuidString + ".json").path
            let context = await Task.detached { try? AgentIntegration.read(AgentTerminalContext.self, path: contextPath) }.value
            guard context?.secret == receipt.secret else { continue }
            guard pendingIdentities.insert(binding.id).inserted else { continue }
            defer { pendingIdentities.remove(binding.id) }
            guard let metadata = await ProviderIdentityResolver.codex(candidates: receipt.candidates, directory: binding.directory),
                  !Task.isCancelled, store.state.tab(primary.id)?.binding == binding else { continue }
            store.update { state in
                state.associateConversation(provider: .codex, sessionID: metadata.id.sessionID, title: metadata.title, workspaceID: workspace.id)
                state.recordCatalogMetadata(metadata, workspaceID: workspace.id, projectID: workspace.projectID)
            }
        }
    }
    func requestCatalogRefresh(force: Bool) {
        let signature = catalogProjectSignature() + "|" + historySearch.stringValue
        if historyRefreshTask != nil && !force && signature == historyQuerySignature { return }
        historyProjectSignature = catalogProjectSignature(); historyQuerySignature = signature
        historyRefreshTask?.cancel()
        let token = UUID(); historyGeneration = token
        let projects = store.state.projects, locations = store.state.locations
        let query = historySearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        historyRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if historyGeneration == token { historyRefreshTask = nil } }
            do {
                await reconcileProviderIdentities()
                if force { await sessionCatalog.invalidatePages() }
                if !query.isEmpty {
                    let limit = historyPageLimits["search"] ?? 10
                    let cached = try await historyCatalog.cached(allProjects: true, search: query, limit: limit, excluding: historyExclusions(for: nil, allProjects: true))
                    try Task.checkCancellation()
                    historyRecords["search"] = cached
                    chromeRevision = ""; render()
                    try await refreshHistoryGroup("search", projects: projects, locations: locations, query: query, reset: true, force: false)
                } else {
                    for projectID in projects.map(\.id).map(Optional.some) + [nil] {
                        let key = projectID?.uuidString ?? "unbound"
                        let cached = try await historyCatalog.cached(projectID: projectID, limit: historyPageLimits[key] ?? 5, excluding: historyExclusions(for: projectID))
                        try Task.checkCancellation()
                        historyRecords[key] = cached
                    }
                    chromeRevision = ""; render()
                    // Discover recent external worktrees without enumerating the provider's full history.
                    _ = try await historyCatalog.refresh(query: HistoryQuery(limit: 10), projects: projects, force: false)
                    for project in projects where project.isCollapsed != true {
                        try Task.checkCancellation()
                        try await refreshHistoryGroup(project.id.uuidString, projects: projects, locations: locations, query: "", reset: true, force: false)
                    }
                    try await refreshHistoryGroup("unbound", projects: projects, locations: locations, query: "", reset: true, force: false)
                }
                guard !Task.isCancelled, historyGeneration == token else { return }
                historyRefreshedAt = Date(); chromeRevision = ""; render()
            } catch is CancellationError { }
            catch {
                guard historyGeneration == token else { return }
                historyIssues[query.isEmpty ? "unbound" : "search"] = error.localizedDescription
                chromeRevision = ""; render()
            }
        }
    }
    private func refreshHistoryGroup(_ key: String, projects: [Project], locations: LocationMetadata?, query: String,
                                     reset: Bool, force: Bool) async throws {
        let projectID = UUID(uuidString: key), isSearch = key == "search"
        let limit = historyPageLimits[key] ?? (isSearch ? 10 : 5)
        let project = projectID.flatMap { id in projects.first { $0.id == id } }
        let directories: [String]
        if let project { directories = try await historyCatalog.directories(for: project, locations: locations) }
        else { directories = [] }
        var cursor = reset ? nil : historyCursors[key]
        var page: CatalogPage?
        for attempt in 0..<8 {
            try Task.checkCancellation()
            page = try await historyCatalog.refresh(query: HistoryQuery(projectID: projectID, directories: directories,
                search: query, limit: reset && attempt == 0 ? (isSearch ? 10 : 5) : 10, cursor: cursor,
                exactDirectories: project != nil, titleSearchOnly: isSearch && !query.contains("/") && UUID(uuidString: query) == nil), projects: projects, force: force && attempt == 0)
            try Task.checkCancellation()
            cursor = page?.nextCursor
            let cached = try await historyCatalog.cached(projectID: projectID, allProjects: isSearch, search: query, limit: limit + 1, excluding: historyExclusions(for: projectID, allProjects: isSearch))
            try Task.checkCancellation()
            historyRecords[key] = Array(cached.prefix(limit))
            if cached.count > limit || cursor != nil { historyHasMore.insert(key) } else { historyHasMore.remove(key) }
            historyCursors[key] = cursor
            for issue in page?.issues ?? [] where !issue.message.hasPrefix("No local Claude Code history") { providerHistoryNotices.insert(issue.message) }
            historyIssues[key] = nil
            if let page {
                store.update { state in
                    for record in page.records {
                        if state.threadPresentations?[record.id.threadKey] != nil { state.rememberThread(record) }
                        if let workspace = state.workspace(for: record.id) {
                            state.recordCatalogMetadata(record.metadata, workspaceID: workspace.id, projectID: record.projectID)
                        }
                    }
                }
            }
            chromeRevision = ""; render()
            if cached.count >= limit || cursor == nil { break }
        }
    }
    private func showMoreHistory(_ key: String) {
        if ["pinned", "recents", "archived"].contains(key) { sectionLimits[key] = (sectionLimits[key] ?? 5) + 10; chromeRevision = ""; render(); return }
        historyPageLimits[key] = (historyPageLimits[key] ?? (key == "search" ? 10 : 5)) + 10
        historyRefreshTask?.cancel()
        let token = UUID(); historyGeneration = token
        let projects = store.state.projects, locations = store.state.locations
        let query = historySearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        historyRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if historyGeneration == token { historyRefreshTask = nil } }
            do {
                try await refreshHistoryGroup(key, projects: projects, locations: locations, query: query, reset: false, force: false)
            } catch is CancellationError { }
            catch { historyIssues[key] = error.localizedDescription; chromeRevision = ""; render() }
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === historySearch else { return }
        historyPageLimits["search"] = 10
        historySearchTask?.cancel(); historyRefreshTask?.cancel()
        historySearchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            requestCatalogRefresh(force: true)
        }
    }
    func openConversationWorkspace(_ id: UUID) {
        guard let workspace = store.state.workspaces.first(where: { $0.id == id }) else { return }
        if let identity = workspace.conversationID, continuingConversations.contains(identity), store.state.selectedWorkspaceID == id { return }
        cancelLaunchPreflight()
        selectWorkspace(id)
        guard let primary = workspace.primaryTerminal, let identity = workspace.conversationID else { return }
        let item = workspace.catalogMetadata ?? ConversationMetadata(id: identity, title: workspace.displayTitle,
            directory: primary.launch?.directory ?? primary.startDirectory ?? workspace.directory, updatedAt: Date())
        guard identity == item.id else { return }
        guard !continuingConversations.contains(item.id) else { return }
        if workspace.conversationOwnershipAmbiguous == true {
            continuationErrors[item.id] = "More than one retained terminal reports this conversation. Reconnect its original terminal before resuming."
            contentKey = ""; render(); return
        }
        let token = UUID(); continuationTokens[item.id] = token; preflightConversation = item.id
        continuingConversations.insert(item.id); continuationErrors[item.id] = nil
        contentKey = ""; render()
        conversationOpenTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if continuationTokens[item.id] == token {
                    continuingConversations.remove(item.id); continuationTokens[item.id] = nil
                    if preflightConversation == item.id { preflightConversation = nil; conversationOpenTask = nil }
                    contentKey = ""; render()
                }
            }
            do {
                if primary.binding != nil || primary.launch != nil {
                    await launches.reconcile(primary.id)
                    try Task.checkCancellation()
                    guard store.state.selectedWorkspaceID == id, let observed = store.state.tab(primary.id) else { return }
                    if observed.status == .running { reconnect(primary.id); return }
                    guard observed.status == .ended else { return }
                }
                if item.availability == .historyUnavailable {
                    throw LaunchError.invalid("The provider's saved history is unavailable. Restore it, then retry this conversation.")
                }
                let assessment = await associationResolver.resolve(directory: item.directory, projects: store.state.projects, preferredProjectID: workspace.projectID)
                try Task.checkCancellation()
                guard let location = assessment.location, assessment.status == .matched || assessment.status == .unregistered else {
                    throw LaunchError.invalid(assessment.message ?? "The original folder is unavailable. Locate it before continuing.")
                }
                let decision = try await ConversationExecutionCheck.prepare(item, resolver: savedConversationResolver)
                try Task.checkCancellation()
                guard store.state.selectedWorkspaceID == id, let current = store.state.workspaces.first(where: { $0.id == id }),
                      current.conversationID == item.id, current.primaryTerminalID == primary.id,
                      current.primaryTerminal?.binding == nil || current.primaryTerminal?.status == .ended else { return }
                if current.primaryTerminal?.status == .ended { surfaces.release(primary.id) }
                let presentation = store.state.presentation(for: current.threadKey)
                let projectID = presentation.hasProjectOverride ? presentation.projectOverride : assessment.projectID
                store.update { $0.setLocation(location, projectID: projectID, workspaceID: id) }
                // Cancellation remains active until the coordinator commits durable launch intent.
                // The coordinator records an owned receipt even when navigation cancels this task.
                var available = item; available.availability = .local
                await launches.resume(primary.id, conversation: available, prepared: decision.launch)
            } catch is CancellationError { }
            catch { if !Task.isCancelled && continuationTokens[item.id] == token { continuationErrors[item.id] = error.localizedDescription } }
        }
    }
    private func cancelLaunchPreflight() {
        for task in initialLaunchTasks.values { task.cancel() }
        conversationOpenTask?.cancel(); conversationOpenTask = nil
        if let id = preflightConversation {
            continuationTokens[id] = nil; continuingConversations.remove(id); preflightConversation = nil
        }
    }
    private func openHistoryRecord(_ record: ConversationCatalogRecord) {
        var workspaceID: UUID!
        store.update { workspaceID = $0.openCatalogRecord(record) }
        openConversationWorkspace(workspaceID)
    }
    private func sidebarItemIDForFixture(_ id: UUID) -> String {
        if let conversation = store.state.workspaces.first(where: { $0.id == id })?.conversationID {
            return "conversation:" + conversation.provider.rawValue + ":" + conversation.sessionID
        }
        return "workspace:" + id.uuidString
    }
    private func sidebarCellForFixture(_ id: String) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == id { return view }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(conversationSidebar)
    }
    private func checkProjectAssociation(root: URL) async throws {
        _ = try await locations.git.command(root.path, ["init", "-b", "main"]).checked()
        let location = try await locations.git.discover(root)
        var entries: [(workspace: UUID, terminal: UUID, event: AgentEvent)] = []
        for _ in 0..<2 {
            var workspaceID = UUID(), terminalID = UUID()
            store.update {
                let project = $0.registerProject(location)
                workspaceID = $0.newWorkspace(location: location, projectID: project)
                terminalID = $0.primaryTerminalID!
            }
            await launches.launch(terminalID, tool: .shell)
            guard let launch = store.state.tab(terminalID)?.launch else { throw LaunchError.invalid("Association fixture shell failed") }
            let event = AgentEvent(bindingID: launch.operationID, invocationID: UUID(), secret: UUID(), provider: .codex,
                                   kind: .finished, sessionID: UUID().uuidString.lowercased())
            store.update { _ = $0.recordAgentEvent(event) }
            entries.append((workspaceID, terminalID, event))
        }
        let first = entries[0], second = entries[1]
        store.update { $0.selectWorkspace(first.workspace) }
        var shellID = UUID()
        store.update { shellID = $0.newTab(workspaceID: first.workspace)! }
        await launches.launch(shellID, tool: .shell)
        for _ in 0..<200 {
            if surfaces.view(first.terminal) != nil && surfaces.view(shellID) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let primary = surfaces.view(first.terminal), let support = surfaces.view(shellID),
              let primaryBinding = store.state.tab(first.terminal)?.binding,
              let secondBinding = store.state.tab(second.terminal)?.binding else { throw LaunchError.invalid("Association fixture surfaces unavailable") }
        let before = try await launches.runtime.inspect(primaryBinding)
        primary.insertText("SPOOKKY_PRIMARY_ASSOCIATION_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
        support.insertText("SPOOKKY_SUPPORT_ASSOCIATION_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<100 {
            if primary.visibleText().contains("SPOOKKY_PRIMARY_ASSOCIATION_UNSENT") && support.visibleText().contains("SPOOKKY_SUPPORT_ASSOCIATION_UNSENT") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.makeFirstResponder(support)
        var checks: [String: Bool] = [:]
        func record(_ entry: (workspace: UUID, terminal: UUID, event: AgentEvent), status: ProviderProjectAssociation.Status, message: String) {
            store.update { $0.recordProjectAssociation(ProviderProjectAssociation(sessionID: entry.event.sessionID!,
                projectID: "disposable-provider-project", status: status, message: message), workspaceID: entry.workspace,
                primaryTerminalID: entry.terminal, invocationID: entry.event.invocationID, operationID: entry.event.bindingID) }
        }
        record(first, status: .unsupported, message: "Fixture: project association unsupported")
        conversationSidebar.focusItem(sidebarItemIDForFixture(first.workspace))
        window.makeFirstResponder(support)
        let sidebarID = sidebarItemIDForFixture(first.workspace)
        let row = sidebarCellForFixture(sidebarID)
        checks["primary_row_exposes_limitation"] = row?.toolTip?.contains("Fixture: project association unsupported") == true &&
            row?.accessibilityLabel()?.contains("Fixture: project association unsupported") == true
        record(first, status: .associated, message: "Fixture: primary project association verified")
        record(second, status: .associated, message: "Fixture: second project association verified")
        checks["primary_row_refreshes_with_stable_identity"] = sidebarCellForFixture(sidebarID)?.accessibilityIdentifier() == sidebarID &&
            sidebarCellForFixture(sidebarID)?.toolTip?.contains("Fixture: primary project association verified") == true
        checks["support_focus_does_not_change_owner"] = store.state.selectedTab?.id == shellID && window.firstResponder === support &&
            store.state.selected?.primaryTerminalID == first.terminal && store.state.tab(shellID)?.projectAssociation == nil
        checks["association_is_presented_on_conversation_row"] =
            (tabPairs[first.terminal]?.titleButton)?.accessibilityLabel()?.contains("Fixture: primary project association verified") != true
        checks["same_checkout_has_distinct_conversation_entries"] = entries.allSatisfy { entry in
            store.state.workspaces.first { $0.id == entry.workspace }?.primaryTerminalID == entry.terminal
        } && store.state.workspaces.first { $0.id == first.workspace }?.conversationID != store.state.workspaces.first { $0.id == second.workspace }?.conversationID
        checks["project_assignment_preserves_execution_directory"] = primaryBinding.directory == location.path && secondBinding.directory == location.path &&
            store.state.tab(first.terminal)?.launch?.directory == location.path && store.state.tab(second.terminal)?.launch?.directory == location.path
        store.update { $0.hideWorkspace(first.workspace) }
        let selection = store.state.selectedWorkspaceID
        record(first, status: .associated, message: "Fixture: hidden primary association verified")
        checks["hidden_result_retains_closed_view_and_selection"] = store.state.workspaces.first { $0.id == first.workspace }?.viewClosed == true &&
            store.state.selectedWorkspaceID == selection && store.state.workspaces.first { $0.id == first.workspace }?.currentProjectAssociation != nil
        store.update { $0.selectWorkspace(first.workspace) }
        if let renderTask { await renderTask.value }
        let after = try await launches.runtime.inspect(primaryBinding)
        checks["association_preserves_primary_process_and_input"] = before?.processID != nil && before?.processID == after?.processID &&
            surfaces.view(first.terminal)?.visibleText().contains("SPOOKKY_PRIMARY_ASSOCIATION_UNSENT") == true
        checks["association_preserves_support_input"] = surfaces.view(shellID)?.visibleText().contains("SPOOKKY_SUPPORT_ASSOCIATION_UNSENT") == true
        for (theme, size, name) in [(WorkspaceAppearance.dark, NSSize(width: 1120, height: 760), "dark-wide"), (.light, NSSize(width: 650, height: 450), "light-narrow")] {
            store.update { $0.appearance = theme }
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
            if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: root.appendingPathComponent("project-association-" + name + ".png")) }
        }
        try await store.flush()
        checks["metadata_valid"] = (try? store.state.validate()) != nil
        try PrivateFiles.write(checks, to: root.appendingPathComponent("project-association-checks.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Project association fixture failed: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", ")) }
    }

    private func checkConversationIdentity(root: URL) async throws {
        let codexID = ConversationID(provider: .codex, sessionID: "00000000-0000-4000-8000-000000000011")
        let claudeID = ConversationID(provider: .claude, sessionID: "00000000-0000-4000-8000-000000000012")
        try Data("Disposable identity preview.\n".utf8).write(to: root.appendingPathComponent("identity.txt"))
        var workspaceID = UUID()
        store.update { workspaceID = $0.newWorkspace(directory: root.path) }
        let primary = store.state.primaryTerminalID!
        await launches.launch(primary, tool: .shell)
        for _ in 0..<100 {
            if surfaces.view(primary) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let surface = surfaces.view(primary), let binding = store.state.tab(primary)?.binding else {
            throw LaunchError.invalid("Identity fixture terminal did not attach.")
        }
        surface.insertText("IDENTITY_KEEP", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        let process = try await launches.runtime.inspect(binding)?.processID
        // Synthetic metadata on a disposable shell, without provider requests.
        store.update {
            $0.recordAgentEvent(AgentEvent(bindingID: binding.id, invocationID: binding.id, secret: UUID(), provider: .codex,
                                          kind: .attached, sessionID: codexID.sessionID))
            $0.setProviderTitle("Repair session continuity", conversationID: codexID)
        }
        window.makeFirstResponder(surface)
        let responder = window.firstResponder
        let pair = tabPairs[primary], sidebar = conversationSidebar
        let sidebarID = sidebarItemIDForFixture(workspaceID)
        store.update { $0.setProviderTitle("Verify session continuity", conversationID: codexID) }
        var checks: [String: Bool] = [:]
        checks["refresh_preserves_controls_and_focus"] = tabPairs[primary] === pair && conversationSidebar === sidebar && window.firstResponder === responder
        checks["refresh_preserves_sidebar_identity"] = sidebarCellForFixture(sidebarID)?.accessibilityLabel()?.contains("Verify session continuity") == true
        checks["refresh_preserves_surface_and_input"] = surfaces.view(primary) === surface && surface.visibleText().contains("IDENTITY_KEEP")
        checks["primary_tab_title_refreshes"] = (tabPairs[primary]?.titleButton)?.title == "Verify session continuity"
        checks["primary_accessibility_names_provider_and_title"] = (pair?.titleButton)?.accessibilityLabel()?.contains("Verify session continuity · Codex") == true
        checks["codex_vector_asset_available"] = SpookkyStyle.toolImage(.codex)?.isTemplate == true
        checks["claude_vector_asset_available"] = SpookkyStyle.toolImage(.claude)?.isTemplate == true
        var claudeWorkspace = UUID(), shell = UUID()
        store.update {
            claudeWorkspace = $0.ensureConversationWorkspace(claudeID, location: WorkspaceLocation(path: root.path), select: false)
            $0.setProviderTitle("Inspect saved conversations", conversationID: claudeID)
            $0.renameWorkspace(claudeWorkspace, "Claude local alias")
            $0.setProviderTitle("Claude renamed externally", conversationID: claudeID)
            shell = $0.newTab(workspaceID: workspaceID)!
        }
        await launches.launch(shell, tool: .shell)
        if let renderTask { await renderTask.value }
        guard let shellBinding = store.state.tab(shell)?.binding else { throw LaunchError.invalid("Supporting shell did not launch.") }
        let shellProcess = try await launches.runtime.inspect(shellBinding)?.processID
        surfaces.view(shell)?.insertText("SHELL_KEEP", replacementRange: NSRange(location: NSNotFound, length: 0))
        let targets: [(SupportingTarget, String)] = [(.file(path: "identity.txt"), "identity.txt"), (.browser(url: "about:blank"), "Preview"), (.terminal(tabID: shell), "Terminal")]
        for (target, title) in targets {
            store.update { $0.openSupport(target, title: title, workspaceID: workspaceID) }
            if let renderTask { await renderTask.value }
            focusSupportingContent()
            let focus = window.firstResponder, content = workspaceLayout.content.subviews.first
            let primaryControl = tabPairs[primary], sidebarControl = conversationSidebar
            store.update { $0.setProviderTitle("Title changed externally", conversationID: codexID) }
            let kind = SupportingTab(target: target, title: title).contentLabel.lowercased()
            checks["primary_identity_with_" + kind] = store.state.selected?.displayProvider == .codex && store.state.selected?.displayTitle == "Title changed externally" && store.state.primaryTerminalID == primary
            checks["refresh_preserves_" + kind + "_focus"] = window.firstResponder === focus && workspaceLayout.content.subviews.first === content && tabPairs[primary] === primaryControl && conversationSidebar === sidebarControl
        }
        checks["support_count_keeps_single_line_sidebar"] = store.state.selected?.support?.tabs.count == 3 &&
            sidebarCellForFixture(sidebarID)?.subviews.compactMap { $0 as? NSTextField }.count == 1
        checks["browser_host_installed"] = supportingContentHost != nil
        checks["same_checkout_has_distinct_conversation_rows"] = store.state.workspaces.filter { $0.directory == root.path && $0.conversationID != nil }.count == 2
        checks["local_alias_wins"] = store.state.workspaces.first { $0.id == claudeWorkspace }?.displayTitle == "Claude local alias"
        checks["support_types_keep_content_labels"] = store.state.selected?.support?.tabs.map(\.contentLabel) == ["Terminal", "File", "Browser"]
        let records = store.state.workspaces.first { $0.id == workspaceID }!.tabs
        store.update { $0.hideWorkspace(workspaceID); $0.selectWorkspace(workspaceID) }
        if let renderTask { await renderTask.value }
        let afterProcess = try await launches.runtime.inspect(binding)?.processID
        let afterShellProcess = try await launches.runtime.inspect(shellBinding)?.processID
        checks["close_reopen_keeps_processes"] = process != nil && process == afterProcess && shellProcess != nil && shellProcess == afterShellProcess
        checks["close_reopen_keeps_receipts"] = store.state.selected?.tabs == records
        checks["support_selection_keeps_primary_input"] = surfaces.view(primary)?.visibleText().contains("IDENTITY_KEEP") == true
        checks["support_selection_keeps_shell_input"] = surfaces.view(shell)?.visibleText().contains("SHELL_KEEP") == true
        if let button = tabPairs[primary]?.titleButton {
            window.makeFirstResponder(button)
            checks["primary_keyboard_focus"] = window.firstResponder === button
            guard let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124) else {
                throw LaunchError.invalid("Identity fixture keyboard event unavailable.")
            }
            button.keyDown(with: right)
            checks["primary_arrow_navigation"] = window.firstResponder === button
        }
        store.update { $0.openSupport(.file(path: "identity.txt"), title: "identity.txt"); $0.setSupportingLayout(.split, fraction: 0.55) }
        if let renderTask { await renderTask.value }
        await files.settleForFixture()
        checks["file_preview_loaded"] = (files.diagnostics["previewBytes"] ?? 0) > 0
        let firstFile = store.state.selected?.support?.selectedTabID
        try Data("Second file owns this preview.\n".utf8).write(to: root.appendingPathComponent("second.txt"))
        store.update { $0.openSupport(.file(path: "second.txt"), title: "second.txt") }
        if let renderTask { await renderTask.value }
        await files.settleForFixture()
        checks["second_file_tab_loads_its_content"] = files.previewMatchesForFixture(path: "second.txt", text: "Second file owns this preview.")
        if let firstFile { store.update { $0.selectSupport(firstFile) } }
        if let renderTask { await renderTask.value }
        await files.settleForFixture()
        checks["file_tab_switch_restores_its_content"] = files.previewMatchesForFixture(path: "identity.txt", text: "Disposable identity preview.")
        func capture(_ name: String) throws -> Bool {
            window.contentView?.layoutSubtreeIfNeeded(); window.makeFirstResponder(nil)
            guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
            var background = NSColor.clear
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                background = window.backgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
                content.cacheDisplay(in: content.bounds, to: bitmap)
            }
            let captured = NSImage(size: content.bounds.size); captured.addRepresentation(bitmap)
            let composite = NSImage(size: content.bounds.size, flipped: false) { bounds in
                background.setFill(); bounds.fill(); captured.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1); return true
            }
            guard let tiff = composite.tiffRepresentation, let image = NSBitmapImageRep(data: tiff),
                  let data = image.representation(using: .png, properties: [:]) else { return false }
            try data.write(to: root.appendingPathComponent(name + ".png")); return true
        }
        store.update { $0.selectSupport(shell); $0.setSupportingLayout(.split, fraction: 0.55) }
        if let renderTask { await renderTask.value }
        window.contentView?.layoutSubtreeIfNeeded()
        let retainedPrimary = surfaces.view(primary), retainedShell = surfaces.view(shell)
        let supportHeaderFrame = workspaceLayout.headerView.convert(workspaceLayout.headerView.bounds, to: window.contentView)
        let primaryHeaderFrame = tabScroll.convert(tabScroll.bounds, to: window.contentView)
        let supportingFrame = workspaceLayout.panel.convert(workspaceLayout.panel.bounds, to: window.contentView)
        checks["split_tab_groups_share_one_header_row"] = abs(primaryHeaderFrame.minY - supportHeaderFrame.minY) < 1 && abs(primaryHeaderFrame.height - supportHeaderFrame.height) < 1
        checks["right_header_tracks_content_divider"] = abs(supportHeaderFrame.minX - supportingFrame.minX) < 1
        checks["support_content_has_no_stacked_tab_header"] = workspaceLayout.content.frame == workspaceLayout.panel.bounds
        checks["running_primary_has_no_duplicate_header"] = retainedPrimary?.frame.height == body.bounds.height
        checks["split_tab_screenshot"] = try capture("identity-tabs-split")
        let splitPrimarySize = body.bounds.size
        store.update { $0.setSupportingLayout(.fullWidth) }
        if let renderTask { await renderTask.value }
        checks["full_support_uses_entire_content_area"] = body.isHidden && workspaceLayout.panel.frame.width == workspaceLayout.bounds.width
        checks["hidden_primary_retains_terminal_geometry"] = body.bounds.size == splitPrimarySize
        let fullSupportingSize = workspaceLayout.panel.bounds.size
        if let mainTab = tabPairs[primary]?.titleButton { mainTab.performClick(nil) }
        if let renderTask { await renderTask.value }
        window.contentView?.layoutSubtreeIfNeeded()
        checks["main_tab_selects_full_primary_without_collapsing_tabs"] = store.state.selected?.support?.layout == .fullWidth && store.state.selected?.support?.resolvedFullWidthSelection == .primary && !body.isHidden && workspaceLayout.panel.isHidden && !workspaceLayout.headerView.isHidden
        checks["full_primary_preserves_right_selection"] = store.state.selected?.support?.selectedTabID == shell
        checks["hidden_support_retains_terminal_geometry"] = workspaceLayout.panel.bounds.size == fullSupportingSize
        checks["full_headers_join_on_same_row"] = tabScroll.isHidden && workspaceLayout.joinsPrimary &&
            workspaceLayout.tabItems.first === tabPairs[primary] && workspaceLayout.tabItems.count == (store.state.selected?.support?.tabs.count ?? 0) + 1
        checks["full_primary_is_fully_visible"] = workspaceLayout.selectedTabFullyVisible
        checks["full_primary_tab_screenshot"] = try capture("identity-tabs-full-primary")
        if let browser = store.state.selected?.support?.tabs.first(where: { if case .browser = $0.target { return true }; return false }) {
            store.update { $0.selectSupport(browser.id) }
            if let renderTask { await renderTask.value }
            checks["full_browser_retains_both_terminal_surfaces"] = surfaces.view(primary) === retainedPrimary && surfaces.view(shell) === retainedShell
            checks["full_browser_tab_screenshot"] = try capture("identity-tabs-full-browser")
        }
        store.update { $0.setSupportingLayout(.split) }
        if let renderTask { await renderTask.value }
        checks["return_to_split_restores_saved_fraction"] = store.state.selected?.support?.fraction == 0.55 && !body.isHidden && !workspaceLayout.panel.isHidden
        store.update { $0.selectSupport(shell) }
        if let renderTask { await renderTask.value }
        for _ in 0..<100 {
            if surfaces.view(primary)?.visibleText().contains("IDENTITY_KEEP") == true && surfaces.view(shell)?.visibleText().contains("SHELL_KEEP") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["layout_switches_preserve_terminal_surfaces"] = surfaces.view(primary) === retainedPrimary && surfaces.view(shell) === retainedShell
        checks["layout_switches_preserve_primary_input"] = surfaces.view(primary)?.visibleText().contains("IDENTITY_KEEP") == true
        checks["layout_switches_preserve_supporting_input"] = surfaces.view(shell)?.visibleText().contains("SHELL_KEEP") == true
        let layoutPrimaryProcess = try await launches.runtime.inspect(binding)?.processID
        let layoutShellProcess = try await launches.runtime.inspect(shellBinding)?.processID
        checks["layout_switches_preserve_process_ids"] = layoutPrimaryProcess == process && layoutShellProcess == shellProcess
        var overflowBrowser = UUID()
        store.update { overflowBrowser = $0.openSupport(.browser(url: "about:blank"), title: "Overflow focus fixture")! }
        if let renderTask { await renderTask.value }
        window.makeFirstResponder(surfaces.view(primary))
        let overflow = tabOverflowMenu(store.state.selected!)
        guard let item = overflow.items.first(where: { $0.representedObject as? UUID == overflowBrowser }), let action = item.action else {
            throw LaunchError.invalid("Overflow browser action is unavailable.")
        }
        _ = NSApp.sendAction(action, to: item.target, from: item)
        if let renderTask { await renderTask.value }
        checks["overflow_selection_focuses_supporting_content"] = workspaceLayout.hasFocus && store.state.selected?.support?.selectedTabID == overflowBrowser
        closeSelectedTab()
        if let renderTask { await renderTask.value }
        checks["overflow_cmd_w_closes_browser_not_workspace"] = store.state.selectedWorkspaceID == workspaceID && store.state.selected?.viewClosed != true && store.state.selected?.support?.tabs.contains(where: { $0.id == overflowBrowser }) == false
        checks["overflow_close_preserves_primary_input"] = surfaces.view(primary)?.visibleText().contains("IDENTITY_KEEP") == true
        let auxiliary = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        auxiliary.isReleasedWhenClosed = false
        auxiliary.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<50 { if NSApp.keyWindow === auxiliary { break }; try await Task.sleep(for: .milliseconds(20)) }
        checks["auxiliary_window_receives_key_focus"] = NSApp.keyWindow === auxiliary
        closeSelectedTab()
        checks["close_auxiliary_window_preserves_conversation"] = !auxiliary.isVisible && store.state.selectedWorkspaceID == workspaceID && store.state.selected?.viewClosed != true
        window.makeKeyAndOrderFront(nil)
        if let firstFile { store.update { $0.selectSupport(firstFile) } }
        if let renderTask { await renderTask.value }
        await files.settleForFixture()
        var screenshots = 0
        for theme in [WorkspaceAppearance.dark, .light] {
            for width in [1120, 680] {
                store.update { $0.appearance = theme }
                window.setContentSize(NSSize(width: width, height: width == 1120 ? 760 : 480))
                if try capture("identity-revised-" + theme.rawValue + "-" + String(width)) { screenshots += 1 }
                checks["primary_header_\(theme.rawValue)_\(width)"] = tabPairs.count == 1 && tabPairs[primary]?.frame.height == SpookkyStyle.headerHeight
                checks["selected_support_tab_visible_\(theme.rawValue)_\(width)"] = workspaceLayout.selectedTabCanFit
                    ? workspaceLayout.selectedTabFullyVisible : workspaceLayout.selectedTabVisibleWidth > 0
                checks["bounded_tab_widths_\(theme.rawValue)_\(width)"] = workspaceLayout.tabItems.allSatisfy {
                    (SpookkyStyle.points(48)...WorkspaceTabView.maximumWidth).contains($0.bounds.width)
                }
            }
        }
        checks["desktop_narrow_both_themes"] = screenshots == 4
        store.update {
            $0.recordAgentEvent(AgentEvent(bindingID: binding.id, invocationID: binding.id, secret: UUID(), provider: .codex,
                                          kind: .needsInput, sessionID: codexID.sessionID))
            $0.sidebarCollapsed = true
        }
        window.contentView?.layoutSubtreeIfNeeded()
        conversationSidebar.focusItem(sidebarID)
        let railCell = sidebarCellForFixture(sidebarID)
        let railImages = railCell?.subviews.compactMap { $0 as? NSImageView } ?? []
        checks["hidden_sidebar_has_no_duplicate_provider_rail"] = railCell == nil && conversationSidebar.itemCount == 0
        checks["hidden_sidebar_preserves_thread_provider_and_activity"] = store.state.selected?.displayProvider == .codex && store.state.selected?.activityState != nil
        for theme in [WorkspaceAppearance.dark, .light] {
            store.update { $0.appearance = theme }
            checks["rail_snapshot_" + theme.rawValue] = try capture("identity-revised-rail-" + theme.rawValue)
        }
        store.update { $0.sidebarCollapsed = false; $0.openSupport(.file(path: "identity.txt"), title: "identity.txt") }
        if let renderTask { await renderTask.value }
        focusSupportingContent()
        let oldSupport = store.state.selected?.support
        let nextID = ConversationID(provider: .codex, sessionID: "00000000-0000-4000-8000-000000000013")
        store.update {
            $0.recordAgentEvent(AgentEvent(bindingID: binding.id, invocationID: binding.id, secret: UUID(), provider: .codex,
                                          kind: .attached, sessionID: nextID.sessionID))
        }
        if let renderTask { await renderTask.value }
        checks["native_session_switch_preserves_old_row_and_support"] = store.state.workspace(for: codexID)?.id == workspaceID && store.state.workspace(for: codexID)?.support == oldSupport
        checks["background_session_switch_preserves_selection"] = store.state.selectedWorkspaceID == workspaceID
        checks["session_switch_moves_binding_once"] = store.state.workspace(for: nextID)?.primaryTerminalID == primary && store.state.workspaces.flatMap(\.tabs).filter { $0.binding?.id == binding.id }.count == 1
        if let next = store.state.workspace(for: nextID) { selectWorkspace(next.id) }
        if let renderTask { await renderTask.value }
        checks["session_switch_retains_live_process"] = try await launches.runtime.inspect(binding)?.processID == process
        checks["session_switch_retains_terminal_input"] = surfaces.view(primary)?.visibleText().contains("IDENTITY_KEEP") == true
        checks["session_switch_new_support_is_independent"] = store.state.selected?.support?.tabs.isEmpty == true
        let returningWorkspace = store.state.selectedWorkspaceID
        var draftWorkspace = UUID()
        store.update {
            draftWorkspace = $0.showLanding(homeDirectory: root.path)
            $0.editDraft($0.primaryTerminalID!, tool: .codex, prompt: "Retain this starting instruction")
        }
        let draftTerminal = store.state.primaryTerminalID!
        if let renderTask { await renderTask.value }
        guard let composer = composers[draftTerminal] else { throw LaunchError.invalid("Startup composer did not render.") }
        for (theme, width, height) in [(WorkspaceAppearance.dark, 1120, 760), (.light, 680, 480)] {
            store.update { $0.appearance = theme }
            window.setContentSize(NSSize(width: width, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
            let editor = composer.convert(composer.prompt.bounds, from: composer.prompt)
            checks["startup_composer_bottom_\(width)"] = editor.midY < composer.bounds.midY && editor.minX >= 24 && editor.maxX <= composer.bounds.width - 24
            checks["startup_screenshot_\(width)"] = try capture("identity-startup-" + theme.rawValue + "-" + String(width))
        }
        checks["startup_keeps_initial_draft"] = composer.prompt.string == "Retain this starting instruction"
        launch(draftTerminal)
        let cancelledLaunch = initialLaunchTasks[draftTerminal]
        if let returningWorkspace { selectWorkspace(returningWorkspace) } else { newWorkspace() }
        await cancelledLaunch?.value
        checks["leaving_new_prompt_cancels_unstarted_agent"] = store.state.tab(draftTerminal)?.binding == nil &&
            store.state.tab(draftTerminal)?.launch == nil && store.state.tab(draftTerminal)?.draft.prompt == "Retain this starting instruction"
        selectWorkspace(draftWorkspace)
        if let renderTask { await renderTask.value }
        func terminalAction(_ view: NSView) -> ActionButton? {
            if let button = view as? ActionButton, button.accessibilityLabel() == "Open Terminal and keep this session draft" { return button }
            return view.subviews.lazy.compactMap { terminalAction($0) }.first
        }
        guard let openTerminal = terminalAction(composer) else { throw LaunchError.invalid("Open Terminal control is unavailable.") }
        openTerminal.performClick(nil)
        for _ in 0..<150 {
            if store.state.selected?.tabs.contains(where: { $0.id != draftTerminal && $0.binding?.tool == .shell }) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let renderTask { await renderTask.value }
        guard let temporaryShell = store.state.selected?.primaryTerminal, temporaryShell.id != draftTerminal,
              temporaryShell.binding?.tool == .shell, let shellWorkspace = store.state.selectedWorkspaceID else {
            throw LaunchError.invalid("Open Terminal did not start an independent shell workspace.")
        }
        checks["startup_open_terminal_preserves_agent_draft"] = store.state.tab(draftTerminal)?.draft.tool == .codex && store.state.tab(draftTerminal)?.draft.prompt == "Retain this starting instruction" && store.state.tab(draftTerminal)?.binding == nil
        checks["startup_open_terminal_has_no_agent_prompt"] = temporaryShell.launch?.tool == .shell && temporaryShell.launch?.arguments.contains("Retain this starting instruction") == false && temporaryShell.promptDelivery == .none
        checks["startup_shell_does_not_erase_provider_preference"] = store.state.lastAgentTool == .codex
        newWorkspace()
        if let renderTask { await renderTask.value }
        checks["cmd_n_restores_existing_landing_draft"] = store.state.selectedWorkspaceID == draftWorkspace &&
            composers[draftTerminal]?.prompt.string == "Retain this starting instruction" && store.state.selected?.isLanding == true
        try await launches.terminate(temporaryShell.id); surfaces.release(temporaryShell.id)
        store.update {
            $0.closeWorkspace(shellWorkspace)
            if let returningWorkspace { $0.selectWorkspace(returningWorkspace) }
        }
        if let renderTask { await renderTask.value }
        render(); window.contentView?.layoutSubtreeIfNeeded()
        checks["history_errors_do_not_use_global_footer"] = warning.isHidden
        try PrivateFiles.write(checks, to: root.appendingPathComponent("identity-checks.json"))
    }
    private func checkSidebar(root: URL) async throws {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<250 {
            if NSApp.isActive && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard NSApp.isActive && window.isKeyWindow else { throw LaunchError.invalid("Sidebar fixture did not activate.") }
        let location = WorkspaceLocation(path: root.path)
        var projectID = UUID(), workspaceID = UUID()
        let name = "Investigate workspace navigation and preserve terminal drafts"
        store.update {
            projectID = $0.registerProject(location)
            workspaceID = $0.newWorkspace(location: location, projectID: projectID)
            $0.renameWorkspace(workspaceID, name)
            $0.editDraft($0.selectedTab!.id, tool: .codex, prompt: "Keep this unsent draft")
        }
        if let renderTask { await renderTask.value }
        let original = store.state.selected!
        let projectKey = "project:" + projectID.uuidString, workspaceKey = sidebarItemIDForFixture(workspaceID)
        var checks: [String: Bool] = [:]
        var interactionDetails = ["fixture_window_key": String(window.isKeyWindow), "fixture_app_active": String(NSApp.isActive)]
        try await Task.sleep(for: .milliseconds(50)); window.contentView?.layoutSubtreeIfNeeded()
        conversationSidebar.focusItem(workspaceKey)
        guard let pair = tabPairs[original.selectedTabID], let cell = sidebarCellForFixture(workspaceKey) else {
            throw LaunchError.invalid("Virtualized sidebar fixture controls are unavailable.")
        }
        if let frame = window.contentView?.superview {
            var hits: [String: String] = [:]
            for y in [2.0, 10.0, 20.0, 30.0, 38.0] {
                let point = pair.convert(NSPoint(x: pair.bounds.midX, y: y), to: frame)
                let hit = frame.hitTest(point)
                hits[String(y)] = hit.map { String(describing: type(of: $0)) } ?? "nil"
            }
            try PrivateFiles.write(hits, to: root.appendingPathComponent("header-hit-grid.json"))
        }
        let tabClose = pair.closeButton
        checks["single_line_conversation_row"] = cell.subviews.compactMap { $0 as? NSTextField }.count == 1 && abs(cell.bounds.height - 31) < 0.5
        let projectIcon = sidebarCellForFixture(projectKey)?.subviews.compactMap { $0 as? NSImageView }.first
        let conversationIcon = cell.subviews.compactMap { $0 as? NSImageView }.first
        let conversationTitle = cell.subviews.compactMap { $0 as? NSTextField }.first
        let projectTitle = sidebarCellForFixture(projectKey)?.subviews.compactMap { $0 as? NSTextField }.first
        checks["project_content_has_internal_padding"] = projectIcon.map { abs($0.convert($0.bounds, to: conversationSidebar).minX - 12) < 0.5 } == true
        checks["conversation_and_project_titles_align_without_provider_icon"] = conversationIcon?.isHidden == true &&
            conversationTitle.map { abs($0.frame.minX - 35) < 0.5 } == true && projectTitle.map { abs($0.frame.minX - 35) < 0.5 } == true
        railScroll.contentView.scroll(to: NSPoint(x: 120, y: 0)); railScroll.reflectScrolledClipView(railScroll.contentView)
        checks["fixed_sidebar_controls_cannot_scroll_sideways"] = railScroll.contentView.bounds.minX == 0 && railScroll.horizontalScrollElasticity == .none
        checks["full_title_in_accessibility_without_native_tooltip"] = cell.toolTip == nil && cell.accessibilityLabel()?.contains(name) == true
        checks["thread_menu_has_archive_without_close"] = conversationSidebar.onContextMenu?(workspaceKey)?.items.contains { $0.title == "Archive" } == true && conversationSidebar.onContextMenu?(workspaceKey)?.items.contains { $0.title == "Close conversation view" } == false
        checks["compact_tab_close_target"] = abs(tabClose.frame.width - 24) < 0.5 && abs(tabClose.frame.height - 24) < 0.5
        window.makeFirstResponder(pair.titleButton); await Task.yield()
        interactionDetails["tab_close_hidden"] = String(tabClose.isHidden)
        interactionDetails["tab_close_revealed"] = String(tabClose.isRevealed)
        interactionDetails["tab_title_focused"] = String(window.firstResponder === pair.titleButton)
        checks["primary_has_no_keyboard_close_target"] = tabClose.isHidden && !pair.closable
        func key(_ code: UInt16, _ text: String = "") throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { throw LaunchError.invalid("Sidebar keyboard event unavailable.") }
            return event
        }
        conversationSidebar.focusItem(projectKey)
        (window.firstResponder as? NSView)?.keyDown(with: try key(36, "\r"))
        checks["project_keyboard_collapses_rows"] = sidebarCellForFixture(workspaceKey) == nil && store.state.projects.first { $0.id == projectID }?.isCollapsed == true
        checks["collapse_preserves_workspace_and_draft"] = store.state.workspaces.first { $0.id == workspaceID } == original
        interactionDetails["original_workspace"] = String(data: try JSONEncoder().encode(original), encoding: .utf8)
        interactionDetails["collapsed_workspace"] = String(data: try JSONEncoder().encode(store.state.workspaces.first { $0.id == workspaceID }), encoding: .utf8)
        checks["collapse_preserves_project_keyboard_focus"] = conversationSidebar.focusedItemID == projectKey && (window.firstResponder as? NSView)?.isDescendant(of: conversationSidebar) == true
        (window.firstResponder as? NSView)?.keyDown(with: try key(36, "\r"))
        checks["expand_restores_rows"] = sidebarCellForFixture(workspaceKey) != nil
        if let scroller = conversationSidebar.subviews.first as? NSScrollView, let table = scroller.documentView as? NSTableView,
           let projectCell = sidebarCellForFixture(projectKey) {
            let point = projectCell.convert(NSPoint(x: 60, y: projectCell.bounds.midY), to: nil)
            let time = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.01,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { throw LaunchError.invalid("Project click fixture unavailable.") }
            NSApp.postEvent(up, atStart: true)
            table.mouseDown(with: down)
            await Task.yield()
            checks["project_mouse_click_toggles_without_selection_or_keyboard_fill"] = store.state.projects.first { $0.id == projectID }?.isCollapsed == true &&
                table.selectedRow == -1 && conversationSidebar.keyboardFocusItemID == nil && store.state.selectedWorkspaceID == workspaceID
            interactionDetails["project_click_state"] = "collapsed=\(store.state.projects.first { $0.id == projectID }?.isCollapsed == true) selectedRow=\(table.selectedRow) keyboard=\(conversationSidebar.keyboardFocusItemID ?? "none") workspace=\(store.state.selectedWorkspaceID == workspaceID)"
            conversationSidebar.focusItem(projectKey)
            (window.firstResponder as? NSView)?.keyDown(with: try key(36, "\r"))
            checks["keyboard_navigation_restores_neutral_focus_after_mouse_click"] = conversationSidebar.keyboardFocusItemID == projectKey && sidebarCellForFixture(workspaceKey) != nil
        }
        let bindings = store.state.workspaces.flatMap(\.tabs).compactMap(\.binding)
        conversationSidebar.onAddProjectSession?(projectKey)
        if let renderTask { await renderTask.value }
        checks["project_plus_opens_landing_without_agent"] = store.state.selected?.isLanding == true && store.state.selected?.projectID == projectID && store.state.workspaces.flatMap(\.tabs).compactMap(\.binding) == bindings
        store.update { $0.setProjectCollapsed(projectID, true); $0.selectWorkspace(workspaceID) }
        checks["selection_reveals_project"] = sidebarCellForFixture(workspaceKey) != nil

        if let refresh = historyRefreshTask { refresh.cancel(); await refresh.value }
        let originalActivate = conversationSidebar.onActivate
        var activations = 0
        conversationSidebar.onActivate = { _ in activations += 1 }
        let virtual = (0..<5_000).map { WorkspaceSidebarItem(id: "fixture:" + String($0), kind: .conversation, title: name + " " + String($0), image: SpookkyStyle.toolImage(.codex)) }
        conversationSidebar.update(items: [virtual[0], virtual[0]], collapsed: false)
        checks["duplicate_history_ids_do_not_duplicate_rows"] = conversationSidebar.itemCount == 1
        conversationSidebar.update(items: virtual, collapsed: false)
        window.contentView?.layoutSubtreeIfNeeded(); conversationSidebar.focusItem("fixture:2500")
        checks["virtualized_views_are_bounded"] = conversationSidebar.itemCount == 5_000 && conversationSidebar.visibleCellCount > 0 && conversationSidebar.visibleCellCount < 100
        (window.firstResponder as? NSView)?.keyDown(with: try key(125))
        checks["arrow_navigation_does_not_activate"] = conversationSidebar.focusedItemID == "fixture:2501" && activations == 0
        (window.firstResponder as? NSView)?.keyDown(with: try key(36, "\r"))
        checks["return_activates_only_focused_row"] = activations == 1
        let focusedID = conversationSidebar.focusedItemID!
        let beforeY = sidebarCellForFixture(focusedID).map { $0.convert($0.bounds, to: window.contentView).minY }
        let updated = [WorkspaceSidebarItem(id: "fixture:inserted", kind: .conversation, title: "New recent conversation")] + virtual
        conversationSidebar.update(items: updated, collapsed: false); window.contentView?.layoutSubtreeIfNeeded()
        let afterY = sidebarCellForFixture(focusedID).map { $0.convert($0.bounds, to: window.contentView).minY }
        checks["refresh_preserves_scroll_anchor_and_focus"] = conversationSidebar.focusedItemID == focusedID && beforeY != nil && afterY != nil && abs(beforeY! - afterY!) < 1
        if let scroller = conversationSidebar.subviews.first as? NSScrollView, let table = scroller.documentView as? NSTableView {
            let origin = scroller.contentView.bounds.origin
            for x in [CGFloat(120), -120] {
                scroller.contentView.scroll(to: NSPoint(x: x, y: origin.y))
                scroller.reflectScrolledClipView(scroller.contentView)
            }
            checks["sidebar_rejects_horizontal_scroll_and_bounce"] = scroller.contentView.bounds.minX == 0 &&
                !scroller.hasHorizontalScroller && scroller.horizontalScrollElasticity == .none
            checks["sidebar_column_matches_viewport_width"] = table.style == .plain &&
                abs(table.frame.width - scroller.contentSize.width) < 0.5 && abs(table.tableColumns[0].width - scroller.contentSize.width) < 0.5
            window.makeFirstResponder(nil)
            let local = conversationSidebar.convert(NSPoint(x: 28, y: conversationSidebar.bounds.midY), to: nil)
            let previousPointer = conversationSidebar.pointerLocation
            conversationSidebar.pointerLocation = { _ in local }
            defer { conversationSidebar.pointerLocation = previousPointer }
            await Task.yield()
            let oldHover = conversationSidebar.hoveredItemID
            scroller.contentView.scroll(to: NSPoint(x: 0, y: scroller.contentView.bounds.minY + 96))
            scroller.reflectScrolledClipView(scroller.contentView)
            try await Task.sleep(for: .milliseconds(40))
            let row = table.row(at: table.convert(local, from: nil))
            let expected = updated.indices.contains(row) ? updated[row].id : nil
            interactionDetails["hover_before_scroll"] = oldHover ?? "none"
            interactionDetails["hover_after_scroll"] = conversationSidebar.hoveredItemID ?? "none"
            interactionDetails["expected_hover_after_scroll"] = expected ?? "none"
            checks["scroll_reconciles_stationary_pointer"] = oldHover != nil && expected != nil && oldHover != expected && conversationSidebar.hoveredItemID == expected
            func actions(_ view: NSView) -> [ActionButton] { (view as? ActionButton).map { [$0] } ?? view.subviews.flatMap { actions($0) } }
            checks["two_direct_hover_actions_visible"] = actions(conversationSidebar).filter { !$0.isHidden }.count == 2
            interactionDetails["visible_hover_accessories"] = String(actions(conversationSidebar).filter { !$0.isHidden }.count)
            let title = expected.flatMap { sidebarCellForFixture($0) }?.subviews.compactMap { $0 as? NSTextField }.first
            checks["hover_title_stays_single_line_and_clipped"] = title?.maximumNumberOfLines == 1 && title?.layer?.animationKeys()?.isEmpty != false
            window.orderOut(nil); await Task.yield()
            checks["inactive_window_hides_all_row_accessories"] = actions(conversationSidebar).allSatisfy(\.isHidden)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            for _ in 0..<250 {
                if NSApp.isActive && window.isKeyWindow { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            checks["reactivation_reveals_only_hovered_row_accessory"] = window.isKeyWindow && actions(conversationSidebar).filter { !$0.isHidden }.count == 2
            scroller.contentView.scroll(to: NSPoint(x: 0, y: scroller.contentView.bounds.minY + 96))
            scroller.reflectScrolledClipView(scroller.contentView); await Task.yield()
            let reactivatedRow = table.row(at: table.convert(local, from: nil))
            checks["reactivated_scroll_hides_other_row_accessories"] = updated.indices.contains(reactivatedRow) &&
                conversationSidebar.hoveredItemID == updated[reactivatedRow].id && actions(conversationSidebar).filter { !$0.isHidden }.count == 2
            conversationSidebar.pointerLocation = { _ in nil }
            conversationSidebar.focusItem(focusedID); await Task.yield()
            let accessory = sidebarCellForFixture(focusedID)?.subviews.compactMap { $0 as? ActionButton }.first
            checks["keyboard_focus_reveals_only_its_row_accessory"] = accessory?.isHidden == false && actions(conversationSidebar).filter { !$0.isHidden }.count == 2
            if let accessory { window.makeFirstResponder(accessory) }
            await Task.yield()
            checks["revealed_row_accessory_accepts_keyboard_focus"] = accessory != nil && window.firstResponder === accessory && accessory?.isHidden == false
        }
        checks["history_navigation_starts_no_agents"] = store.state.workspaces.flatMap(\.tabs).compactMap(\.binding) == bindings
        conversationSidebar.onActivate = originalActivate
        renderChrome(); conversationSidebar.focusItem(workspaceKey)
        var screenshots = 0
        for (theme, size) in [(WorkspaceAppearance.dark, NSSize(width: 1120, height: 760)), (.light, NSSize(width: 650, height: 450))] {
            store.update { $0.appearance = theme }; window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded(); window.makeFirstResponder(nil)
            guard let content = window.contentView, let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            window.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: image) }
            if let png = image.representation(using: .png, properties: [:]) { try png.write(to: root.appendingPathComponent("sidebar-" + theme.rawValue + ".png")); screenshots += 1 }
        }
        checks["wide_and_narrow_native_snapshots"] = screenshots == 2
        store.update { $0.appearance = .dark }; window.setContentSize(NSSize(width: 1120, height: 760))
        var shellID: UUID?
        store.update { shellID = $0.newTab() }
        guard let shellID else { throw LaunchError.invalid("Sidebar shell fixture is unavailable.") }
        await launches.launch(shellID, tool: .shell)
        for _ in 0..<100 { if surfaces.view(shellID) != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        guard let surface = surfaces.view(shellID), let binding = store.state.tab(shellID)?.binding else { throw LaunchError.invalid("Sidebar shell fixture did not attach.") }
        for green in [false, true] {
            let rgb = green ? "0;255;0" : "255;0;0"
            let command = "if [[ -z ${NO_COLOR-} && $COLORTERM == truecolor ]]; then printf '\\033[2J\\033[H\\033[48;2;" + rgb + "m                \\033[0m\\nSPOOKKY_NATIVE_COLOR_ENV_OK\\n'; fi"
            surface.insertText(command, replacementRange: NSRange(location: NSNotFound, length: 0))
            surface.keyDown(with: try key(36, "\r"))
            for _ in 0..<150 {
                if RenderedFixtureProbe.matches(surface, green: green) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            checks[green ? "native_truecolor_green_survives_tmux" : "native_truecolor_red_survives_tmux"] =
                surface.visibleText().contains("SPOOKKY_NATIVE_COLOR_ENV_OK") && RenderedFixtureProbe.matches(surface, green: green)
        }
        surface.insertText("for i in {1..120}; do printf 'READ_CHECK_%s\\n' \"$i\"; done", replacementRange: NSRange(location: NSNotFound, length: 0))
        surface.keyDown(with: try key(36, "\r"))
        try await Task.sleep(for: .milliseconds(250))
        try await surfaces.scrollFixtureHistory(shellID, offset: 25)
        let invocation = UUID(), secret = UUID()
        func activityEvent(_ kind: AgentEventKind) -> AgentEvent {
            AgentEvent(bindingID: binding.id, invocationID: invocation, secret: secret, provider: .codex, kind: kind)
        }
        store.update { $0.recordAgentEvent(activityEvent(.working)); $0.recordAgentEvent(activityEvent(.finished)) }
        try await Task.sleep(for: .milliseconds(250))
        let scrolledBottom = try await surfaces.viewportAtBottom(shellID)
        checks["completion_stays_unread_in_real_scrollback"] = store.state.tab(shellID)?.activity?.unread == true && scrolledBottom == false
        interactionDetails["observed_scrolled_bottom"] = String(describing: scrolledBottom)
        try await surfaces.scrollFixtureHistory(shellID, offset: 0)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(surface); NSApp.activate(ignoringOtherApps: true)
        refreshAgentAttention()
        for _ in 0..<100 {
            if store.state.tab(shellID)?.activity?.unread == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["completion_acknowledged_at_real_terminal_bottom"] = store.state.tab(shellID)?.activity?.unread == false
        interactionDetails["observed_live_bottom"] = String(describing: try await surfaces.viewportAtBottom(shellID))
        if let ownerID = store.state.workspace(containing: shellID)?.id {
            store.update { _ = $0.showLanding(homeDirectory: root.path) }
            if let renderTask { await renderTask.value }
            store.update { $0.recordAgentEvent(activityEvent(.working)); $0.recordAgentEvent(activityEvent(.finished)) }
            try await Task.sleep(for: .milliseconds(200))
            checks["background_completion_remains_unread"] = store.state.tab(shellID)?.activity?.unread == true
            store.update { $0.selectWorkspace(ownerID); $0.selectTab(shellID); $0.setSupportingLayout(.split) }
            if let renderTask { await renderTask.value }
            refreshAgentAttention()
            for _ in 0..<100 {
                if store.state.tab(shellID)?.activity?.unread == false { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            checks["visible_split_terminal_acknowledges_completion"] = store.state.tab(shellID)?.activity?.unread == false
        }
        guard let cancelCopyMode = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{3}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) else { throw LaunchError.invalid("Copy-mode cancellation event unavailable.") }
        surface.keyDown(with: cancelCopyMode)
        for _ in 0..<100 {
            if try await surfaces.observedViewport(shellID) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["return_to_bottom_keeps_live_terminal_input"] = try await surfaces.observedViewport(shellID) == nil
        store.update { $0.recordAgentEvent(activityEvent(.needsInput)) }
        refreshAgentAttention(); try await Task.sleep(for: .milliseconds(100))
        checks["viewing_real_terminal_keeps_input_request"] = store.state.tab(shellID)?.activity?.displayState == .needsInput
        store.update { $0.recordAgentEvent(activityEvent(.failed)) }
        refreshAgentAttention(); try await Task.sleep(for: .milliseconds(100))
        checks["viewing_real_terminal_keeps_failure"] = store.state.tab(shellID)?.activity?.displayState == .failed
        guard let viewportOwner = launches.runtime as? WorkspaceViewportFixtureRuntime else {
            throw LaunchError.invalid("Sidebar viewport race fixture is unavailable.")
        }
        store.update { $0.resetAgent(shellID) }
        for task in Array(acknowledgmentTasks.values) { await task.value }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(surface); NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<100 {
            if agentTargetVisible(shellID), try await surfaces.viewportAtBottom(shellID) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        interactionDetails["acknowledgment_race_setup"] = "visible=\(agentTargetVisible(shellID)) revision=\(surface.viewportRevision) bottom=\(String(describing: try await surfaces.viewportAtBottom(shellID))) pending=\(acknowledgmentTasks[shellID] != nil)"
        try PrivateFiles.write(interactionDetails, to: root.appendingPathComponent("sidebar-interaction-diagnostics.json"))
        await viewportOwner.holdViewport(after: 1)
        store.update { $0.recordAgentEvent(activityEvent(.working)); $0.recordAgentEvent(activityEvent(.finished)) }
        refreshAgentAttention()
        for _ in 0..<100 {
            if await viewportOwner.isHeld { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await viewportOwner.isHeld else { throw LaunchError.invalid("Sidebar acknowledgment did not reach its delayed bottom query.") }
        let bottomAcknowledgment = acknowledgmentTasks[shellID]
        surface.onViewportInteraction?()
        checks["pending_scroll_keeps_viewport_unknown"] = try await surfaces.viewportAtBottom(shellID) == nil
        try await surfaces.scrollFixtureHistory(shellID, offset: 25)
        try await Task.sleep(for: .milliseconds(150))
        await viewportOwner.resume()
        await bottomAcknowledgment?.value
        for task in Array(acknowledgmentTasks.values) { await task.value }
        checks["scroll_during_bottom_query_retains_unread"] = store.state.tab(shellID)?.activity?.unread == true
        await viewportOwner.holdViewport(after: 1)
        refreshAgentAttention()
        for _ in 0..<100 {
            if await viewportOwner.isHeld { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await viewportOwner.isHeld else { throw LaunchError.invalid("Sidebar acknowledgment did not reach its delayed scrollback query.") }
        let scrollbackAcknowledgment = acknowledgmentTasks[shellID]
        surface.onViewportInteraction?()
        try await surfaces.scrollFixtureHistory(shellID, offset: 0)
        try await Task.sleep(for: .milliseconds(150))
        await viewportOwner.resume()
        await scrollbackAcknowledgment?.value
        for _ in 0..<100 {
            if store.state.tab(shellID)?.activity?.unread == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["return_to_bottom_during_query_retries_acknowledgment"] = store.state.tab(shellID)?.activity?.unread == false
        interactionDetails["acknowledgment_race_result"] = "visible=\(agentTargetVisible(shellID)) revision=\(surface.viewportRevision) bottom=\(String(describing: try await surfaces.viewportAtBottom(shellID))) pending=\(acknowledgmentTasks[shellID] != nil)"
        try PrivateFiles.write(interactionDetails, to: root.appendingPathComponent("sidebar-interaction-diagnostics.json"))
        surface.keyDown(with: cancelCopyMode)
        for _ in 0..<100 {
            if try await surfaces.observedViewport(shellID) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        store.update { $0.resetAgent(shellID) }
        surface.insertText("SPOOKKY_SIDEBAR_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
        func unsentInputVisible() -> Bool { surface.visibleText().replacingOccurrences(of: "\n", with: "").contains("SPOOKKY_SIDEBAR_UNSENT") }
        for _ in 0..<100 {
            if unsentInputVisible() { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        interactionDetails["input_before_collapse"] = String(surface.visibleText().suffix(300))
        let before = try await launches.runtime.inspect(binding)
        conversationSidebar.onActivate?(projectKey)
        let after = try await launches.runtime.inspect(binding)
        checks["collapse_preserves_running_process"] = before?.processID != nil && before?.processID == after?.processID && surfaces.view(shellID) === surface
        conversationSidebar.onActivate?(projectKey)
        checks["collapse_preserves_terminal_input"] = unsentInputVisible()
        interactionDetails["input_after_collapse"] = String(surface.visibleText().suffix(300))
        checks["agent_draft_survives_shell_and_collapse"] = store.state.tab(original.selectedTabID)?.draft == original.tabs[0].draft
        func nativeControls(_ view: NSView) -> [NSControl] { (view as? NSControl).map { [$0] } ?? view.subviews.flatMap(nativeControls) }
        let controls = nativeControls(window.contentView!).filter { control in
            if let field = control as? NSTextField { return field.isEditable || field.isSelectable }
            return control is NSButton || control is NSTableView
        }
        checks["native_chrome_controls_have_no_focus_ring"] = !controls.isEmpty && controls.allSatisfy { $0.focusRingType == .none && $0.cell?.focusRingType != .exterior }
        let nativeAlert = ChromeAlert()
        let standardControls: [NSControl] = [ChromeTextField(), ChromeSearchField(), ChromePopUpButton(), ChromeButton(), nativeAlert.addButton(withTitle: "Done")]
        checks["shared_native_control_defaults_suppress_focus_rings"] = standardControls.allSatisfy { $0.focusRingType == .none && $0.cell?.focusRingType == NSFocusRingType.none }
        checks["custom_search_cells_remain_editable"] = historySearch.isEditable && historySearch.isSelectable &&
            standardControls.compactMap { $0 as? NSSearchField }.allSatisfy { $0.isEditable && $0.isSelectable }
        interactionDetails["native_control_focus_types"] = controls.map { String(describing: type(of: $0)) + ":" + String($0.focusRingType.rawValue) + ":" + String(describing: $0.cell?.focusRingType) }.joined(separator: ", ")
        let action = ActionButton("Keyboard action", action: {})
        let intrinsicSize = action.intrinsicContentSize
        let buttonFrame = NSRect(x: 24, y: 24, width: 140, height: 28)
        action.frame = buttonFrame; window.contentView?.addSubview(action)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<100 {
            if window.isKeyWindow && NSApp.isActive { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.makeFirstResponder(action)
        checks["keyboard_button_feedback_keeps_bounds_and_intrinsic_size"] = action.showsKeyboardFocus && action.frame == buttonFrame && action.intrinsicContentSize == intrinsicSize && action.focusRingType == .none
        action.removeFromSuperview(); window.makeFirstResponder(surface)
        NSApp.sendAction(NSSelectorFromString("showSettings"), to: services, from: nil)
        if let settings = NSApp.windows.first(where: { $0.title == "Spookky Settings" }), let content = settings.contentView {
            let settingsControls = nativeControls(content).filter { control in
                if let field = control as? NSTextField { return field.isEditable || field.isSelectable }
                return control is NSButton || control is NSSlider
            }
            checks["settings_controls_have_no_focus_ring"] = settingsControls.contains { $0 is NSSlider } && settingsControls.allSatisfy {
                $0.focusRingType == .none && $0.cell?.focusRingType == NSFocusRingType.none
            }
            settings.close(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(surface)
        } else { checks["settings_controls_have_no_focus_ring"] = false }
        func cpuSeconds() -> Double {
            var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let idleStart = cpuSeconds(), idleTime = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        let idleCPU = (cpuSeconds() - idleStart) / (ProcessInfo.processInfo.systemUptime - idleTime) * 100
        conversationSidebar.focusItem(workspaceKey)
        let activeStart = cpuSeconds(), activeTime = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        let activeCPU = (cpuSeconds() - activeStart) / (ProcessInfo.processInfo.systemUptime - activeTime) * 100
        window.makeFirstResponder(nil)
        let resources: [String: Double] = ["idle_app_cpu_percent": idleCPU, "focused_sidebar_app_cpu_percent": activeCPU,
            "app_rss_mib": WorkspaceDiagnostics.residentMiB() ?? -1, "terminal_session_count": 1,
            "virtual_history_items": 5_000, "mounted_sidebar_cells": Double(conversationSidebar.visibleCellCount)]
        if CommandLine.arguments.contains("--workspace-benchmark-display") {
            store.update { $0.openSupport(.changes, title: "Changes"); $0.openSupport(.file(path: root.appendingPathComponent("appearance-config").path), title: "Settings file") }
            checks.merge(try await DisplayPolishFixture.check(window: window, root: root, sidebar: conversationSidebar,
                apply: { preferences in self.services.changeDisplay { $0 = preferences } },
                tabs: { Array(self.tabPairs.values) + self.workspaceLayout.tabItems },
                layout: { mode in self.store.update { $0.setSupportingLayout(mode) } },
                setAppearance: { appearance in self.store.update { $0.appearance = appearance } }), uniquingKeysWith: { _, new in new })
        }
        func perform(_ title: String, in menu: NSMenu) throws {
            guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { throw LaunchError.invalid("Thread action unavailable: " + title) }
            guard NSApp.sendAction(action, to: item.target, from: item) else { throw LaunchError.invalid("Thread action failed: " + title) }
        }
        let threadKey = store.state.selected!.threadKey, activeWorkspace = store.state.selectedWorkspaceID!
        try perform("Pin", in: workspaceContextMenu(activeWorkspace))
        let pinnedKey = "pinned:" + threadKey
        checks["pin_preserves_thread_and_execution"] = store.state.presentation(for: threadKey).pinnedAt != nil && store.state.selectedWorkspaceID == activeWorkspace && store.state.tab(shellID)?.binding == binding
        conversationSidebar.onActivate?(pinnedKey)
        checks["pinned_occurrence_is_only_selected_row"] = conversationSidebar.selectedItemIDs == [pinnedKey] && store.state.selectedWorkspaceID == activeWorkspace
        try perform("Archive", in: workspaceContextMenu(activeWorkspace))
        checks["archive_preserves_running_thread_and_reaches_composer"] = store.state.selected?.isLanding == true && store.state.workspaces.first(where: { $0.id == activeWorkspace }).map(store.state.isArchived) == true && store.state.tab(shellID)?.binding == binding
        showingArchived = true; chromeRevision = ""; render()
        let archivedKey = "archived:" + threadKey
        if let menu = conversationSidebar.onContextMenu?(archivedKey) { try perform("Unarchive", in: menu) }
        checks["archived_row_unarchive_uses_same_identity"] = store.state.presentation(for: threadKey).archivedAt == nil && store.state.tab(shellID)?.binding == binding
        showingArchived = false; selectedSidebarOccurrence = nil; selectWorkspace(activeWorkspace)
        try perform("Unpin", in: workspaceContextMenu(activeWorkspace))
        try PrivateFiles.write(resources, to: root.appendingPathComponent("sidebar-resources.json"))
        try PrivateFiles.write(interactionDetails, to: root.appendingPathComponent("sidebar-interaction-diagnostics.json"))
        try await store.flush(); try PrivateFiles.write(checks, to: root.appendingPathComponent("sidebar-checks.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Sidebar fixture failed: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", ")) }
    }
    private func renderContent(started: Double) async {
        guard window.isVisible else { return }
        let ids = store.state.visibleTabIDs, records = ids.compactMap { store.state.tab($0) }
        let terminals = records.filter { $0.status == .running || $0.status == .ended }
        let warm = !terminals.isEmpty && terminals.allSatisfy { surfaces.view($0.id) != nil }
        do {
            var sizes: [UUID: NSSize] = [:]
            for tab in records {
                let bounds = tab.id == store.state.primaryTerminalID ? body.bounds : supportingTerminal.bounds
                sizes[tab.id] = NSSize(width: max(1, bounds.width), height: max(1, bounds.height - (tab.status == .running ? 0 : SpookkyStyle.headerHeight)))
            }
            let prepared = try await surfaces.prepare(terminals, sizes: sizes)
            guard !Task.isCancelled, let prepared, ids == store.state.visibleTabIDs else { return }
            body.subviews.forEach { $0.removeFromSuperview() }; paneHeaders.removeAll(); paneTitles.removeAll(); agentHeaderLabels.removeAll()
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
            if !workspaceLayout.hasFocus {
                if let active, let surface = prepared[active] { window.makeFirstResponder(surface) }
                else if let active { composers[active]?.focus() }
            }
            body.layoutSubtreeIfNeeded()
            try await surfaces.restoreViewports(ids)
            guard !Task.isCancelled, ids == store.state.visibleTabIDs else { return }
            if !terminals.isEmpty { diagnostics?.record(elapsed: ProcessInfo.processInfo.systemUptime - started, warm: warm, surfaces: surfaces.count) }
            let retained = Set(store.state.workspaces.flatMap(\.tabs).map(\.id))
            composers = composers.filter { retained.contains($0.key) }
            refreshAgentAttention()
        } catch {
            guard !Task.isCancelled, ids == store.state.visibleTabIDs else { return }
            for tab in records where tab.binding != nil {
                store.update { $0.apply(.failure(.failed, TabFailure(.attachment, error.localizedDescription), clearIntent: false), to: tab.id) }
            }
        }
    }
    private func pane(_ tab: WorkspaceTab, surface: TerminalHostView?) -> NSView {
        let container = NSView()
        if let workspace = store.state.workspace(containing: tab.id), workspace.primaryTerminalID == tab.id,
           workspace.catalogMetadata != nil, tab.binding == nil, tab.launch == nil {
            let message = ChromeTextField(wrappingLabelWithString: workspace.catalogMetadata?.displayTitle ?? workspace.title)
            message.font = .systemFont(ofSize: SpookkyStyle.points(15), weight: .medium)
            let identity = workspace.conversationID
            let opening = identity.map { continuingConversations.contains($0) } ?? false
            let error = identity.flatMap { continuationErrors[$0] }
            let action = ActionButton(opening ? "Opening conversation…" : error == nil ? "Continue saved conversation" : "Retry", symbol: opening ? "clock" : "arrow.up.forward") { [weak self] in self?.openConversationWorkspace(workspace.id) }
            action.isEnabled = !opening
            let details = ChromeTextField(wrappingLabelWithString: error ?? "Open this saved conversation in its original folder.")
            details.textColor = SpookkyPalette.secondary
            let stack = NSStackView(views: [message, details, action]); stack.orientation = .vertical; stack.alignment = .leading
            stack.spacing = SpookkyStyle.points(12); stack.edgeInsets = NSEdgeInsets(top: SpookkyStyle.points(24), left: SpookkyStyle.points(24), bottom: SpookkyStyle.points(24), right: SpookkyStyle.points(24))
            install(stack, in: container)
        } else if tab.isEditable || tab.status == .preparing || tab.status == .launching {
            let composer = composers[tab.id] ?? LaunchComposerView(tabID: tab.id); composers[tab.id] = composer
            composer.onDraft = { [weak self] tool, prompt in self?.store.update(debounced: prompt != nil) { $0.editDraft(tab.id, tool: tool, prompt: prompt) } }
            composer.onLaunch = { [weak self] in self?.launch(tab.id) }
            composer.onTerminal = { [weak self] in self?.openTerminal(from: tab.id) }
            composer.onChooseFolder = { [weak self] in self?.chooseFolder(register: false) }
            composer.onAddProject = { [weak self] anchor in self?.addProjectMenu(anchor: anchor) }
            composer.onLocate = { [weak self] in self?.chooseFolder(register: false, relocate: true) }
            composer.onProject = { [weak self] id in self?.chooseProject(id) }
            composer.onFocus = { [weak self] in self?.selectTab(tab.id) }
            if let w = store.state.workspace(containing: tab.id) {
                composer.repositorySnapshot = w.projectID.flatMap { repositorySnapshots[$0] }
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
                install(surface, in: container)
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
                    let opening = continuingConversations.contains(identity)
                    let resume = ActionButton(opening ? "Resuming…" : "Resume conversation", symbol: "arrow.clockwise") { [weak self] in
                        self?.openConversationWorkspace(workspace.id)
                    }
                    resume.isEnabled = !opening
                    resume.toolTip = continuationErrors[identity] ?? "Resume this exact conversation in its original folder"
                    headerViews.append(resume)
                    if let error = continuationErrors[identity] {
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
                    stack.addArrangedSubview(ActionButton(tab.binding != nil ? "Reconnect" : "Check session", symbol: "arrow.clockwise") { [weak self] in self?.reconnect(tab.id) })
                }
                stack.addArrangedSubview(ActionButton("Open a new Terminal", symbol: "terminal") { [weak self] in
                    guard let self else { return }; self.store.update { $0.newTab() }; if let id = self.store.state.selectedTab?.id { self.launch(id, tool: .shell) }
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
    private func install(_ view: NSView, in parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: parent.leadingAnchor), view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.topAnchor), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
    }
    private func focusSelectedContent() {
        guard let id = store.state.primaryTerminalID else { return }
        store.update { $0.selectPrimaryContent() }
        if let view = surfaces.view(id), [.running, .ended].contains(store.state.tab(id)?.status) {
            window.makeFirstResponder(view)
        } else { composers[id]?.focus() }
    }
    private func selectWorkspace(_ id: UUID) {
        if store.state.selectedWorkspaceID != id { cancelLaunchPreflight() }
        renameEditor?.cancel(); renameEditor = nil
        if store.state.selectedWorkspaceID == id { focusSelectedContent() }
        else { store.update { $0.selectWorkspace(id) } }
        scheduleRepositoryRefresh()
        refreshAgentAttention(clearManual: true)
    }
    private func selectTab(_ id: UUID) {
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
    private func moveTabFocus(from id: UUID, offset: Int) {
        guard let tabs = store.state.selected?.tabs, let index = tabs.firstIndex(where: { $0.id == id }), !tabs.isEmpty else { return }
        let target = tabs[(index + offset + tabs.count) % tabs.count].id
        guard let pair = tabPairs[target] else { return }
        pair.scrollToVisible(pair.bounds); window.makeFirstResponder(pair.titleButton)
    }
    private func cycleTab(_ offset: Int) {
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
    @objc private func nextTab() { cycleTab(1) }
    @objc private func previousTab() { cycleTab(-1) }
    @objc private func renameSelectedTab() { if let id = store.state.selectedWorkspaceID { rename(workspaceID: id) } }
    @objc private func focusSidebar() {
        conversationSidebar.focusItem()
    }
    @objc private func focusTabStrip() { if let id = store.state.selectedTab?.id { moveTabFocus(from: id, offset: 0) } }
    @objc private func focusOtherPane() {
        if workspaceLayout.hasFocus { focusSelectedContent(); return }
        guard let selected = store.state.selected?.support?.selectedTabID else { return }
        store.update { $0.selectSupport(selected) }
        focusSupportingContent()
    }
    private func focusSupportingContent() {
        guard workspaceLayout.showsSupportingContent, store.state.selected?.support?.selected != nil else { focusSelectedContent(); return }
        if case .terminal(let id) = store.state.selected?.support?.selected?.target, let view = surfaces.view(id), view.window === window {
            window.makeFirstResponder(view)
        } else if let content = workspaceLayout.content.subviews.first, content.acceptsFirstResponder {
            window.makeFirstResponder(content)
        } else { window.makeFirstResponder(workspaceLayout.panel) }
    }
    private func handleClientExit(_ id: UUID) {
        guard store.state.tab(id)?.status == .running, surfaces.clientExited(id) else { return }
        surfaces.release(id)
        store.update { $0.apply(.failure(.failed, TabFailure(.attachment, "Terminal view disconnected. Your session is still running."), clearIntent: false), to: id) }
    }
    @objc private func newWorkspace() {
        let hidden = !window.isVisible
        cancelLaunchPreflight()
        store.update { $0.showLanding(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path) }
        if hidden { reopen() }
        if let id = store.state.primaryTerminalID { composers[id]?.focus() }
    }
    private func addBlankTab() { files.revealTerminal(); if store.state.selected == nil { newWorkspace() } else { store.update { $0.newTab() } } }
    @objc private func newTab() {
        if store.state.selected == nil { newWorkspace() }
        if !window.isVisible { showWindow() }
        store.update { $0.openSupport(.startPage, title: "New tab") }; focusSupportingContent()
    }
    private func openTerminal(from id: UUID) {
        guard let tab = store.state.tab(id) else { return }
        if let workspace = store.state.workspace(containing: id), workspace.isLanding, workspace.primaryTerminalID == id {
            var shellID: UUID!
            store.update {
                $0.newWorkspace(location: workspace.anchor ?? workspace.selectedLocation, projectID: workspace.projectID)
                shellID = $0.primaryTerminalID; $0.editDraft(shellID, tool: .shell, prompt: "")
            }
            launch(shellID, tool: .shell); return
        }
        if !tab.draft.prompt.isEmpty || !tab.isEditable || store.state.workspace(containing: id)?.primaryTerminalID == id && tab.binding != nil {
            store.update { $0.newTab() }; if let id = store.state.selectedTab?.id { launch(id, tool: .shell) }
        } else { launch(id, tool: .shell) }
    }
    @objc private func launchSelected() {
        guard let id = store.state.selectedTab?.id, composers[id]?.hasInputFocus == true else { return }; launch(id)
    }
    private func launch(_ id: UUID, tool: SessionTool? = nil) {
        guard initialLaunchTasks[id] == nil, let tab = store.state.tab(id),
              let workspace = store.state.workspace(containing: id), !launches.isBusy(id),
              tab.isEditable || (tab.status == .failed && tab.launch != nil) else { return }
        if (tool ?? tab.draft.tool) != .shell, workspace.primaryTerminalID != id {
            store.update { $0.separateAgentTerminal(id) }; launch(id, tool: tool); return
        }
        if workspace.locationOwnerWorkspaceID != nil {
            var resolved = false
            store.update { resolved = $0.resolveConversationLocation(workspaceID: workspace.id) }
            if resolved { launch(id, tool: tool) }
            else { alert("Location is not ready", "This draft shares a retained location operation. Finish or recover that operation, or choose a folder explicitly.") }
            return
        }
        let deleting = store.state.locations?.operations.contains { $0.status == .running && $0.request.kind == .deleteWorktree && $0.request.destination == workspace.selectedLocation.scopePath } ?? false
        guard !deleting else { alert("Worktree removal in progress", "Wait for removal to finish before launching here."); return }
        initialLaunchTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { initialLaunchTasks[id] = nil }
            do {
                await agentPreferencesTask?.value
                try Task.checkCancellation()
                if workspace.anchor == nil && (workspace.locationDraft?.mode == .worktree || workspace.locationOperationID != nil) {
                    store.update { $0.apply(.preparing, to: id) }
                    _ = try await locations.prepare(workspaceID: workspace.id)
                }
                try Task.checkCancellation()
                guard store.state.tab(id) != nil else { return }
                await launches.launch(id, tool: tool)
            } catch is CancellationError {
                store.update { $0.cancelPreparation(id, restoring: tab) }
            } catch {
                let recovery: FailureRecovery?
                if case .folderUnavailable = error as? LaunchError { recovery = .locateFolder } else { recovery = nil }
                store.update { $0.apply(.failure(.failed, TabFailure(.validation, error.localizedDescription, recovery: recovery), clearIntent: true), to: id) }
            }
        }
    }
    private func reconnect(_ id: UUID) {
        Task {
            surfaces.release(id)
            await launches.reconcile(id)
            contentKey = ""; render()
        }
    }
    private func split(_ id: UUID) {
        guard store.state.tab(id)?.status == .running else { return }
        var newID: UUID?
        store.update { state in newID = state.newTab() }
        if let newID { launch(newID, tool: .shell) }
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
    private func rememberWindowFrame() {
        guard store.onChange != nil, let window, !fullscreenTransition, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        store.update(debounced: true) { $0.windowFrame = WorkspaceWindowFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height) }
    }
    private func newProjectWorkspace(_ id: UUID) {
        guard store.state.projects.contains(where: { $0.id == id }) else { return }
        cancelLaunchPreflight()
        store.update { $0.showLanding(projectID: id, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path) }
        scheduleRepositoryRefresh()
    }
    private func chooseProject(_ id: UUID) {
        guard let project = store.state.projects.first(where: { $0.id == id }), let w = store.state.selected else { return }
        store.update { $0.setLocation(project.location, projectID: id, workspaceID: w.id) }
        scheduleRepositoryRefresh()
    }
    private func scheduleRepositoryRefresh() {
        repositoryRefreshTask?.cancel()
        repositoryRefreshTask = Task { await refreshSelectedRepository() }
    }
    private func refreshSelectedRepository() async {
        guard let workspace = store.state.selected, let projectID = workspace.projectID, workspace.selectedLocation.isGit else { return }
        let generation = UUID(); repositoryGenerations[projectID] = generation
        do {
            let snapshot = try await locations.git.snapshot(workspace.selectedLocation)
            guard repositoryGenerations[projectID] == generation else { return }
            repositorySnapshots[projectID] = snapshot
            store.update { state in
                state.refreshProject(projectID, location: snapshot.location)
                for checkout in snapshot.checkouts where checkout.available {
                    state.recordCheckout(WorkspaceLocation(path: checkout.path, checkoutIdentity: checkout.identity,
                        branch: checkout.branch, commonRepository: snapshot.location.commonRepository))
                }
                if let current = state.workspaces.first(where: { $0.id == workspace.id }), current.anchor == nil, current.locationDraft == nil {
                    var draft = LocationDraft()
                    draft.source = state.projects.first { $0.id == projectID }?.preferredSource ?? snapshot.defaultSource
                    state.editLocation(draft, workspaceID: workspace.id)
                }
            }
            render()
        } catch is CancellationError { return }
        catch { if store.state.selectedWorkspaceID == workspace.id { alert("Could not read repository", error.localizedDescription) } }
    }
    private func makeProjectMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open folder…") { [weak self] in self?.chooseFolder(register: true) })
        let create = ClosureMenuItem("Create project…") { [weak self] in DispatchQueue.main.async { self?.showProjectCreation(.create) } }
        let clone = ClosureMenuItem("Clone repository…") { [weak self] in DispatchQueue.main.async { self?.showProjectCreation(.clone) } }
        menu.autoenablesItems = false
        create.isEnabled = projectCreation?.isWorking != true; clone.isEnabled = create.isEnabled
        menu.addItem(create); menu.addItem(clone)
        return menu
    }
    private func addProjectMenu(anchor: NSView?) {
        let menu = makeProjectMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor?.bounds.height ?? 28), in: anchor ?? rail)
    }
    private func showProjectCreation(_ mode: ProjectCreationMode) {
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
            store.update {
                let projectID = $0.registerProject(location)
                guard $0.selectedWorkspaceID == startingWorkspaceID else { return }
                if let workspace = $0.selected, workspace.anchor == nil { $0.setLocation(location, projectID: projectID, workspaceID: workspace.id) }
                else { $0.newWorkspace(location: location, projectID: projectID) }
            }
            self.scheduleRepositoryRefresh()
        }
        form.onClose = { [weak self] in self?.projectCreation = nil; self?.focusSelectedContent() }
        form.show(relativeTo: window)
    }
    private func deleteWorktree(_ record: CheckoutRecord) {
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
    private func showLocationOperations() {
        let operations = store.state.locations?.operations ?? []
        let text = operations.suffix(10).map { operation -> String in
            let heading = operation.request.kind.rawValue + " · " + operation.status.rawValue
            let phase = operation.error ?? operation.receipts.last?.phase.rawValue ?? "intent"
            return heading + "\n" + operation.request.destination + "\n" + phase
        }.joined(separator: "\n\n")
        alert("Project operations", text.isEmpty ? "No project operations yet." : text)
    }
    private func chooseFolder(register: Bool, relocate: Bool = false) {
        guard window.attachedSheet == nil else { return }
        if !window.isVisible { reopen() }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = register ? "Add project" : "Open"; let workspaceID = store.state.selectedWorkspaceID
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    let location = try await LocationDiscovery.discover(url)
                    self.store.update {
                        let projectID = register ? $0.registerProject(location) : nil
                        if let workspaceID {
                            if relocate { $0.relocateWorkspace(workspaceID, location: location) }
                            else if register && $0.selectedWorkspaceID == workspaceID && $0.workspaces.first(where: { $0.id == workspaceID })?.anchor != nil {
                                $0.newWorkspace(location: location, projectID: projectID)
                            } else { $0.setLocation(location, projectID: projectID, workspaceID: workspaceID) }
                        }
                    }
                    await self.refreshSelectedRepository()
                } catch { self.alert("Could not open folder", error.localizedDescription) }
            }
        }
    }
    private func rename(tabID: UUID? = nil, workspaceID: UUID? = nil) {
        renameEditor?.cancel(); renameEditor = nil
        if store.state.sidebarCollapsed, workspaceID != nil { store.update { $0.sidebarCollapsed = false } }
        if let workspaceID, let projectID = store.state.workspaces.first(where: { $0.id == workspaceID })?.projectID {
            store.update { $0.setProjectCollapsed(projectID, false) }
        }
        let button = tabID.flatMap { tabPairs[$0]?.titleButton }
        guard let button else {
            if let workspaceID, let workspace = store.state.workspaces.first(where: { $0.id == workspaceID }) {
                presentThreadName(workspace.displayTitle) { [weak self] name in
                    guard let self else { return }
                    store.update { $0.renameWorkspace(workspaceID, name) }
                    if let metadata = workspace.catalogMetadata {
                        Task {
                            do { try await self.historyCatalog.rename(metadata.id, alias: name) }
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
    @objc private func findWorkspace() {
        if !window.isVisible { reopen() }
        if store.state.sidebarCollapsed { store.update { $0.sidebarCollapsed = false } }
        window.makeFirstResponder(historySearch)
    }
    @objc private func closeSelectedTab() {
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            keyWindow.performClose(nil)
            return
        }
        if workspaceLayout.hasFocus, workspaceLayout.showsSupportingContent, let id = store.state.selected?.support?.selectedTabID {
            store.update { $0.closeSupport(id) }; focusSupportingContent()
        } else { window.performClose(nil) }
    }
    private func stopPrimaryAgent(_ workspaceID: UUID? = nil) {
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
    private func confirm(_ title: String, _ message: String, action: String = "Close") async -> Bool {
        let alert = ChromeAlert(); alert.messageText = title; alert.informativeText = message
        let close = alert.addButton(withTitle: action)
        close.keyEquivalent = "\r"; close.keyEquivalentModifierMask = []
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        alert.window.defaultButtonCell = close.cell as? NSButtonCell
        return await present(alert) == .alertFirstButtonReturn
    }
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if !window.isVisible { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
    private func alert(_ title: String, _ message: String) {
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
    func prepareToQuit() -> NSApplication.TerminateReply {
        services.flushDisplayPreferences()
        cancelLaunchPreflight()
        guard !(store.state.locations?.operations.contains(where: { $0.status == .running }) ?? false),
              !store.state.workspaces.flatMap(\.tabs).contains(where: { launches.isBusy($0.id) }) else { return .terminateCancel }
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
                    if result == .alertSecondButtonReturn { NSApp.reply(toApplicationShouldTerminate: false); return }
                    if result == .alertThirdButtonReturn {
                        for tab in store.state.workspaces.flatMap(\.tabs) { try await launches.terminate(tab.id) }
                    }
                }
                await surfaces.captureViewports()
                try await store.flush(); surfaces.releaseAll(); NSApp.reply(toApplicationShouldTerminate: true)
            } catch { alert("Could not quit safely", error.localizedDescription); NSApp.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
    func windowWillClose(_ notification: Notification) {
        cancelLaunchPreflight()
        continuationTask?.cancel()
        files.suspend()
        renderTask?.cancel(); surfaces.invalidate(); contentKey = ""
        Task { await surfaces.captureViewports(); if !window.isVisible { surfaces.releaseAll() }; try? await store.flush() }
    }
    func reopen() {
        if store.state.selected == nil {
            store.update { $0.showLanding(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path) }
        }
        showWindow()
        contentKey = ""; render(); observeRuntimeEvent() }
    private func showWindow() {
        if backgroundFixture { window.orderBack(nil) }
        else { window.makeKeyAndOrderFront(nil) }
    }
    func recordBenchmarkFailure(root: URL) {
        guard diagnostics != nil, CommandLine.arguments.contains("--workspace-benchmark-continuity") else { return }
        struct Tab: Encodable {
            let id: UUID
            let bindingID: UUID?
            let status: String
            let failure: String?
            let surface: Bool
        }
        struct Failure: Encodable {
            let selectedTab: UUID?
            let visibleTabs: [UUID]
            let windowVisible: Bool
            let windowKey: Bool
            let appActive: Bool
            let closeRequests: [[String: String]]
            let tabs: [Tab]
        }
        let snapshot = Failure(selectedTab: store.state.selectedTab?.id, visibleTabs: store.state.visibleTabIDs,
            windowVisible: window.isVisible, windowKey: window.isKeyWindow, appActive: NSApp.isActive,
            closeRequests: fixtureCloseRequests, tabs: store.state.workspaces.flatMap(\.tabs).prefix(32).map {
                Tab(id: $0.id, bindingID: $0.binding?.id, status: $0.status.rawValue,
                    failure: $0.failure.map { String($0.message.prefix(512)) }, surface: surfaces.view($0.id) != nil)
            })
        try? PrivateFiles.write(snapshot, to: root.appendingPathComponent("continuity-failure.json"))
    }
    func setFocus(_ focused: Bool) { surfaces.setFocus(focused); if focused { observeRuntimeEvent() } }
    func benchmark(count: Int, root: URL, timing: Bool) async throws {
        let fileFixture = CommandLine.arguments.contains("--workspace-benchmark-files")
        let conversationFixture = CommandLine.arguments.contains("--workspace-benchmark-conversations")
        if conversationFixture { store.update { $0.changeDirectory(root.path) } }
        if fileFixture {
            let location = try await GitRepository().discover(root.appendingPathComponent("code"))
            if let id = store.state.selectedWorkspaceID {
                store.update { $0.setLocation(location, projectID: nil, workspaceID: id) }
            }
        }
        if CommandLine.arguments.contains("--workspace-benchmark-races") { store.update { $0.changeDirectory(root.path) } }
        var ids: [UUID] = []
        for _ in 0..<count {
            var id: UUID?
            store.update {
                if ids.isEmpty { id = $0.selectedTab?.id }
                else if conversationFixture {
                    $0.newWorkspace(directory: root.path)
                    id = $0.primaryTerminalID
                } else { id = $0.newTab() }
            }
            guard let id else { throw LaunchError.invalid("Benchmark tab is unavailable.") }
            await launches.launch(id, tool: .shell)
            guard store.state.tab(id)?.binding != nil else { throw LaunchError.invalid("Benchmark launch failed.") }
            ids.append(id)
        }
        if CommandLine.arguments.contains("--workspace-benchmark-activity") {
            services.agentPreferences.inputSound = false; services.agentPreferences.finishedSound = false; services.agentPreferences.failedSound = false
            await agentPreferencesTask?.value
            if let first = ids.first { store.update { $0.selectTab(first) } }
            if let renderTask { await renderTask.value }
            for (index, id) in ids.enumerated() {
                guard let binding = store.state.tab(id)?.binding else { continue }
                let path = root.appendingPathComponent("agent-terminal-" + binding.id.uuidString + ".json")
                let context = try AgentIntegration.read(AgentTerminalContext.self, path: path.path)
                let invocation = AgentInvocation(context: context, provider: index % 2 == 0 ? .codex : .claude)
                try PrivateFiles.write(invocation, to: URL(fileURLWithPath: invocation.path))
                try PrivateFiles.write(invocation, to: URL(fileURLWithPath: context.activePath))
                AgentActivitySocket.send(invocation.event(.attached), socket: context.socket)
                AgentActivitySocket.send(invocation.event([.working, .needsInput, .finished, .failed, .unsupported][index % 5]), socket: context.socket)
            }
            try await Task.sleep(for: .milliseconds(350))
            let snapshot = store.state.workspaces.flatMap(\.tabs).compactMap { tab -> [String: String]? in
                guard let activity = tab.activity else { return nil }
                return ["tabID": tab.id.uuidString, "state": activity.displayState.rawValue, "unread": String(activity.unread)]
            }
            try PrivateFiles.write(snapshot, to: root.appendingPathComponent("activity-fixture.json"))
        }
        try await store.flush()
        if let renderTask { await renderTask.value }
        if CommandLine.arguments.contains("--workspace-benchmark-split"), ids.count >= 2 {
            store.update { $0.setSplit(first: ids[0], second: ids[1]) }
            if let renderTask { await renderTask.value }
        }
        if fileFixture, let id = store.state.selectedWorkspaceID {
            var view = FileViewState(); view.sidebar = true; view.changes = true
            view.preview = true; view.selectedPath = "sample.swift"; view.selectedGroup = "Unstaged"
            store.update {
                $0.setFileView(view, workspaceID: id)
                $0.openSupport(.changes, title: "Changes", workspaceID: id)
            }
            if let renderTask { await renderTask.value }
            await files.settleForFixture()
            if CommandLine.arguments.contains("--workspace-benchmark-diffs") {
                var samples: [Double] = [], counts: [[String: Int]] = [], phases: [[String: Double]] = []
                var otherID: UUID?
                store.update { otherID = $0.newWorkspace(directory: root.appendingPathComponent("other").path); $0.selectWorkspace(id) }
                for index in 0..<135 {
                    if index >= 35, let otherID {
                        store.update { $0.selectWorkspace(otherID) }; if let renderTask { await renderTask.value }
                        store.update { $0.selectWorkspace(id) }; if let renderTask { await renderTask.value }
                        await files.settleForFixture()
                    }
                    let path = index >= 35 && index % 2 == 0 ? "other.swift" : "sample.swift"
                    let elapsed = try await files.previewForFixture(path: path, group: "Unstaged", split: index >= 35 && index % 3 == 0, waitForSyntax: index < 35)
                    if index >= 5 && index < 35 { samples.append(elapsed); phases.append(files.previewTimings) }
                    if index == 34 {
                        try PrivateFiles.write(samples, to: root.appendingPathComponent("file-timings.json"))
                        try PrivateFiles.write(phases, to: root.appendingPathComponent("file-phases.json"))
                    }
                    if index >= 35 { counts.append(files.diagnostics.merging(["surfaces": surfaces.count], uniquingKeysWith: { _, new in new })) }
                }
                await files.settleSyntaxForFixture()
                let surface = store.state.selectedTab.flatMap { surfaces.view($0.id) }
                surface?.insertText("SPOOKKY_M3_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
                var interactions = try await files.interactionChecksForFixture()
                interactions["terminal_draft_preserved"] = surface?.visibleText().contains("SPOOKKY_M3_UNSENT") == true
                try PrivateFiles.write(interactions, to: root.appendingPathComponent("file-interactions.json"))
                try PrivateFiles.write(samples, to: root.appendingPathComponent("file-timings.json"))
                try PrivateFiles.write(counts, to: root.appendingPathComponent("file-cycles.json"))
            }
        }
        if CommandLine.arguments.contains("--workspace-benchmark-races"), let id = ids.first {
            try await surfaceRaceFixture(id: id, root: root)
        }
        if CommandLine.arguments.contains("--workspace-benchmark-selection"), let id = ids.first,
           let view = surfaces.view(id), let binding = store.state.tab(id)?.binding {
            try await TerminalSelectionFixture.run(view: view, binding: binding, runtime: launches.runtime, root: root)
        }
        if CommandLine.arguments.contains("--workspace-benchmark-project-association") {
            guard count == 0 else { throw LaunchError.invalid("Project association fixture starts with no running sessions.") }
            try await checkProjectAssociation(root: root)
        }
        if CommandLine.arguments.contains("--workspace-benchmark-identity") {
            guard count == 0 else { throw LaunchError.invalid("Identity fixtures start without running sessions.") }
            try await checkConversationIdentity(root: root)
        }
        if CommandLine.arguments.contains("--workspace-benchmark-history") {
            try await runHistorySidebarFixture(root: root)
        }
        if CommandLine.arguments.contains("--workspace-benchmark-sidebar") {
            guard count == 0 else { throw LaunchError.invalid("Sidebar fixtures start without running sessions.") }
            try await checkSidebar(root: root)
        }
        if CommandLine.arguments.contains("--workspace-benchmark-sidebar-reference") {
            guard count == 0 else { throw LaunchError.invalid("Sidebar reference fixtures start without running sessions.") }
            let previousAppearance = store.state.appearance
            defer { store.update { $0.appearance = previousAppearance } }
            try await SidebarReferenceFixture.run(window: window, root: root,
                setAppearance: { appearance in self.store.update { $0.appearance = appearance } })
        }
        if CommandLine.arguments.contains("--workspace-benchmark-browser") {
            guard count == 0, let host = supportingContentHost as? BrowserArtifactContentHost else { throw LaunchError.invalid("Browser fixtures require no launched sessions.") }
            try await SupportingPreviewFixture.run(window: window, host: host, state: { self.store.state },
                mutate: { change in self.store.update(change) }, command: { self.handleCommand($0) },
                submitAddress: { id, input in self.startPages[id]?.onAddress?(input) },
                openTerminal: { if let id = self.store.state.primaryTerminalID { self.openTerminal(from: id) } },
                terminal: { self.store.state.primaryTerminalID.flatMap { self.surfaces.view($0) } }, runtime: launches.runtime, root: root)
            try await store.flush()
        }
        if CommandLine.arguments.contains("--workspace-benchmark-close") {
            guard count == 0 else { throw LaunchError.invalid("Close fixtures start with one unlaunched tab.") }
            let fixtureHost = SupportingContentFixtureHost(); supportingContentHost = fixtureHost
            try await WorkspaceCloseFixture.run(window: window, state: { self.store.state }, runtime: launches.runtime,
                view: { self.surfaces.view($0) }, command: { self.handleCommand($0) }, reopen: { self.reopen() },
                openTerminal: { if let id = self.store.state.primaryTerminalID { self.openTerminal(from: id) } },
                openBrowser: { id in self.store.update { $0.updateSupport(id, target: .browser(url: "about:blank"), title: "Browser") }; self.focusSupportingContent() },
                supportingView: { self.workspaceLayout.panel }, selectWorkspace: { id in self.store.update { $0.selectWorkspace(id) } },
                openSupportingTerminal: { if let id = self.store.state.primaryTerminalID { self.openTerminal(from: id) } },
                reopenSupportingTerminal: { id in
                    self.store.update { $0.openSupport(.startPage, title: "New tab") }
                    self.renderSupportingContent()
                    func button(_ view: NSView) -> NSButton? {
                        if view.identifier?.rawValue == "reopen-terminal:" + id.uuidString { return view as? NSButton }
                        return view.subviews.lazy.compactMap { button($0) }.first
                    }
                    if let page = self.workspaceLayout.panel.subviews.first { button(page)?.performClick(nil) }
                },
                prepareStop: { self.store.update { state in if let id = state.selectedWorkspaceID { state.associateConversation(ConversationID(provider: .codex, sessionID: "disposable-stop-fixture"), workspaceID: id) } } },
                stop: { self.stopPrimaryAgent() }, setAppearance: { appearance in self.store.update { $0.appearance = appearance } },
                support: { id, layout in self.store.update { state in if let id { state.selectSupport(id) }; if let layout { state.setSupportingLayout(layout) } } },
                host: fixtureHost,
                settled: { self.closing.isEmpty && !self.store.state.workspaces.flatMap(\.tabs).contains { self.launches.isBusy($0.id) } }, root: root)
            try await store.flush()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--workspace-benchmark-continuity") {
            guard CommandLine.arguments.count > index + 1,
                  let seconds = Int(CommandLine.arguments[index + 1]), (1...28800).contains(seconds), ids.count == 10 else {
                throw LaunchError.invalid("Continuity requires ten fixture sessions and a duration from 1 to 28800 seconds.")
            }
            try await continuityFixture(ids: ids, root: root, seconds: seconds)
        }
        let observations = try await launches.runtime.list()
        var pids: [UUID: Int32] = [:]
        for binding in observations { pids[binding.id] = try await launches.runtime.inspect(binding)?.processID }
        if timing && ids.count >= 4 {
            var warmSwitches: [Double] = [], recreatedSwitches: [Double] = []
            func selectFixtureTerminal(_ id: UUID) async throws {
                let warm = surfaces.view(id) != nil
                let started = ProcessInfo.processInfo.systemUptime
                store.update { state in
                    if conversationFixture, let workspace = state.workspace(containing: id) { state.selectWorkspace(workspace.id) }
                    state.selectTab(id)
                }
                if let renderTask { await renderTask.value }
                guard surfaces.view(id) != nil else { throw LaunchError.invalid("Benchmark attachment failed.") }
                let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                if warm { warmSwitches.append(elapsed) } else { recreatedSwitches.append(elapsed) }
            }
            for index in 0..<40 {
                try await selectFixtureTerminal(ids[index % 2])
            }
            let cycleCount = try WorkspaceBenchmarkOptions.cycleCount()
            for index in 0..<cycleCount {
                let id = ids[index % ids.count]
                try await selectFixtureTerminal(id)
            }
            if conversationFixture {
                try PrivateFiles.write(["warm": warmSwitches, "recreated": recreatedSwitches],
                                       to: root.appendingPathComponent("conversation-selection-timings.json"))
            }
            for binding in observations {
                guard try await launches.runtime.inspect(binding)?.processID == pids[binding.id] else { throw LaunchError.invalid("Benchmark process identity changed.") }
            }
            let id = ids[0]
            try await selectFixtureTerminal(id)
            guard let view = surfaces.view(id) else { throw LaunchError.invalid("Fixture surface is unavailable.") }
            let fixtureCommand = CommandLine.arguments.contains("--workspace-benchmark-resize")
                ? "for i in {1..150}; do printf 'SPOOKKY_M1_FIXTURE_HISTORY_%s %0120d\\n' $i 0; done"
                : "for i in {1..150}; do echo SPOOKKY_M1_FIXTURE_HISTORY_$i; done"
            view.insertText(fixtureCommand, replacementRange: NSRange(location: NSNotFound, length: 0))
            guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { throw LaunchError.invalid("Fixture Enter event is unavailable.") }
            view.keyDown(with: enter)
            var outputReady = false
            for _ in 0..<100 {
                if view.visibleText().contains("SPOOKKY_M1_FIXTURE_HISTORY_150") { outputReady = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard outputReady else { throw LaunchError.invalid("Fixture command did not produce its expected terminal output.") }
            try await surfaces.scrollFixtureHistory(id, offset: CommandLine.arguments.contains("--workspace-benchmark-resize") ? nil : 25)
            var marker: Int?
            for _ in 0..<100 {
                marker = surfaces.fixtureHistoryMarker(id)
                if let marker, marker < 100 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let marker, marker < 100 else {
                throw LaunchError.invalid("Fixture viewport did not become ready. Fixture screen: " + String(view.visibleText().prefix(1200)))
            }
            if CommandLine.arguments.contains("--workspace-benchmark-resize") {
                let original = window.frame
                let expectedAnchor = store.state.tab(id)?.viewport?.anchor?.digest
                var checks: [String: Bool] = [:]
                for (name, size) in [("narrow", NSSize(width: 760, height: 570)), ("wide", NSSize(width: 1240, height: 850))] {
                    window.setFrame(NSRect(origin: original.origin, size: size), display: true)
                    body.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    for _ in 0..<100 {
                        if !surfaces.isResizing(id) { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let observed = try await surfaces.observedViewport(id)
                    checks[name + "_wrapped_anchor"] = expectedAnchor != nil && observed?.anchor?.digest == expectedAnchor && !surfaces.isResizing(id)
                }
                window.setFrame(original, display: true)
                try await Task.sleep(for: .milliseconds(500))
                try PrivateFiles.write(checks, to: root.appendingPathComponent("resize-checks.json"))
                guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Wrapped viewport resize check failed.") }
            }
            try await store.flush()
            try PrivateFiles.write(["expected_history_marker": marker], to: root.appendingPathComponent("fixture-history.json"))
        }
        try PrivateFiles.write(["pid": ProcessInfo.processInfo.processIdentifier, "session_count": Int32(observations.count),
                                "surface_count": Int32(surfaces.count), "workspace_count": Int32(store.state.workspaces.count)],
                               to: root.appendingPathComponent("ready.json"))
    }
    private func surfaceRaceFixture(id: UUID, root: URL) async throws {
        guard let owner = launches.runtime as? WorkspaceViewportFixtureRuntime,
              let view = surfaces.view(id) else { throw LaunchError.invalid("Race fixture is unavailable") }
        view.insertText("for i in {1..150}; do echo SPOOKKY_M4_RACE_$i; done", replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { throw LaunchError.invalid("Fixture Enter is unavailable") }
        view.keyDown(with: enter)
        for _ in 0..<100 {
            if view.visibleText().contains("SPOOKKY_M4_RACE_150") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await surfaces.scrollFixtureHistory(id)
        try await store.flush()
        guard let binding = store.state.tab(id)?.binding else { throw LaunchError.invalid("Fixture binding is unavailable") }
        guard let before = try await launches.runtime.inspect(binding)?.processID else { throw LaunchError.invalid("Fixture process is missing") }
        await owner.holdViewport(after: 2)
        let original = window.frame
        window.setFrame(NSRect(origin: original.origin, size: NSSize(width: 760, height: 570)), display: true)
        body.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if await owner.isHeld { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await owner.isHeld else { throw LaunchError.invalid("Resize fixture did not reach its delayed query") }
        surfaces.release(id)
        await owner.resume()
        for _ in 0..<100 {
            if surfaces.resizeTaskCount == 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let resizeSafe = surfaces.count == 0 && surfaces.resizeTaskCount == 0 && store.state.tab(id)?.status == .running
        window.setFrame(original, display: true)
        await owner.holdRestoration()
        contentKey = ""; render()
        for _ in 0..<100 {
            if await owner.isHeld { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await owner.isHeld else { throw LaunchError.invalid("Restoration fixture did not reach its delayed result") }
        let restoration = renderTask
        surfaces.invalidate(); surfaces.release(id)
        await owner.resume()
        if let restoration { await restoration.value }
        let restoreSafe = surfaces.count == 0 && surfaces.resizeAnchorCount == 0
        contentKey = ""; render()
        if let renderTask { await renderTask.value }
        let checks = ["released_surface_not_read_after_await": resizeSafe,
            "released_restoration_not_cached": restoreSafe,
            "same_process": before == (try await launches.runtime.inspect(binding)?.processID),
            "new_surface_attached": surfaces.view(id) != nil]
        try PrivateFiles.write(checks, to: root.appendingPathComponent("surface-races.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Surface race fixture failed") }
    }
    private func continuityFixture(ids: [UUID], root: URL, seconds: Int) async throws {
        struct Cycle: Codable {
            let index: Int
            let warmup: Bool
            let surfaces: Int
            let watchers: Int
            let previewBytes: Int
            let metadataBytes: Int
            let composers: Int
            let fileTaskHandles: Int
            let resizeTaskHandles: Int
            let launchOperations: Int
            let rssMiB: Double
            let closedProcessGone: Bool
            let remainingSessions: Int
        }
        var cycles: [Cycle] = []
        guard let anchor = store.state.selectedWorkspaceID else { throw LaunchError.invalid("Fixture workspace is unavailable") }
        var identities: [UUID: Int32] = [:]
        var baseline: [[String: String]] = []
        for id in ids {
            guard let binding = store.state.tab(id)?.binding,
                  let observed = try await launches.runtime.inspect(binding) else { throw LaunchError.invalid("Fixture session is unavailable") }
            identities[id] = observed.processID
            baseline.append(["id": id.uuidString, "pid": String(observed.processID), "bindingID": binding.id.uuidString])
        }
        try PrivateFiles.write(baseline, to: root.appendingPathComponent("baseline-identities.json"))
        let cycleCount = try WorkspaceBenchmarkOptions.cycleCount()
        for index in 0..<cycleCount {
            var workspaceID: UUID?, tabID: UUID?
            store.update {
                workspaceID = $0.newWorkspace(directory: root.appendingPathComponent("other").path)
                tabID = $0.selectedTab?.id
            }
            guard let workspaceID, let tabID else { throw LaunchError.invalid("Cycle draft was not created") }
            await launches.launch(tabID, tool: .shell)
            if let renderTask { await renderTask.value }
            guard let binding = store.state.tab(tabID)?.binding,
                  let observation = try await launches.runtime.inspect(binding) else { throw LaunchError.invalid("Cycle launch failed") }
            store.update { $0.selectWorkspace(workspaceID) }
            var pair: UUID?
            store.update { pair = $0.newTab() }
            guard let pair else { throw LaunchError.invalid("Cycle split draft is unavailable") }
            await launches.launch(pair, tool: .shell)
            store.update { $0.setSplit(first: tabID, second: pair) }
            if let renderTask { await renderTask.value }
            guard let pairBinding = store.state.tab(pair)?.binding,
                  let pairObservation = try await launches.runtime.inspect(pairBinding) else { throw LaunchError.invalid("Cycle split launch failed") }
            guard surfaces.count <= 3 else { throw LaunchError.invalid("Cycle surface budget exceeded") }
            try await settleRuntimeForFixture()
            try await launches.terminate(pair); surfaces.release(pair)
            store.update { $0.closeTab(pair) }
            try await settleRuntimeForFixture()
            try await launches.terminate(tabID); surfaces.release(tabID)
            store.update { $0.closeWorkspace(workspaceID); $0.selectWorkspace(anchor); $0.selectTab(ids[index % ids.count]) }
            if let renderTask { await renderTask.value }
            await files.settleForFixture()
            try await store.flush()
            var gone = false
            for _ in 0..<50 {
                let firstGone = kill(observation.processID, 0) != 0 && errno == ESRCH
                let secondGone = kill(pairObservation.processID, 0) != 0 && errno == ESRCH
                if firstGone && secondGone { gone = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let remaining = try await launches.runtime.list().count
            try await settleRuntimeForFixture()
            let diagnostics = files.diagnostics
            guard let residentMiB = WorkspaceDiagnostics.residentMiB() else { throw LaunchError.invalid("Fixture RSS could not be measured") }
            cycles.append(Cycle(index: index, warmup: index < 10, surfaces: surfaces.count,
                watchers: diagnostics["watchers"] ?? 0, previewBytes: diagnostics["previewBytes"] ?? 0,
                metadataBytes: diagnostics["metadataBytes"] ?? 0, composers: composers.count,
                fileTaskHandles: diagnostics["fileTaskHandles"] ?? 0, resizeTaskHandles: surfaces.resizeTaskCount,
                launchOperations: store.state.workspaces.flatMap(\.tabs).filter { launches.isBusy($0.id) }.count,
                rssMiB: residentMiB, closedProcessGone: gone, remainingSessions: remaining))
            try PrivateFiles.write(cycles, to: root.appendingPathComponent("continuity-cycles.json"))
            guard gone, remaining == ids.count else { throw LaunchError.invalid("Cycle retained a closed process") }
        }
        store.update { $0.selectTab(ids[0]) }
        if let renderTask { await renderTask.value }
        guard let draftView = surfaces.view(ids[0]) else { throw LaunchError.invalid("Draft surface is unavailable") }
        draftView.insertText("SPOOKKY_M4_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        let delayIndex = CommandLine.arguments.firstIndex(of: "--workspace-benchmark-output-delay")
        let outputDelay = delayIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 0
        guard outputDelay.isFinite, (0...5).contains(outputDelay) else { throw LaunchError.invalid("Invalid fixture output delay") }
        let producer = "import time; time.sleep(\(outputDelay)); i=0\nwhile True:\n print('SPOOKKY_M4_OUTPUT_'+str(i),flush=True);i+=1;time.sleep(1)"
        let spec = try LaunchSpec(tool: .shell, executable: "/usr/bin/python3", arguments: ["-u", "-c", producer], directory: root.path)
        var outputID: UUID?
        store.update { outputID = $0.newTab() }
        guard let outputID else { throw LaunchError.invalid("Output draft is unavailable") }
        store.update { $0.apply(.preparing, to: outputID); $0.apply(.intent(spec, .none), to: outputID) }
        try await store.flush()
        let outputBinding = try await launches.runtime.create(spec)
        store.update { $0.apply(.observed(outputBinding, dead: false, exitCode: nil, prompt: PromptDelivery.none), to: outputID) }
        store.update { $0.selectTab(outputID) }
        if let renderTask { await renderTask.value }
        let outputStarted = ContinuousClock.now
        var outputReady = false
        while outputStarted.duration(to: .now) < .seconds(10) {
            if surfaces.view(outputID)?.visibleText().contains("SPOOKKY_M4_OUTPUT_") == true { outputReady = true; break }
            guard try await launches.runtime.inspect(outputBinding)?.dead == false else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard outputReady else { throw LaunchError.invalid("Continuous output fixture did not become ready within ten seconds") }
        let readiness = outputStarted.duration(to: .now).components
        try PrivateFiles.write(["milliseconds": Double(readiness.seconds) * 1000 + Double(readiness.attoseconds) / 1e15,
                                "injected_delay_seconds": outputDelay], to: root.appendingPathComponent("output-ready.json"))
        let started = ContinuousClock.now
        var checkpoints: [[String: Int]] = [], tick = 0
        while started.duration(to: .now) < .seconds(seconds) {
            store.update { $0.selectTab(ids[tick % ids.count]) }
            if let renderTask { await renderTask.value }
            if tick % 4 == 0 { surfaces.release(ids[tick % ids.count]); contentKey = ""; render(); if let renderTask { await renderTask.value } }
            if tick % 3 == 0 {
                let file = root.appendingPathComponent("code/sample.swift")
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd(); try handle.write(contentsOf: Data("// SPOOKKY_M4_EDIT_\(tick)\n".utf8)); try handle.close()
                await files.settleForFixture()
            }
            store.update { $0.selectTab(outputID) }
            if let renderTask { await renderTask.value }
            var outputVisible = false
            for _ in 0..<50 {
                if surfaces.view(outputID)?.visibleText().contains("SPOOKKY_M4_OUTPUT_") == true { outputVisible = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let outputObservation = try await launches.runtime.inspect(outputBinding)
            guard outputVisible, outputObservation?.dead == false else {
                let screen = String((surfaces.view(outputID)?.visibleText() ?? "NO_SURFACE").prefix(1000))
                throw LaunchError.invalid("Continuous output fixture failed. Visible: \(outputVisible), dead: \(String(describing: outputObservation?.dead)), exit: \(String(describing: outputObservation?.exitCode)). Generated fixture screen: " + screen)
            }
            if tick % 10 == 0 {
                window.performClose(nil)
                for _ in 0..<100 {
                    if surfaces.count == 0 { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard surfaces.count == 0 else { throw LaunchError.invalid("Window close retained terminal surfaces") }
                reopen()
            }
            store.update { $0.selectTab(ids[0]) }
            if let renderTask { await renderTask.value }
            var preserved = false
            for _ in 0..<50 {
                // The native text projection includes soft-wrap newlines. Confirm the owner's joined lines too.
                let visible = surfaces.view(ids[0])?.visibleText().replacingOccurrences(of: "\n", with: "") ?? ""
                if visible.contains("SPOOKKY_M4_UNSENT"), let binding = store.state.tab(ids[0])?.binding,
                   try await launches.runtime.inspect(binding) != nil {
                    let owner = try await ProcessRunner.asyncRun(PackagedRuntime.tmux(),
                        ["-S", root.appendingPathComponent("socket").path, "capture-pane", "-p", "-J", "-t", "=" + binding.name + ":0.0"], outputLimit: 8192)
                    if owner.status == 0 && owner.output.contains("SPOOKKY_M4_UNSENT") { preserved = true; break }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard preserved else {
                try PrivateFiles.write(["visible": surfaces.view(ids[0])?.visibleText() ?? "NO_SURFACE"], to: root.appendingPathComponent("draft-failure.json"))
                throw LaunchError.invalid("Unsent fixture input was lost")
            }
            for id in ids {
                guard let binding = store.state.tab(id)?.binding,
                      try await launches.runtime.inspect(binding)?.processID == identities[id] else { throw LaunchError.invalid("Continuity process identity changed") }
            }
            checkpoints.append(files.diagnostics.merging(["tick": tick, "elapsedSeconds": Int(started.duration(to: .now).components.seconds), "surfaces": surfaces.count,
                "windowKey": window.isKeyWindow ? 1 : 0, "windowMain": window.isMainWindow ? 1 : 0,
                "resizeTaskHandles": surfaces.resizeTaskCount, "reconciliationTaskHandles": observationTask == nil ? 0 : 1,
                "renderTaskHandles": renderTask == nil ? 0 : 1], uniquingKeysWith: { _, new in new }))
            try PrivateFiles.write(checkpoints, to: root.appendingPathComponent("continuity-checkpoints.json"))
            guard surfaces.count <= 3 else { throw LaunchError.invalid("Continuity surface budget exceeded") }
            guard !backgroundFixture || (!window.isKeyWindow && !window.isMainWindow) else {
                throw LaunchError.invalid("Background fixture took native window focus.")
            }
            tick += 1
            try await Task.sleep(for: .seconds(min(15, seconds)))
        }
        try await settleRuntimeForFixture()
        try await launches.terminate(outputID); surfaces.release(outputID)
        store.update { $0.closeTab(outputID); $0.selectTab(ids[0]) }
        if let renderTask { await renderTask.value }
        try await store.flush()
        try PrivateFiles.write(["same_processes": 1, "draft_preserved": 1, "cycles": cycles.count,
            "checkpoints": checkpoints.count, "elapsedSeconds": Int(started.duration(to: .now).components.seconds)] as [String: Int], to: root.appendingPathComponent("continuity-result.json"))
    }
    private func settleRuntimeForFixture() async throws {
        for _ in 0..<100 {
            if observationTask == nil && !store.state.workspaces.flatMap(\.tabs).contains(where: { launches.isBusy($0.id) }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw LaunchError.invalid("Fixture runtime reconciliation did not settle within two seconds.")
    }

    private func renderConversationSidebar(_ state: WorkspaceState, collapsed: Bool) {
        let structure = String(collapsed) + String(describing: window.effectiveAppearance.name)
        if collapsed {
            if sidebarRevision != structure { sidebarRevision = structure; clear(rail) }
            conversationSidebar.update(items: [], collapsed: true)
            return
        }
        if sidebarRevision != structure {
            sidebarRevision = structure; clear(rail)
            let outerInset: CGFloat = 0
            rail.edgeInsets = NSEdgeInsets(top: SpookkyStyle.points(8), left: outerInset, bottom: SpookkyStyle.points(12), right: outerInset)
            let create = ActionButton("New chat", symbol: "plus", help: "New chat · ⌘N") { [weak self] in self?.newWorkspace() }
            create.contentTintColor = SidebarPalette.text
            create.alignment = .left
            create.heightAnchor.constraint(equalToConstant: 32).displayScaled().isActive = true
            rail.addArrangedSubview(create)
            rail.addArrangedSubview(historySearch); historySearch.heightAnchor.constraint(equalToConstant: 28).displayScaled().isActive = true
            rail.addArrangedSubview(conversationSidebar)
            conversationSidebar.setContentHuggingPriority(.defaultLow, for: .vertical)
            for view in rail.arrangedSubviews { view.widthAnchor.constraint(equalTo: rail.widthAnchor, constant: -2 * outerInset).displayScaled(alreadyScaled: true).isActive = true }
            conversationSidebar.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).displayScaled().isActive = true
            conversationSidebar.onActivate = { [weak self] in self?.activateSidebarItem($0) }
            conversationSidebar.onAddProject = { [weak self] in self?.addProjectMenu(anchor: $0) }
            conversationSidebar.onAddProjectSession = { [weak self] value in
                if let id = UUID(uuidString: value.replacingOccurrences(of: "project:", with: "")) { self?.newProjectWorkspace(id) }
            }
            conversationSidebar.onMore = { [weak self] value in self?.showMoreHistory(String(value.dropFirst(5))) }
            conversationSidebar.onContextMenu = { [weak self] in self?.sidebarContextMenu($0) }
            conversationSidebar.onThreadAction = { [weak self] id, action in
                guard let menu = self?.sidebarContextMenu(id), let item = menu.items.first(where: {
                    (action == "pin" ? ["Pin", "Unpin"] : ["Archive", "Unarchive"]).contains($0.title)
                }), let selector = item.action else { return }
                NSApp.sendAction(selector, to: item.target, from: item)
            }
            conversationSidebar.onVisibleItems = { [weak self] items in
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
        let search = historySearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
            var rows: [(id: String, date: Date, record: ConversationCatalogRecord?, workspace: Workspace?)] = []
            for originalRecord in records + supplemental + moved {
                var record = originalRecord
                let presentation = state.presentation(for: record.id.threadKey)
                if presentation.hasProjectOverride { record.projectID = presentation.projectOverride }
                guard presentation.archivedAt == nil else { continue }
                let workspace = workspaceByKey[record.id.threadKey]
                if key != "search", (workspace?.projectID ?? record.projectID) != projectID { continue }
                if !search.isEmpty, ![workspace?.displayTitle ?? record.displayTitle, record.metadata.directory, record.id.sessionID].contains(where: { $0.localizedCaseInsensitiveContains(search) }) { continue }
                guard seen.insert(record.id).inserted else { continue }
                rows.append(("conversation:" + record.id.threadKey, record.metadata.updatedAt, record, workspace))
            }
            for workspace in state.workspaces where !workspace.isLanding && workspace.projectID == projectID && workspace.conversationID == nil && !state.isArchived(workspace) &&
                (search.isEmpty || workspace.displayTitle.localizedCaseInsensitiveContains(search)) {
                rows.append((workspace.threadKey, workspace.lastViewedAt ?? .distantPast, nil, workspace))
            }
            rows.sort { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
            let limit = historyPageLimits[key] ?? (key == "search" ? 10 : 5)
            var visible = Array(rows.prefix(limit))
            if let selected = rows.first(where: { $0.workspace?.id == state.selectedWorkspaceID }), !visible.contains(where: { $0.id == selected.id }) { visible.append(selected) }
            for row in visible {
                let record = row.record, workspace = row.workspace, activity = workspace?.activityState
                if let record { sidebarRecords[row.id] = record }
                guard let title = workspace?.displayTitle ?? record?.displayTitle else { continue }
                let heading = record.map { $0.displayTitle + " · " + $0.id.provider.displayName } ?? title
                items.append(WorkspaceSidebarItem(id: row.id, kind: .conversation, title: title,
                    image: SpookkyStyle.toolImage(record?.id.provider ?? workspace?.displayProvider ?? .shell),
                    help: ([heading, record?.metadata.directory ?? workspace?.directory, workspace?.currentProjectAssociation?.message, activity?.label].compactMap { $0 }).joined(separator: "\n"),
                    selected: workspace?.id == state.selectedWorkspaceID && (selectedSidebarOccurrence == nil || selectedSidebarOccurrence == row.id),
                    nested: projectID != nil, activity: activity))
            }
            if rows.count > limit || historyHasMore.contains(key) || historyIssues[key] != nil {
                items.append(WorkspaceSidebarItem(id: "more:" + key, kind: .more,
                    title: historyIssues[key] == nil ? "Show more" : "Retry history", help: historyIssues[key] ?? "Show ten more conversations", nested: projectID != nil))
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
            append(historyRecords["search"] ?? [], projectID: nil, key: "search")
        } else {
            localSection("Pinned", key: "pinned", filter: { $0.pinnedAt != nil && $0.archivedAt == nil })
            items.append(WorkspaceSidebarItem(id: "section:projects", kind: .section, title: "Projects"))
            for project in state.projects {
                items.append(WorkspaceSidebarItem(id: "project:" + project.id.uuidString, kind: .project, title: project.name,
                    image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil), help: project.name + "\n" + project.location.path,
                    collapsed: project.isCollapsed == true))
                if project.isCollapsed != true { append(historyRecords[project.id.uuidString] ?? [], projectID: project.id, key: project.id.uuidString) }
            }
            let unbound = historyRecords["unbound"] ?? []
            if !unbound.isEmpty || historyHasMore.contains("unbound") || historyIssues["unbound"] != nil || state.openWorkspaces.contains(where: { $0.projectID == nil }) {
                items.append(WorkspaceSidebarItem(id: "section:unbound", kind: .section, title: "No project"))
                append(unbound, projectID: nil, key: "unbound")
            }
        }
        if !showingArchived && search.isEmpty { localSection("Recents", key: "recents", filter: { $0.lastVisitedAt != nil && $0.archivedAt == nil }) }
        for index in items.indices where items[index].kind == .conversation {
            guard let key = sidebarThreadKey(items[index].id) else { continue }
            let record = sidebarRecords[items[index].id]
            let workspace = workspaceByKey[key]
            let presentation = state.presentation(for: key)
            items[index].pinned = presentation.pinnedAt != nil; items[index].archived = presentation.archivedAt != nil
            items[index].provider = workspace?.displayProvider ?? record?.id.provider
            items[index].updatedAt = workspace?.primaryTerminal?.activity.flatMap { $0.lastEventAt > 0 ? Date(timeIntervalSince1970: $0.lastEventAt) : nil } ?? record?.metadata.updatedAt
            let projectID = workspace?.projectID ?? record?.projectID
            items[index].projectName = state.projects.first { $0.id == projectID }?.name
            items[index].checkout = sidebarGit[key]?.checkout; items[index].pullRequest = sidebarGit[key]?.pr
            items[index].help += "\n" + [items[index].provider?.displayName, items[index].pullRequest?.label,
                items[index].checkout?.linkedWorktree == true ? "Linked worktree" : nil, items[index].checkout?.branch].compactMap { $0 }.joined(separator: " · ")
        }
        conversationSidebar.update(items: items, collapsed: false)
    }
    private func sidebarThreadKey(_ id: String) -> String? {
        if let record = sidebarRecords[id] { return record.id.threadKey }
        if let workspaceID = sidebarWorkspaceIDs[id] { return store.state.workspaces.first { $0.id == workspaceID }?.threadKey }
        return store.state.workspaces.first { $0.threadKey == id }?.threadKey
    }
    private func refreshSidebarGit() {
        guard let window, NSApp.isActive, window.isVisible, window.occlusionState.contains(.visible), !store.state.sidebarCollapsed else {
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
            let workspace = store.state.workspaces.first { $0.threadKey == key && $0.primaryTerminal?.binding != nil && $0.primaryTerminal?.status == .running }
            let association = store.state.presentation(for: key).pullRequest
            guard workspace != nil || association != nil else { return nil }
            return Job(key: key, workspaceID: workspace?.id, bindingID: workspace?.primaryTerminal?.binding?.id,
                directory: workspace?.directory, association: association)
        }
        guard !jobs.isEmpty else { return }
        let generation = UUID(); sidebarGitGeneration = generation
        let service = sidebarPRService
        sidebarGitTask = Task { [weak self] in
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
                    guard !Task.isCancelled, let self, self.sidebarGitGeneration == generation,
                          self.sidebarVisibleItems.contains(where: { self.sidebarThreadKey($0.id) == job.key }),
                          self.window.isVisible, NSApp.isActive else { continue }
                    if let id = job.workspaceID {
                        guard let workspace = self.store.state.workspaces.first(where: { $0.id == id }),
                              workspace.threadKey == job.key, workspace.primaryTerminal?.binding?.id == job.bindingID,
                              workspace.directory == job.directory else { continue }
                    }
                    self.sidebarGit[job.key] = (checkout, pr, Date())
                    if let association = pr?.association, self.store.state.presentation(for: job.key).pullRequest != association {
                        self.store.update(debounced: true) { $0.editThread(job.key) { $0.pullRequest = association } }
                    } else if invalidAssociation {
                        self.store.update(debounced: true) { $0.editThread(job.key) { $0.pullRequest = nil } }
                    }
                    while self.sidebarGit.count > 128, let oldest = self.sidebarGit.min(by: { $0.value.date < $1.value.date })?.key { self.sidebarGit[oldest] = nil }
                    self.chromeRevision = ""; self.renderChrome()
                }
            }
            if let self, self.sidebarGitGeneration == generation { self.sidebarGitTask = nil; self.refreshSidebarGit() }
        }
    }
    private func activateSidebarItem(_ value: String) {
        if !value.hasPrefix("project:") && !value.hasPrefix("more:") { selectedSidebarOccurrence = value }
        if value.hasPrefix("project:"), let id = UUID(uuidString: String(value.dropFirst(8))) {
            if store.state.projects.first(where: { $0.id == id })?.isCollapsed != true {
                let key = id.uuidString, records = historyRecords[id.uuidString] ?? []
                historyPageLimits[key] = 5
                historyRecords[key] = Array(records.prefix(5))
                historyCursors[key] = nil
                if records.count > 5 { historyHasMore.insert(key) }
            }
            store.update { $0.toggleProjectCollapsed(id) }
            requestCatalogRefresh(force: true)
        } else if value.hasPrefix("more:") { showMoreHistory(String(value.dropFirst(5))) }
        else if let id = sidebarWorkspaceIDs[value] { openConversationWorkspace(id) }
        else if let record = sidebarRecords[value] { openHistoryRecord(record) }
        else if value.hasPrefix("workspace:"), let id = UUID(uuidString: String(value.dropFirst(10))) { openConversationWorkspace(id) }
    }
    private func sidebarContextMenu(_ value: String) -> NSMenu? {
        if value.hasPrefix("project:"), let id = UUID(uuidString: String(value.dropFirst(8))) {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("New chat") { [weak self] in self?.newProjectWorkspace(id) })
            menu.addItem(ClosureMenuItem("Refresh conversations") { [weak self] in self?.requestCatalogRefresh(force: true) })
            menu.addItem(ClosureMenuItem("Remove project") { [weak self] in
                guard let self else { return }
                store.update { $0.removeProject(id) }
                Task {
                    do { try await self.historyCatalog.removeProject(id); self.requestCatalogRefresh(force: true) }
                    catch { self.historyIssues["unbound"] = error.localizedDescription; self.chromeRevision = ""; self.render() }
                }
            })
            return menu
        }
        if let id = sidebarWorkspaceIDs[value] { return workspaceContextMenu(id) }
        if let record = sidebarRecords[value] {
            if let workspace = store.state.workspace(for: record.id) { return workspaceContextMenu(workspace.id) }
            let menu = NSMenu()
            addThreadActions(menu, key: record.id.threadKey, record: record)
            menu.addItem(ClosureMenuItem("Go to conversation") { [weak self] in self?.openHistoryRecord(record) })
            menu.addItem(ClosureMenuItem("Rename in Spookky…") { [weak self] in self?.renameHistoryRecord(record) })
            return menu
        }
        if value.hasPrefix("workspace:"), let id = UUID(uuidString: String(value.dropFirst(10))) { return workspaceContextMenu(id) }
        return nil
    }
    private func workspaceContextMenu(_ id: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Rename…") { [weak self] in self?.rename(workspaceID: id) })
        if let workspace = store.state.workspaces.first(where: { $0.id == id }) {
            addThreadActions(menu, key: workspace.threadKey)
            let unread = workspace.primaryTerminal?.activity?.unread == true
            menu.addItem(ClosureMenuItem(unread ? "Mark read" : "Mark unread") { [weak self] in self?.changeAgentAttention( workspace.tabs.map(\.id), action: unread ? "read" : "unread") })
            menu.addItem(.separator()); addContinuationAction(menu, workspaceID: id)
            if workspace.primaryTerminal?.binding != nil && workspace.displayProvider != .shell {
                menu.addItem(ClosureMenuItem("Stop primary terminal…") { [weak self] in self?.stopPrimaryAgent(id) })
            }
        }
        return menu
    }
    private func renameHistoryRecord(_ record: ConversationCatalogRecord) {
        presentThreadName(record.displayTitle) { [weak self] name in
            guard let self else { return }
            Task {
                do {
                    try await self.historyCatalog.rename(record.id, alias: name)
                    if let updated = try await self.historyCatalog.record(record.id) { self.store.update { $0.rememberThread(updated) } }
                    self.requestCatalogRefresh(force: true)
                } catch { self.alert("Could not rename thread", error.localizedDescription) }
            }
        }
    }

    private func presentThreadName(_ current: String, save: @escaping (String) -> Void) {
        guard window.attachedSheet == nil else { return }
        let panel = ChromeAlert(); panel.messageText = "Rename in Spookky"
        let field = ChromeTextField(string: current); field.frame = NSRect(x: 0, y: 0, width: SpookkyStyle.points(320), height: SpookkyStyle.controlHeight)
        field.setAccessibilityLabel("Thread name")
        panel.accessoryView = field; panel.window.initialFirstResponder = field
        panel.addButton(withTitle: "Save"); panel.addButton(withTitle: "Cancel")
        panel.beginSheetModal(for: window) { result in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if result == .alertFirstButtonReturn, !name.isEmpty { save(name) }
        }
    }
    private func recordNavigation() {
        guard let id = store.state.selectedWorkspaceID else { return }
        if let occurrence = selectedSidebarOccurrence,
           sidebarRecords[occurrence]?.id != store.state.selected?.conversationID && sidebarWorkspaceIDs[occurrence] != id {
            selectedSidebarOccurrence = nil
        }
        if !navigating, navigationIndex < 0 || navigation.indices.contains(navigationIndex) && navigation[navigationIndex] != id {
            navigation = Array(navigation.prefix(navigationIndex + 1)); navigation.append(id)
            if navigation.count > 64 { navigation.removeFirst(navigation.count - 64) }
            navigationIndex = navigation.count - 1
        }
        navigationBack.isEnabled = navigationIndex > 0
        navigationForward.isEnabled = navigationIndex + 1 < navigation.count
    }
    private func navigateThread(_ offset: Int) {
        let next = navigationIndex + offset
        guard navigation.indices.contains(next) else { return }
        navigating = true; navigationIndex = next; selectedSidebarOccurrence = nil
        openConversationWorkspace(navigation[next]); navigating = false; recordNavigation()
    }
    private func selectDisplayTab(_ index: Int) {
        guard let workspace = store.state.selected else { return }
        if index == 0 { focusSelectedContent() }
        else if let tabs = workspace.support?.tabs, tabs.indices.contains(index - 1) { store.update { $0.selectSupport(tabs[index - 1].id) }; focusSupportingContent() }
    }
    private func addThreadActions(_ menu: NSMenu, key: String, record: ConversationCatalogRecord? = nil) {
        let presentation = store.state.presentation(for: key)
        if let association = sidebarGit[key]?.pr?.association ?? presentation.pullRequest, association.isValid {
            menu.addItem(ClosureMenuItem("Open PR #" + String(association.number)) { NSWorkspace.shared.open(association.url) })
        }
        menu.addItem(ClosureMenuItem(presentation.pinnedAt == nil ? "Pin" : "Unpin") { [weak self] in
            self?.store.update { if let record { $0.rememberThread(record) }; $0.editThread(key) { $0.pinnedAt = presentation.pinnedAt == nil ? Date() : nil } }
            self?.chromeRevision = ""; self?.render()
        })
        let move = NSMenuItem(title: "Move to project", action: nil, keyEquivalent: ""), projects = NSMenu()
        for (id, name) in [(nil as UUID?, "No project")] + store.state.projects.map({ (Optional($0.id), $0.name) }) {
            projects.addItem(ClosureMenuItem(name) { [weak self] in
                self?.store.update { if let record { $0.rememberThread(record) }; $0.editThread(key) { $0.hasProjectOverride = true; $0.projectOverride = id } }
                self?.requestCatalogRefresh(force: true)
            })
        }
        move.submenu = projects; menu.addItem(move)
        menu.addItem(ClosureMenuItem(presentation.archivedAt == nil ? "Archive" : "Unarchive") { [weak self] in
            guard let self else { return }
            if presentation.archivedAt == nil && store.state.selected?.threadKey == key { cancelLaunchPreflight() }
            store.update { if let record { $0.rememberThread(record) }; $0.editThread(key) { $0.archivedAt = presentation.archivedAt == nil ? Date() : nil } }
            chromeRevision = ""; render(); requestCatalogRefresh(force: false)
        })
    }
    private func openSupportingTool(_ tool: SupportingTool, replacing tabID: UUID) {
        switch tool {
        case .files: chooseSupportingFile(replacing: tabID)
        case .changes: store.update { $0.updateSupport(tabID, target: .changes, title: "Changes") }
        case .terminal: store.update { $0.closeSupport(tabID); $0.newTab() }; if let id = store.state.selectedTab?.id { launch(id, tool: .shell) }
        case .artifact: BrowserArtifactContentHost.chooseArtifact(in: window) { [weak self] path in
            self?.store.update { $0.updateSupport(tabID, target: .artifact(path: path), title: (path as NSString).lastPathComponent) }
        }
        }
        focusSupportingContent()
    }
    private func showThreadDetails() {
        guard let workspace = store.state.selected else { return }
        let popover = NSPopover(), controller = NSViewController(); detailsPopover = popover
        let title = SpookkyStyle.label(workspace.displayTitle); title.font = .boldSystemFont(ofSize: SpookkyStyle.points(13))
        let provider = SpookkyStyle.label(workspace.displayProvider.displayName)
        let folder = ChromeTextField(wrappingLabelWithString: workspace.directory); folder.isSelectable = true; folder.textColor = SpookkyPalette.secondary
        let review = ActionButton("Changes", symbol: "arrow.triangle.branch") { [weak self] in self?.store.update { $0.openSupport(.changes, title: "Changes") }; self?.detailsPopover?.performClose(nil) }
        var views: [NSView] = [title, provider, folder]
        if let activity = workspace.activityState { views.append(SpookkyStyle.label(activity.label)) }
        if workspace.displayProvider != .shell && workspace.primaryTerminal?.activity?.displayState == .unknown {
            let help = ChromeTextField(wrappingLabelWithString: "Activity monitoring is unavailable. The provider’s Review action shows Spookky’s local callback definitions before you trust them. They report activity and optional previews to this Mac. Declining keeps the terminal usable, but Working and Needs input cannot be reported.")
            help.font = .systemFont(ofSize: SpookkyStyle.points(11)); help.textColor = SpookkyPalette.secondary
            views.append(help)
        }
        if let primary = workspace.primaryTerminal, primary.binding != nil {
            views.append(ActionButton("Reconnect terminal", symbol: "arrow.clockwise") { [weak self] in
                self?.reconnect(primary.id); self?.detailsPopover?.performClose(nil)
            })
        }
        views.append(review)
        if let branch = (workspace.anchor ?? workspace.selectedLocation).branch { views.append(SpookkyStyle.label("Branch: " + branch)) }
        for warning in providerHistoryNotices.sorted() {
            let field = ChromeTextField(wrappingLabelWithString: warning); field.font = .systemFont(ofSize: SpookkyStyle.points(11)); field.textColor = SpookkyPalette.secondary; views.append(field)
        }
        for tab in workspace.support?.tabs ?? [] {
            if case .artifact = tab.target { views.append(ActionButton(tab.displayTitle, symbol: "doc.richtext") { [weak self] in self?.store.update { $0.selectSupport(tab.id) }; self?.detailsPopover?.performClose(nil) }) }
        }
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = SpookkyStyle.points(12)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.widthAnchor.constraint(equalToConstant: 320).displayScaled().isActive = true
        controller.view = stack; popover.contentViewController = controller; popover.behavior = .transient
        popover.show(relativeTo: threadDetails.bounds, of: threadDetails, preferredEdge: .minY)
    }

}
