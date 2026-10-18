import AppKit
import Darwin
import SpookkyCore
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
    private let avatarCache: GitHubAvatarCache
    private var avatarTasks: [UUID: Task<Void, Never>] = [:]
    private var projectOwners: [String: String] = [:]
    private let sessionCatalog: any SessionCatalogReading
    private let associationResolver = ProjectAssociationResolver()
    var historyRefreshTask: Task<Void, Never>?
    private var historyGeneration = UUID()
    private var historyProjectSignature = ""
    private var historyActivationObserver: NSObjectProtocol?
    private var historyNotice: String?
    private var historyRefreshedAt: Date?
    private let savedConversationResolver: any ExecutableResolver
    private var continuingConversations = Set<ConversationID>()
    let historySearch = NSSearchField()
    private let unboundHistoryLabel = NSTextField(labelWithString: "No project")
    let historyMore = ActionButton("Show more conversations", action: {})
    var historyLimit = 50
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
    private let filesToggle = ActionButton("Panel", symbol: "sidebar.right", help: "Show supporting panel · ⌘L", action: {})
    private let sidebarToggle = ActionButton("", symbol: "sidebar.left", help: "Collapse workspace sidebar · ⌘B", action: {})
    private let tabOverflow = ActionButton("", symbol: "chevron.down", help: "All tabs", action: {})
    private let header = WorkspaceHeaderView()
    private var toggleLeading: NSLayoutConstraint!
    private var tabsLeading: NSLayoutConstraint!
    private var tabsWidth: NSLayoutConstraint!
    private var supportHeaderLeading: NSLayoutConstraint!
    private var codeWidth: NSLayoutConstraint!
    private var overflowWidth: NSLayoutConstraint!
    private var updatingHeader = false
    private weak var projectAddButton: ActionButton?
    private let cancelLocation = ActionButton("Cancel operation", action: {})
    private let warning = NSTextField(labelWithString: "")
    private let railScroll = NSScrollView()
    private let tabScroll = TabStripScrollView()
    private var railWidth: NSLayoutConstraint!
    private var composers: [UUID: LaunchComposerView] = [:]
    private var contentKey = ""
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
    var workspaceRows: [UUID: ContextRow] = [:]
    var projectRows: [UUID: ContextRow] = [:]
    private var tabPairs: [UUID: ChromeStackView] = [:]
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
    private var agentPreferencesTask: Task<Void, Never>?
    private let backgroundFixture: Bool
    private var fixtureCloseRequests: [[String: String]] = []

    init(root: URL, initialStore: WorkspaceStore? = nil,
         resolver: any ExecutableResolver = CLIResolver(), backgroundFixture: Bool = false,
         catalog: (any SessionCatalogReading)? = nil) throws {
        let paths = AppPaths(bundleID: Bundle.main.bundleIdentifier, home: FileManager.default.homeDirectoryForCurrentUser, userID: getuid())
        avatarCache = GitHubAvatarCache(directory: paths.data.appendingPathComponent("AvatarCache"))
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
        if CommandLine.arguments.contains("--workspace-benchmark-races"), CommandLine.arguments.contains("--workspace-benchmark-count"),
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
        buildWindow(); buildMenu()
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
        agentNotifications.watchFocus { [weak self] in self?.refreshAgentAttention(clearManual: true); self?.updateAgentAnimations() }
        services.prepareForUpdate = { [weak self] in
            guard let self else { throw LaunchError.invalid("Workspaces are unavailable.") }
            try await self.prepareForUpdate()
        }
        diagnostics?.visibility = { [weak self] in self?.window.occlusionState.contains(.visible) == true }
        historyProjectSignature = catalogProjectSignature()
        historySearch.placeholderString = "Search conversations"; historySearch.delegate = self
        historySearch.sendsSearchStringImmediately = true
        historySearch.setAccessibilityLabel("Search all saved conversations")
        historySearch.widthAnchor.constraint(equalToConstant: SpookkyStyle.sidebarWidth - 16).isActive = true
        historyMore.handler = { [weak self] in
            guard let self else { return }; historyLimit += 50; chromeRevision = ""; render()
        }
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
        surfaces.onViewportFailure = { [weak self] id, error in
            guard let self, self.store.state.tab(id)?.binding != nil else { return }
            self.store.update { $0.apply(.failure(.unavailable, TabFailure(.observation, error.localizedDescription), clearIntent: false), to: id) }
        }
        if store.state.workspaces.isEmpty {
            store.update { $0.newWorkspace(directory: FileManager.default.homeDirectoryForCurrentUser.path) }
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
        historyActivationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestCatalogRefresh(force: false) }
        }
        runtimeEvents.onChange = { [weak self] in self?.observeRuntimeEvent() }
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    for row in Array(self.workspaceRows.values) + Array(self.projectRows.values) { row.primary?.needsDisplay = true }
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
        let seen = store.state.visibleTabIDs.filter { id in
            guard agentTargetVisible(id), let activity = store.state.tab(id)?.activity else { return false }
            return (activity.completionID != nil && activity.completionID != activity.seenCompletionID) || (clearManual && activity.manualUnread)
        }
        if !seen.isEmpty {
            store.update(debounced: true) { state in for id in seen { state.acknowledgeAgent(id) } }
            for id in seen { agentNotifications.clear(id) }
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
    private func updateAgentAnimations() {
        for workspace in store.state.workspaces {
            if let badge = workspaceRows[workspace.id]?.statusBadge {
                let lifecycle = workspace.primaryTerminal.map { [.failed, .uncertain, .unavailable, .launching, .preparing, .reconnecting].contains($0.status) } ?? false
                AgentIndicator.animate(badge, working: workspace.activityState == .working && !lifecycle)
            }
        }
        for (id, pair) in tabPairs {
            if let icon = pair.arrangedSubviews[1] as? NSImageView {
                AgentIndicator.animate(icon, working: store.state.tab(id)?.activity?.displayState == .working && store.state.tab(id)?.status == .running)
            }
        }
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
                let alert = NSAlert()
                alert.messageText = "Continue " + target.provider.displayName + " elsewhere"
                alert.informativeText = presentation.capabilities.version + ". Commands target the primary conversation."
                let instructions = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 280))
                instructions.isEditable = false; instructions.isSelectable = true; instructions.isRichText = false
                instructions.isVerticallyResizable = true; instructions.isHorizontallyResizable = false
                instructions.minSize = NSSize(width: 0, height: 280)
                instructions.maxSize = NSSize(width: 480, height: CGFloat.greatestFiniteMagnitude)
                instructions.font = .systemFont(ofSize: 13)
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
        historyRefreshTask?.cancel()
        if let historyActivationObserver { NotificationCenter.default.removeObserver(historyActivationObserver) }
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
        (window as? WorkspaceNativeWindow)?.onCommand = { [weak self] in self?.handleCommand($0) ?? false }
        let rootView = WorkspaceRootView(); window.contentView = rootView
        rootView.onAppearance = { [weak self] in self?.render() }
        rootView.onLayout = { [weak self] in self?.updateHeaderGeometry() }
        window.isMovableByWindowBackground = false
        let content = window.contentView!
        let workspaceBody = workspaceLayout
        files.layout.supportingOnly = true
        workspaceLayout.onSelect = { [weak self] id in self?.store.update { $0.selectSupport(id) }; self?.focusSupportingContent() }
        workspaceLayout.onClose = { [weak self] id in self?.store.update { $0.closeSupport(id) }; self?.focusSupportingContent() }
        workspaceLayout.onAdd = { [weak self] anchor in self?.supportMenu(anchor) }
        workspaceLayout.onLayout = { [weak self] layout, fraction in
            guard let self else { return }
            store.update(debounced: fraction != nil) { $0.setSupportingLayout(layout, fraction: fraction) }
            if layout == .fullWidth { focusSupportingContent() }
        }
        workspaceLayout.onGeometryChange = { [weak self] in self?.updateHeaderGeometry() }

        filesToggle.handler = { [weak self] in self?.toggleCodeSidebar() }
        sidebarToggle.handler = { [weak self] in self?.toggleWorkspaceSidebar() }
        tabOverflow.handler = { [weak self] in self?.showTabOverflow() }
        rail.orientation = .vertical; rail.alignment = .leading; rail.spacing = 4
        rail.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 12, right: 8)
        railScroll.documentView = rail; railScroll.hasVerticalScroller = true; railScroll.autohidesScrollers = true
        railScroll.drawsBackground = true; railScroll.backgroundColor = SpookkyPalette.sidebar
        tabs.orientation = .horizontal; tabs.spacing = 0; tabs.alignment = .centerY
        tabs.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        tabScroll.documentView = tabs; tabScroll.hasHorizontalScroller = true; tabScroll.autohidesScrollers = true; tabScroll.drawsBackground = false
        tabScroll.automaticallyAdjustsContentInsets = false
        tabScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tabScroll.scrollerStyle = .overlay
        warning.font = .systemFont(ofSize: 11); warning.textColor = SpookkyPalette.warning
        warning.isHidden = true
        cancelLocation.isHidden = true
        cancelLocation.handler = { [weak self] in guard let self else { return }; locations.activeOperationIDs.forEach { self.locations.cancel($0) } }
        for view in [header, railScroll, tabScroll, workspaceLayout.headerView, workspaceBody, sidebarToggle, tabOverflow, filesToggle, warning, cancelLocation] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        rail.translatesAutoresizingMaskIntoConstraints = false; tabs.translatesAutoresizingMaskIntoConstraints = false
        railWidth = railScroll.widthAnchor.constraint(equalToConstant: SpookkyStyle.sidebarWidth)
        toggleLeading = sidebarToggle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 196)
        tabsLeading = tabScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SpookkyStyle.sidebarWidth)
        tabsWidth = tabScroll.widthAnchor.constraint(equalToConstant: 220)
        supportHeaderLeading = workspaceLayout.headerView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SpookkyStyle.sidebarWidth + 220)
        codeWidth = filesToggle.widthAnchor.constraint(equalToConstant: 64)
        overflowWidth = tabOverflow.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor), header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor), header.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight),
            railScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), railScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            railScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor), railWidth,
            rail.widthAnchor.constraint(equalTo: railScroll.widthAnchor), rail.heightAnchor.constraint(greaterThanOrEqualTo: railScroll.heightAnchor),
            tabsLeading, tabsWidth, supportHeaderLeading,
            workspaceLayout.headerView.trailingAnchor.constraint(equalTo: tabOverflow.leadingAnchor, constant: -4),
            workspaceLayout.headerView.topAnchor.constraint(equalTo: content.topAnchor),
            workspaceLayout.headerView.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight),
            tabScroll.topAnchor.constraint(equalTo: content.topAnchor), tabScroll.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight),
            tabs.heightAnchor.constraint(equalTo: tabScroll.heightAnchor),
            filesToggle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            filesToggle.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            codeWidth, filesToggle.heightAnchor.constraint(equalToConstant: 28),
            toggleLeading, sidebarToggle.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            sidebarToggle.widthAnchor.constraint(equalToConstant: 28), sidebarToggle.heightAnchor.constraint(equalToConstant: 28),
            tabOverflow.trailingAnchor.constraint(equalTo: filesToggle.leadingAnchor, constant: -4), overflowWidth,
            tabOverflow.topAnchor.constraint(equalTo: content.topAnchor, constant: 6), tabOverflow.heightAnchor.constraint(equalToConstant: 28),
            workspaceBody.leadingAnchor.constraint(equalTo: railScroll.trailingAnchor), workspaceBody.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            workspaceBody.topAnchor.constraint(equalTo: tabScroll.bottomAnchor), workspaceBody.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            warning.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 12),
            warning.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -8),
            warning.trailingAnchor.constraint(lessThanOrEqualTo: cancelLocation.leadingAnchor, constant: -8),
            cancelLocation.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -12),
            cancelLocation.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -4)
        ])
    }
    private func updateHeaderGeometry() {
        guard !updatingHeader, let content = window?.contentView, toggleLeading != nil else { return }
        updatingHeader = true; defer { updatingHeader = false }
        let collapsed = store.state.sidebarCollapsed
        let width = collapsed ? SpookkyStyle.railWidth : SpookkyStyle.sidebarWidth
        if header.sidebarWidth != width { header.sidebarWidth = width }
        let occupied = window.styleMask.contains(.fullScreen) ? 0 : [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            .filter { !$0.isHidden }.map { content.convert($0.bounds, from: $0).maxX }.max() ?? 0
        let leading = collapsed ? max((width - 28) / 2, occupied + 8) : max(width - 36, occupied + 8)
        if toggleLeading.constant != leading { toggleLeading.constant = leading }
        let tabStart = max(width, leading + 36)
        if tabsLeading.constant != tabStart { tabsLeading.constant = tabStart }
        let labeled = content.bounds.width >= 900
        let codeTitle = labeled ? "Panel" : ""
        if filesToggle.title != codeTitle { filesToggle.title = codeTitle }
        let codeTarget: CGFloat = labeled ? 76 : 28
        if codeWidth.constant != codeTarget { codeWidth.constant = codeTarget }
        filesToggle.selected = workspaceLayout.showsSupportingContent && store.state.selected != nil
        filesToggle.setAccessibilityValue(filesToggle.selected ? "Selected" : nil)
        filesToggle.toolTip = (filesToggle.selected ? "Hide" : "Show") + " supporting panel · ⌘L"
        filesToggle.setAccessibilityLabel(filesToggle.toolTip!)
        sidebarToggle.toolTip = (collapsed ? "Expand" : "Collapse") + " workspace sidebar · ⌘B"
        sidebarToggle.setAccessibilityLabel(sidebarToggle.toolTip!)
        sidebarToggle.setAccessibilityValue(collapsed ? "Collapsed" : "Expanded")
        let available = max(0, content.bounds.width - tabStart - codeTarget - 24)
        let splitStart = width + workspaceLayout.primaryPaneWidth + 5
        let mainWidth = workspaceLayout.isSplit ? max(0, splitStart - tabStart - 5) : min(tabs.fittingSize.width, available * 0.45)
        let supportStart = workspaceLayout.isSplit ? splitStart : tabStart + mainWidth
        let supportWidth = max(0, content.bounds.width - codeTarget - 20 - supportStart)
        let overflowing = tabs.fittingSize.width > mainWidth || workspaceLayout.headerFittingWidth > supportWidth
        tabOverflow.isHidden = !overflowing
        if overflowWidth.constant != (overflowing ? 28 : 0) { overflowWidth.constant = overflowing ? 28 : 0 }
        if tabsWidth.constant != mainWidth { tabsWidth.constant = mainWidth }
        if supportHeaderLeading.constant != supportStart { supportHeaderLeading.constant = supportStart }
        tabScroll.isHidden = store.state.selected == nil
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
        menu.addItem(ClosureMenuItem("New session") { [weak self] in self?.newWorkspace() })
        return menu
    }
    @objc private func toggleWorkspaceSidebar() { store.update { $0.sidebarCollapsed.toggle() } }
    @objc private func toggleCodeSidebar() {
        if (supportingContentHost as? BrowserArtifactContentHost)?.focusAddress(in: window) == true { return }
        if workspaceLayout.showsSupportingContent { store.update { $0.setSupportingLayout(.collapsed) }; focusSelectedContent() }
        else if store.state.selected?.support?.tabs.isEmpty == false { store.update { $0.setSupportingLayout(.split) } }
        else { store.update { $0.openSupport(.changes, title: "Changes") } }
    }
    private func supportMenu(_ anchor: NSView) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Browser") { [weak self] in self?.newTab() })
        menu.addItem(ClosureMenuItem("Open artifact…") { [weak self] in
            guard let self else { return }
            BrowserArtifactContentHost.chooseArtifact(in: window) { [weak self] path in
                self?.store.update { $0.openSupport(.artifact(path: path), title: (path as NSString).lastPathComponent) }
                self?.focusSupportingContent()
            }
        })
        menu.addItem(ClosureMenuItem("Files and Changes") { [weak self] in self?.store.update { $0.openSupport(.changes, title: "Changes") } })
        menu.addItem(ClosureMenuItem("Terminal") { [weak self] in
            guard let self, let primary = store.state.primaryTerminalID else { return }; openTerminal(from: primary)
        })
        if let workspace = store.state.selected {
            for terminal in workspace.retainedSupportingTerminals {
                menu.addItem(ClosureMenuItem("Reopen " + terminal.title) { [weak self] in
                    self?.store.update { $0.openSupport(.terminal(tabID: terminal.id), title: terminal.title) }
                })
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }
    private func renderSupportingContent() {
        let workspace = store.state.selected
        workspaceLayout.update(workspace?.support ?? SupportingPanelState())
        workspaceLayout.layoutSubtreeIfNeeded()
        supportingContentHost?.retainTabs(Set(store.state.workspaces.flatMap { $0.support?.tabs.map(\.id) ?? [] }))
        guard let workspace, let tab = workspace.support?.selected, workspaceLayout.showsSupportingContent else {
            workspaceLayout.show(nil); supportContentKey = ""; return
        }
        let key = workspace.id.uuidString + tab.id.uuidString
        switch tab.target {
        case .changes, .file:
            workspaceLayout.show(files.layout)
        case .terminal:
            workspaceLayout.show(supportingTerminal)
        case .browser, .artifact:
            if let view = supportingContentHost?.view(for: tab, workspace: workspace, update: { [weak self, tabID = tab.id, workspaceID = workspace.id] target, title in
                self?.store.update(debounced: true) { $0.updateSupport(tabID, target: target, title: title, workspaceID: workspaceID) }
            }) { workspaceLayout.show(view) }
            else if key != supportContentKey {
                let label = NSTextField(wrappingLabelWithString: "This supporting view is unavailable in this build.")
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
        for (title, action, key) in [("New session", #selector(newWorkspace), "n"), ("New browser tab", #selector(newTab), "t"),
            ("Close view", #selector(closeSelectedTab), "w"), ("Start selected CLI", #selector(launchSelected), "\r"),
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
        view.addItem(ClosureMenuItem("Focus Files and Changes") { [weak self] in self?.store.update { $0.openSupport(.changes, title: "Changes") }; self?.files.focusSidebar() })
        for (title, action, key) in [("Toggle workspace sidebar", #selector(toggleWorkspaceSidebar), "b"),
                                     ("Show or hide Files and Changes", #selector(toggleCodeSidebar), "l")] {
            let entry = view.addItem(withTitle: title, action: action, keyEquivalent: key)
            entry.target = self; entry.keyEquivalentModifierMask = .command
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
    private func handleCommand(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, window.attachedSheet == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command {
            switch key {
            case "b": toggleWorkspaceSidebar()
            case "l": toggleCodeSidebar()
            case "n": newWorkspace()
            case "t": newTab()
            case "w": closeSelectedTab()
            case "k": findWorkspace()
            case "\r":
                guard let id = store.state.selectedTab?.id, store.state.selectedTab?.isEditable == true,
                      composers[id]?.hasInputFocus == true else { return false }
                launchSelected()
            default: return false
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
        railWidth.constant = state.sidebarCollapsed ? SpookkyStyle.railWidth : SpookkyStyle.sidebarWidth
        updateHeaderGeometry()
        window.contentView?.layoutSubtreeIfNeeded()
        renderSupportingContent()
        files.update(state.selected, operation: state.locations?.operations.last(where: { $0.status == .complete })?.request.id)
        files.layout.layoutSubtreeIfNeeded()
        let lastOperation = state.locations?.operations.last
        let locationNotice = lastOperation.flatMap { [.failed, .uncertain, .cancelled].contains($0.status) ? $0.request.kind.rawValue.capitalized + " · " + ($0.error ?? $0.request.destination) : nil }
        let identityNotice = state.selected?.conversationOwnershipAmbiguous == true ? "Conversation identity is shared by multiple retained terminals. Ownership needs review before resume." : nil
        warning.stringValue = store.saveError ?? identityNotice ?? historyNotice ?? activeLocation.map { $0.request.kind.rawValue.capitalized + " · " + $0.request.destination } ?? locationNotice ?? ""
        warning.lineBreakMode = .byTruncatingTail; warning.toolTip = warning.stringValue
        warning.isHidden = warning.stringValue.isEmpty
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
        let chrome = historySearch.stringValue + String(historyLimit) + workspaceChrome + projectChrome + selectionChrome + String(describing: window.effectiveAppearance.name) + state.workspaces.map { String($0.viewClosed == true) }.joined()
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
        let sidebarKey = state.projects.map { $0.id.uuidString + $0.name + $0.location.scopePath + String($0.location.isGit) }.joined() +
            String(collapsed) + String(describing: window.effectiveAppearance.name)
        if sidebarKey != sidebarRevision {
            renameEditor?.cancel(); renameEditor = nil
            let focusedProject = projectRows.first { $0.value.primary === window.firstResponder }?.key
            let focusedWorkspace = workspaceRows.first { $0.value.primary === window.firstResponder }?.key
            sidebarRevision = sidebarKey; workspaceRows.removeAll(); projectRows.removeAll(); clear(rail)
            avatarTasks.values.forEach { $0.cancel() }; avatarTasks.removeAll()
            let paths = Set(state.projects.map { $0.location.scopePath })
            projectOwners = projectOwners.filter { paths.contains($0.key) }
            let newWorkspace = ActionButton(collapsed ? "" : "New session", symbol: "plus", help: "New session · ⌘N") { [weak self] in self?.newWorkspace() }
            newWorkspace.emphasis = .secondary
            rail.addArrangedSubview(newWorkspace)
            rail.addArrangedSubview(ActionButton(collapsed ? "" : "Search", symbol: "magnifyingglass", help: "Find workspace · ⌘K") { [weak self] in self?.findWorkspace() })
            if !collapsed {
                rail.addArrangedSubview(historySearch)
            }
            let projectLabel = NSTextField(labelWithString: collapsed ? "" : "Projects")
            projectLabel.font = .systemFont(ofSize: 11, weight: .medium); projectLabel.textColor = SpookkyPalette.secondary
            let projectAdd = ActionButton("", symbol: "plus", help: "Add project") { [weak self] in
                self?.addProjectMenu(anchor: self?.projectAddButton)
            }
            projectAddButton = projectAdd
            if collapsed {
                rail.addArrangedSubview(projectAdd)
            } else {
                let projectHeader = NSStackView(views: [projectLabel, NSView(), projectAdd])
                projectHeader.spacing = 8; rail.addArrangedSubview(projectHeader)
                projectAdd.widthAnchor.constraint(equalToConstant: SpookkyStyle.controlHeight).isActive = true
                projectHeader.widthAnchor.constraint(equalTo: rail.widthAnchor, constant: -16).isActive = true
            }
            for button in rail.arrangedSubviews.compactMap({ $0 as? ActionButton }) {
                button.alignment = collapsed ? .center : .left
                button.widthAnchor.constraint(equalToConstant: collapsed ? 32 : SpookkyStyle.sidebarWidth - 16).isActive = true
                if collapsed { button.heightAnchor.constraint(equalToConstant: 32).isActive = true }
            }
            rail.alignment = collapsed ? .centerX : .leading
            for (projectIndex, project) in state.projects.enumerated() {
                if projectIndex > 0, let previous = rail.arrangedSubviews.last { rail.setCustomSpacing(8, after: previous) }
                let row = contextRow(title: collapsed ? "" : project.name, symbol: "folder", secondarySymbol: "plus",
                    help: project.name + " · " + project.location.path, selected: false, monogram: project.name,
                    select: { [weak self] in
                        self?.store.update {
                            if collapsed { $0.sidebarCollapsed = false; $0.setProjectCollapsed(project.id, false) }
                            else { $0.toggleProjectCollapsed(project.id) }
                        }
                    },
                    secondary: { [weak self] in self?.newProjectWorkspace(project.id) })
                row.secondary = { [weak self] in
                    let menu = NSMenu()
                    menu.addItem(ClosureMenuItem("Refresh conversations") { [weak self] in self?.requestCatalogRefresh(force: true) })
                    menu.addItem(ClosureMenuItem("Remove project") { self?.store.update { $0.removeProject(project.id) } })
                    return menu
                }
                row.primary?.setAccessibilityLabel(project.name)
                row.primary?.setAccessibilityValue(project.isCollapsed == true ? "Collapsed" : "Expanded")
                row.primary?.toolTip = (project.isCollapsed == true ? "Expand " : "Collapse ") + project.name
                row.restingIcon = row.icon?.image
                let previousInteraction = row.onInteractionChange
                row.onInteractionChange = { [weak row] active in
                    previousInteraction?(active)
                    guard let row, !collapsed else { return }
                    row.icon?.image = active ? NSImage(systemSymbolName: row.groupCollapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil) : row.restingIcon
                    row.icon?.contentTintColor = active ? SpookkyPalette.secondary : nil
                }
                rail.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: collapsed ? 32 : SpookkyStyle.sidebarWidth - 16).isActive = true
                projectRows[project.id] = row
                installProjectAvatar(project, row: row, collapsed: collapsed)
            }
            unboundHistoryLabel.textColor = SpookkyPalette.secondary
            unboundHistoryLabel.font = .systemFont(ofSize: 11)
            rail.addArrangedSubview(unboundHistoryLabel)
            rail.addArrangedSubview(historyMore)
            if let focusedProject, let button = projectRows[focusedProject]?.primary { window.makeFirstResponder(button) }
            else if let focusedWorkspace, let button = workspaceRows[focusedWorkspace]?.primary { window.makeFirstResponder(button) }
        }
        for project in state.projects {
            guard let row = projectRows[project.id] else { continue }
            let nextCollapsed = project.isCollapsed == true && historySearch.stringValue.isEmpty
            if row.groupCollapsed != nextCollapsed {
                row.groupCollapsed = nextCollapsed
                row.onInteractionChange?(row.interactionActive)
            }
            row.primary?.setAccessibilityValue(row.groupCollapsed ? "Collapsed" : "Expanded")
            row.primary?.toolTip = (row.groupCollapsed ? "Expand " : "Collapse ") + project.name + " · " + project.location.path
            if !project.location.isGit { projectOwners[project.location.scopePath] = nil }
        }
        reconcileSidebarRows(state, collapsed: collapsed)
        for workspace in state.workspaces {
            guard let row = workspaceRows[workspace.id] else { continue }
            row.primary?.title = collapsed ? "" : workspace.displayTitle
            row.primary?.toolTip = workspace.displayTitle + " · " + workspace.directory
            row.primary?.setAccessibilityLabel(workspace.displayTitle + " · " + workspace.directory)
            row.primary?.setAccessibilityValue(workspace.id == state.selectedWorkspaceID ? "Selected" : "")
            row.secondaryButton?.toolTip = "Close " + workspace.displayTitle
            row.secondaryButton?.setAccessibilityLabel("Close " + workspace.displayTitle)
            let branch = workspace.anchor?.branch
            let supportCount = workspace.support?.tabs.count ?? 0
            let count = supportCount == 0 ? (workspace.displayProvider == .shell ? "Terminal" : "Conversation") : String(supportCount) + (supportCount == 1 ? " supporting tab" : " supporting tabs")
            let status = workspace.primaryTerminal?.status
            let attention = status.flatMap { $0 == .draft || $0 == .running ? nil : $0 }
            let kind = workspace.anchor?.isGit == true ? (workspace.anchor?.checkoutIdentity == workspace.anchor?.commonRepository ? "Local" : "Worktree") : (SpookkyStyle.abbreviatedPath(workspace.directory) == "~" ? "Home" : "Folder")
            let generatedBranch = WorkspaceNaming.isGeneratedBranch(branch, workspaceID: workspace.id)
            let context = workspace.anchor == nil ? "Not started" : branch == workspace.displayTitle || generatedBranch ? kind : branch ?? kind
            let activity = attention == nil || attention == .ended ? workspace.activityState : nil
            var statusText = activity?.label ?? attention.map { SpookkyStyle.statusLabel($0) + " · " + count } ?? context + " · " + count
            let associationDetail = workspace.currentProjectAssociation.map { "\n" + $0.message } ?? ""
            let detail = [workspace.directory, branch ?? kind, count].joined(separator: " · ") + (workspace.primaryTerminal?.activity.map { "\n" + AgentIndicator.detail($0) } ?? "") + associationDetail
            if let metadata = workspace.catalogMetadata, workspace.primaryTerminal?.binding == nil {
                switch metadata.availability {
                case .local: statusText = "Saved · " + SpookkyStyle.abbreviatedPath(metadata.directory)
                case .folderUnavailable: statusText = "Folder unavailable"
                case .historyUnavailable: statusText = "History unavailable"
                }
            }
            if workspace.conversationOwnershipAmbiguous == true { statusText = "Conversation ownership unknown" }
            row.metadata?.stringValue = statusText; row.metadata?.toolTip = detail
            row.metadata?.textColor = workspace.conversationOwnershipAmbiguous == true ? SpookkyPalette.warning : activity.map(AgentIndicator.color) ?? (attention == .failed || attention == .uncertain || attention == .unavailable ? SpookkyPalette.warning : SpookkyPalette.metadata)
            row.icon?.image = SpookkyStyle.toolImage(workspace.displayProvider)
            row.icon?.contentTintColor = SpookkyPalette.secondary
            row.primary?.setAccessibilityLabel(workspace.displayTitle + " · " + workspace.displayProvider.displayName + " · " + statusText + associationDetail)
            row.primary?.toolTip = workspace.displayTitle + " · " + workspace.displayProvider.displayName + "\n" + detail
            if let badge = row.statusBadge {
                let symbol = activity.flatMap(AgentIndicator.symbol) ?? attention.flatMap(SpookkyStyle.statusSymbol)
                badge.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                badge.contentTintColor = row.metadata?.textColor ?? activity.map(AgentIndicator.color) ?? SpookkyPalette.metadata
                badge.isHidden = symbol == nil
            }
            if collapsed { row.primary?.image = row.icon?.image; row.primary?.contentTintColor = row.icon?.contentTintColor }
            row.selected = workspace.id == state.selectedWorkspaceID
        }
        let tabsKey = String(describing: state.selectedWorkspaceID) + String(describing: state.selected?.primaryTerminalID)
        if tabsKey != tabRevision {
            renameEditor?.cancel(); renameEditor = nil
            tabRevision = tabsKey; tabPairs.removeAll(); clear(tabs)
            if let w = state.selected {
                for tab in w.tabs where tab.id == w.primaryTerminalID {
                    let select = ActionButton(w.displayTitle, symbol: SpookkyStyle.toolSymbol(tab.binding?.tool ?? tab.draft.tool), help: w.displayTitle + " · " + tab.status.rawValue) { [weak self] in self?.selectTab(tab.id) }
                    select.drawsInteractionFill = false
                    select.onDoubleClick = { [weak self] in self?.rename(workspaceID: w.id) }
                    let close = ActionButton("", symbol: "xmark", help: "Close " + tab.title, height: SpookkyStyle.compactHeight) { [weak self] in self?.closeWorkspace(w.id) }
                    let status = NSImageView(); status.symbolConfiguration = .init(pointSize: 12, weight: .regular)
                    status.widthAnchor.constraint(equalToConstant: 16).isActive = true; status.heightAnchor.constraint(equalToConstant: 16).isActive = true
                    let pair = ChromeStackView(views: [select, status, close]); pair.spacing = 0
                    close.revealOnInteraction = true
                    pair.onInteractionChange = { [weak close] in close?.interactionActive = $0 }
                    select.onFocusChange = { [weak pair, weak select] focused in if let select { pair?.trackFocus(select, focused) } }
                    close.onFocusChange = { [weak pair, weak close] focused in if let close { pair?.trackFocus(close, focused) } }
                    select.onHoverChange = { [weak pair, weak select] inside in if let select { pair?.trackHover(select, inside) } }
                    close.onHoverChange = { [weak pair, weak close] inside in if let close { pair?.trackHover(close, inside) } }
                    pair.cornerRadius = 0; pair.drawsTrailingBorder = true
                    select.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).isActive = true
                    pair.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).isActive = true
                    close.widthAnchor.constraint(equalToConstant: SpookkyStyle.compactHeight).isActive = true
                    close.heightAnchor.constraint(equalToConstant: SpookkyStyle.compactHeight).isActive = true
                    select.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
                    select.lineBreakMode = .byTruncatingTail
                    pair.menu = NSMenu(); pair.menu?.addItem(ClosureMenuItem("Rename conversation…") { [weak self] in self?.rename(workspaceID: w.id) })
                    select.onContextMenu = { [weak pair] in pair?.menu }
                    select.onNavigate = { [weak self] key in self?.moveTabFocus(from: tab.id, offset: key == 123 || key == 126 ? -1 : 1) }
                    tabs.addArrangedSubview(pair)
                    tabPairs[tab.id] = pair
                }
            }
        }
        updateHeaderGeometry()
        if let workspace = state.selected {
            for tab in workspace.tabs {
                guard let pair = tabPairs[tab.id], let button = pair.arrangedSubviews.first as? ActionButton else { continue }
                button.title = workspace.displayTitle; button.toolTip = workspace.displayTitle + " · " + tab.status.rawValue
                button.setAccessibilityLabel(button.toolTip!)
                button.setAccessibilityValue("Primary conversation")
                let tool = workspace.displayProvider
                button.image = SpookkyStyle.toolImage(tool)
                button.toolTip = workspace.displayTitle + " · " + tool.displayName + " · " + SpookkyStyle.statusLabel(tab.status) + (tab.activity.map { "\n" + AgentIndicator.detail($0) } ?? "")
                button.setAccessibilityLabel(button.toolTip!)
                if let status = pair.arrangedSubviews[1] as? NSImageView {
                    let activity = [.running, .ended].contains(tab.status) ? tab.activity?.displayState : nil
                    let symbol = activity.flatMap(AgentIndicator.symbol) ?? SpookkyStyle.statusSymbol(tab.status); status.isHidden = symbol == nil
                    status.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                    status.contentTintColor = activity.map(AgentIndicator.color) ?? ([.failed, .uncertain, .unavailable].contains(tab.status) ? SpookkyPalette.warning : SpookkyPalette.metadata)
                    status.toolTip = tab.activity.map(AgentIndicator.detail) ?? SpookkyStyle.statusLabel(tab.status); status.setAccessibilityLabel(status.toolTip!)
                }
                let menu = NSMenu(); menu.addItem(ClosureMenuItem("Rename conversation…") { [weak self] in self?.rename(workspaceID: workspace.id) })
                addAgentActions(menu, ids: [tab.id]); addContinuationAction(menu, workspaceID: workspace.id); pair.menu = menu
                button.contentTintColor = SpookkyPalette.text
                pair.selected = workspace.support?.layout != .fullWidth || workspace.support?.resolvedFullWidthSelection == .primary
                button.setAccessibilityValue(pair.selected ? "Selected primary conversation" : "Primary conversation")
                if let close = pair.arrangedSubviews.last as? ActionButton { close.setAccessibilityLabel("Close " + workspace.displayTitle); close.toolTip = "Close " + workspace.displayTitle }
                DispatchQueue.main.async { pair.scrollToVisible(pair.bounds) }
            }
        }
        updateAgentAnimations()
    }
    func catalogProjectSignature() -> String {
        store.state.projects.map { $0.id.uuidString + $0.location.path }.joined(separator: "\n")
    }
    func requestCatalogRefresh(force: Bool) {
        let signature = catalogProjectSignature()
        if !force, signature == historyProjectSignature, let date = historyRefreshedAt, Date().timeIntervalSince(date) < 30 { return }
        if historyRefreshTask != nil && !force && signature == historyProjectSignature { return }
        historyProjectSignature = signature
        historyRefreshedAt = Date()
        historyRefreshTask?.cancel()
        let generation = UUID(); historyGeneration = generation
        let projects = store.state.projects
        historyRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if historyGeneration == generation { historyRefreshTask = nil } }
            let snapshot = await sessionCatalog.refresh(force: force)
            guard !Task.isCancelled, historyGeneration == generation, catalogProjectSignature() == signature else { return }
            do {
                let directories = Array(Set(snapshot.conversations.map(\.directory)))
                let batch = try await associationResolver.resolveBatch(directories: directories, projects: projects,
                    limits: ProjectAssociationBatchLimits(maximumDirectories: 4096, maximumRequests: 16_384))
                guard !Task.isCancelled, historyGeneration == generation, catalogProjectSignature() == signature else { return }
                historyRefreshedAt = Date()
                historyNotice = snapshot.issues.isEmpty ? nil : snapshot.issues.map(\.message).joined(separator: " ")
                if snapshot.truncated { historyNotice = "History refresh reached its bound. Retained conversations remain searchable. Refresh again to retry." }
                // Prepare value metadata away from terminal input. Never overwrite edits made while it runs.
                for _ in 0..<3 {
                    let baseline = store.state
                    let preparation = Task.detached { () -> WorkspaceState in
                        var next = baseline
                        ConversationCatalogReconciler.apply(snapshot, batch: batch, to: &next)
                        return next
                    }
                    let next = await withTaskCancellationHandler(operation: { await preparation.value }, onCancel: { preparation.cancel() })
                    guard !Task.isCancelled, historyGeneration == generation, catalogProjectSignature() == signature else { return }
                    guard store.state == baseline else { continue }
                    store.update { $0 = next }
                    render(); return
                }
                historyNotice = "Conversation refresh was deferred while workspace state changed. Refresh conversations to retry."
                render()
            } catch is CancellationError { }
            catch {
                guard historyGeneration == generation else { return }
                historyNotice = "Conversation refresh could not resolve projects. " + error.localizedDescription + " Retained conversations are unchanged. Use Refresh conversations to retry."
                render()
            }
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === historySearch else { return }
        historyLimit = 50; chromeRevision = ""; render()
    }
    private func reconcileSidebarRows(_ state: WorkspaceState, collapsed: Bool) {
        let page = ConversationSidebarPage(state: state, query: historySearch.stringValue, limit: historyLimit)
        let desired = page.workspaces
        let ids = Set(desired.map(\.id))
        for id in Array(workspaceRows.keys) where !ids.contains(id) {
            if let row = workspaceRows.removeValue(forKey: id) { rail.removeArrangedSubview(row); row.removeFromSuperview() }
        }
        func place(_ entries: [Workspace], after anchor: NSView) {
            guard let start = rail.arrangedSubviews.firstIndex(where: { $0 === anchor }) else { return }
            for (offset, workspace) in entries.enumerated() {
                if workspaceRows[workspace.id] == nil { addWorkspaceRow(workspace, collapsed: collapsed) }
                guard let row = workspaceRows[workspace.id] else { continue }
                let position = start + offset + 1
                if rail.arrangedSubviews.firstIndex(where: { $0 === row }) != position {
                    rail.removeArrangedSubview(row); row.removeFromSuperview()
                    rail.insertArrangedSubview(row, at: min(position, rail.arrangedSubviews.count))
                }
            }
        }
        for project in state.projects {
            if let row = projectRows[project.id] { place(desired.filter { $0.projectID == project.id }, after: row) }
        }
        unboundHistoryLabel.isHidden = collapsed || !desired.contains { $0.projectID == nil }
        place(desired.filter { $0.projectID == nil }, after: unboundHistoryLabel)
        historyMore.isHidden = page.remaining == 0
        historyMore.title = "Show more (\(page.remaining) remaining)"
        historyMore.toolTip = "Show 50 more saved conversations. Search includes all retained history."
    }
    func openConversationWorkspace(_ id: UUID) {
        guard let workspace = store.state.workspaces.first(where: { $0.id == id }) else { return }
        selectWorkspace(id)
        guard let item = workspace.catalogMetadata, workspace.conversationID == item.id,
              let primary = workspace.primaryTerminal else { return }
        guard workspace.conversationOwnershipAmbiguous != true else {
            alert("Conversation ownership unknown", "Multiple retained records refer to this conversation. No process was started."); return
        }
        guard !continuingConversations.contains(item.id) else { return }
        continuingConversations.insert(item.id)
        Task {
            defer { continuingConversations.remove(item.id) }
            if primary.binding != nil || primary.launch != nil {
                await launches.reconcile(primary.id)
                for _ in 0..<100 {
                    if !launches.isBusy(primary.id) { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                guard !launches.isBusy(primary.id), let observed = store.state.tab(primary.id) else { return }
                if observed.status == .running { reconnect(primary.id); return }
                guard observed.status == .ended else { return }
            }
            guard item.availability == .local else {
                alert("Conversation unavailable", item.availability == .folderUnavailable ? "The saved folder is unavailable. Locate it before continuing." : "The saved provider history is unavailable. Refresh conversations before continuing."); return
            }
            let assessment = await associationResolver.resolve(directory: item.directory, projects: store.state.projects, preferredProjectID: workspace.projectID)
            guard let location = assessment.location, assessment.status == .matched || assessment.status == .unregistered else {
                alert("Conversation location unavailable", assessment.message ?? "Choose the original folder before continuing."); return
            }
            if let reason = await ConversationExecutionCheck.blockReason(item, resolver: savedConversationResolver) {
                historyNotice = reason; contentKey = ""; render()
                alert("Continuation unavailable", reason); return
            }
            guard let current = store.state.workspaces.first(where: { $0.id == id }), current.conversationID == item.id,
                  current.primaryTerminalID == primary.id,
                  current.primaryTerminal?.binding == nil || current.primaryTerminal?.status == .ended else { return }
            if current.primaryTerminal?.status == .ended { surfaces.release(primary.id) }
            store.update { $0.setLocation(location, projectID: assessment.projectID, workspaceID: id) }
            await launches.resume(primary.id, conversation: item)
        }
    }
    private func contextRow(title: String, symbol: String, secondarySymbol: String, help: String, selected: Bool, nested: Bool = false,
                            monogram: String? = nil, select: @escaping () -> Void, secondary: @escaping () -> Void) -> ContextRow {
        let row = ContextRow(); row.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = store.state.sidebarCollapsed
        let primary = FadingTitleButton(title, symbol: collapsed ? symbol : nil, help: help, action: select)
        if collapsed, let monogram { primary.image = SpookkyStyle.monogram(monogram) }
        primary.contentInset = collapsed ? SpookkyStyle.controlInset : 0
        primary.drawsInteractionFill = false
        row.primary = primary
        primary.onContextMenu = { [weak row] in row?.secondary?() }
        primary.onNavigate = { [weak self, weak primary] key in
            guard let self, let primary else { return }
            let controls = self.rail.arrangedSubviews.filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { ($0 as? ContextRow)?.primary }
            guard let index = controls.firstIndex(where: { $0 === primary }), !controls.isEmpty else { return }
            let offset = key == 123 || key == 126 ? -1 : 1
            let target = controls[(index + offset + controls.count) % controls.count]
            target.scrollToVisible(target.bounds); self.window.makeFirstResponder(target)
        }
        primary.alignment = .left; primary.lineBreakMode = .byTruncatingTail
        let action = ActionButton("", symbol: secondarySymbol, help: secondarySymbol == "plus" ? "New session for " + title : "Close " + title, action: secondary)
        row.secondaryButton = action
        action.revealOnInteraction = true
        row.onInteractionChange = { [weak action, weak primary] active in
            action?.interactionActive = active; primary?.revealTitle = active
        }
        primary.onFocusChange = { [weak row, weak primary] focused in if let primary { row?.trackFocus(primary, focused) } }
        action.onFocusChange = { [weak row, weak action] focused in if let action { row?.trackFocus(action, focused) } }
        primary.onHoverChange = { [weak row, weak primary] inside in if let primary { row?.trackHover(primary, inside) } }
        action.onHoverChange = { [weak row, weak action] inside in if let action { row?.trackHover(action, inside) } }
        let isWorkspace = secondarySymbol == "xmark"
        let icon = NSImageView()
        row.icon = icon
        icon.image = monogram.map(SpookkyStyle.monogram) ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: SpookkyStyle.leadingIconSize, weight: .regular)
        icon.contentTintColor = SpookkyPalette.secondary
        icon.setAccessibilityElement(false)
        for view in [primary, action, icon] { view.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(view) }
        icon.isHidden = collapsed; action.isHidden = collapsed
        let iconInset: CGFloat = nested ? 24 : SpookkyStyle.controlInset
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: collapsed ? 32 : isWorkspace ? SpookkyStyle.workspaceRowHeight : SpookkyStyle.controlHeight),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: iconInset),
            icon.widthAnchor.constraint(equalToConstant: SpookkyStyle.iconSlot), icon.heightAnchor.constraint(equalToConstant: SpookkyStyle.iconSlot),
            icon.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            primary.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: collapsed ? 0 : iconInset + 24),
            primary.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: collapsed ? 0 : -36),
            primary.topAnchor.constraint(equalTo: row.topAnchor), primary.heightAnchor.constraint(equalToConstant: collapsed ? 32 : SpookkyStyle.controlHeight),
            action.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            action.topAnchor.constraint(equalTo: row.topAnchor), action.widthAnchor.constraint(equalToConstant: SpookkyStyle.controlHeight),
            action.heightAnchor.constraint(equalToConstant: SpookkyStyle.controlHeight)
        ])
        if isWorkspace && !collapsed {
            let metadata = NSTextField(labelWithString: "")
            metadata.font = .systemFont(ofSize: 11); metadata.textColor = SpookkyPalette.metadata
            metadata.lineBreakMode = .byTruncatingMiddle; row.metadata = metadata
            metadata.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(metadata)
            NSLayoutConstraint.activate([
                metadata.leadingAnchor.constraint(equalTo: primary.leadingAnchor),
                metadata.trailingAnchor.constraint(equalTo: primary.trailingAnchor),
                metadata.topAnchor.constraint(equalTo: row.topAnchor, constant: 27),
                metadata.heightAnchor.constraint(equalToConstant: 14)
            ])
        }
        primary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.selected = selected
        return row
    }
    private func addWorkspaceRow(_ workspace: Workspace, collapsed: Bool, at index: Int? = nil) {
        let row = contextRow(title: collapsed ? "" : workspace.displayTitle, symbol: "terminal", secondarySymbol: "xmark",
            help: workspace.displayTitle + " · " + workspace.directory, selected: workspace.id == store.state.selectedWorkspaceID, nested: workspace.projectID != nil,
            select: { [weak self] in self?.openConversationWorkspace(workspace.id) },
            secondary: { [weak self] in self?.closeWorkspace(workspace.id) })
        if collapsed, let primary = row.primary {
            let badge = PassthroughImageView(); badge.translatesAutoresizingMaskIntoConstraints = false
            badge.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
            badge.setAccessibilityElement(false); primary.addSubview(badge); row.statusBadge = badge
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: primary.trailingAnchor, constant: -1),
                badge.bottomAnchor.constraint(equalTo: primary.bottomAnchor, constant: -1),
                badge.widthAnchor.constraint(equalToConstant: 10), badge.heightAnchor.constraint(equalToConstant: 10)
            ])
        }
        row.primary?.onDoubleClick = { [weak self] in self?.rename(workspaceID: workspace.id) }
        row.secondary = { [weak self] in
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Rename workspace…") { self?.rename(workspaceID: workspace.id) })
            if let self { self.addAgentActions(menu, ids: self.store.state.workspaces.first { $0.id == workspace.id }?.tabs.map(\.id) ?? []) }
            self?.addContinuationAction(menu, workspaceID: workspace.id)
            menu.addItem(ClosureMenuItem("Stop primary terminal…") { self?.stopPrimaryAgent(workspace.id) })
            menu.addItem(ClosureMenuItem("Close workspace view") { self?.closeWorkspace(workspace.id) })
            if let current = self?.store.state.workspaces.first(where: { $0.id == workspace.id }),
               let record = self?.store.state.locations?.checkouts.first(where: { $0.location.checkoutIdentity == (current.anchor ?? current.selectedLocation).checkoutIdentity }), record.createdBy != nil {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Delete worktree…") { self?.deleteWorktree(record) })
            }
            return menu
        }
        if let index { rail.insertArrangedSubview(row, at: index) } else { rail.addArrangedSubview(row) }
        workspaceRows[workspace.id] = row
        row.widthAnchor.constraint(equalToConstant: collapsed ? 32 : SpookkyStyle.sidebarWidth - 16).isActive = true
    }
    private func installProjectAvatar(_ project: Project, row: ContextRow, collapsed: Bool) {
        guard project.location.isGit else { return }
        avatarTasks[project.id] = Task { [weak self, weak row] in
            guard let self else { return }
            let path = project.location.scopePath
            let owner: String
            if let known = projectOwners[path] { owner = known }
            else {
                owner = (try? await GitRepository().githubOwner(project.location)) ?? ""
                guard !Task.isCancelled else { return }
                projectOwners[path] = owner
            }
            guard !owner.isEmpty, !Task.isCancelled else { return }
            let cached = await avatarCache.cached(owner)
            if let cached, let row { applyProjectAvatar(cached, row: row, collapsed: collapsed) }
            let data = await avatarCache.image(owner)
            guard !Task.isCancelled, let data, let row, row.superview != nil else { return }
            applyProjectAvatar(data, row: row, collapsed: collapsed)
        }
    }
    private func applyProjectAvatar(_ data: Data, row: ContextRow, collapsed: Bool) {
        guard let image = NSImage(data: data) else { return }
        image.size = NSSize(width: 16, height: 16); row.restingIcon = image
        if !row.interactionActive { row.icon?.image = image; row.icon?.contentTintColor = nil }
        if collapsed { row.primary?.image = image }
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
        let row = workspaceRows[first.workspace]?.primary
        checks["primary_row_exposes_limitation"] = row?.toolTip?.contains("Fixture: project association unsupported") == true &&
            row?.accessibilityLabel()?.contains("Fixture: project association unsupported") == true
        record(first, status: .associated, message: "Fixture: primary project association verified")
        record(second, status: .associated, message: "Fixture: second project association verified")
        checks["primary_row_refreshes_without_recreation"] = row === workspaceRows[first.workspace]?.primary &&
            row?.toolTip?.contains("Fixture: primary project association verified") == true
        checks["support_focus_does_not_change_owner"] = store.state.selectedTab?.id == shellID && window.firstResponder === support &&
            store.state.selected?.primaryTerminalID == first.terminal && store.state.tab(shellID)?.projectAssociation == nil
        checks["association_is_presented_on_conversation_row"] =
            (tabPairs[first.terminal]?.arrangedSubviews.first as? ActionButton)?.accessibilityLabel()?.contains("Fixture: primary project association verified") != true
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
        let pair = tabPairs[primary], row = workspaceRows[workspaceID]
        store.update { $0.setProviderTitle("Verify session continuity", conversationID: codexID) }
        var checks: [String: Bool] = [:]
        checks["refresh_preserves_controls_and_focus"] = tabPairs[primary] === pair && workspaceRows[workspaceID] === row && window.firstResponder === responder
        checks["refresh_preserves_surface_and_input"] = surfaces.view(primary) === surface && surface.visibleText().contains("IDENTITY_KEEP")
        checks["primary_tab_title_refreshes"] = (tabPairs[primary]?.arrangedSubviews.first as? ActionButton)?.title == "Verify session continuity"
        checks["primary_accessibility_names_provider_and_title"] = (pair?.arrangedSubviews.first as? ActionButton)?.accessibilityLabel()?.contains("Verify session continuity · Codex") == true
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
            let primaryControl = tabPairs[primary], sidebarControl = workspaceRows[workspaceID]
            store.update { $0.setProviderTitle("Title changed externally", conversationID: codexID) }
            let kind = SupportingTab(target: target, title: title).contentLabel.lowercased()
            checks["primary_identity_with_" + kind] = store.state.selected?.displayProvider == .codex && store.state.selected?.displayTitle == "Title changed externally" && store.state.primaryTerminalID == primary
            checks["refresh_preserves_" + kind + "_focus"] = window.firstResponder === focus && workspaceLayout.content.subviews.first === content && tabPairs[primary] === primaryControl && workspaceRows[workspaceID] === sidebarControl
        }
        checks["support_count_refreshes"] = workspaceRows[workspaceID]?.metadata?.stringValue.contains("3 supporting tabs") == true
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
        if let button = tabPairs[primary]?.arrangedSubviews.first as? ActionButton {
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
        if let mainTab = tabPairs[primary]?.arrangedSubviews.first as? ActionButton { mainTab.performClick(nil) }
        if let renderTask { await renderTask.value }
        window.contentView?.layoutSubtreeIfNeeded()
        checks["main_tab_selects_full_primary_without_collapsing_tabs"] = store.state.selected?.support?.layout == .fullWidth && store.state.selected?.support?.resolvedFullWidthSelection == .primary && !body.isHidden && workspaceLayout.panel.isHidden && !workspaceLayout.headerView.isHidden
        checks["full_primary_preserves_right_selection"] = store.state.selected?.support?.selectedTabID == shell
        checks["hidden_support_retains_terminal_geometry"] = workspaceLayout.panel.bounds.size == fullSupportingSize
        checks["full_headers_join_on_same_row"] = abs(tabScroll.frame.maxX - workspaceLayout.headerView.frame.minX) < 1 && abs(tabScroll.frame.minY - workspaceLayout.headerView.frame.minY) < 1
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
        if let firstFile { store.update { $0.selectSupport(firstFile) } }
        if let renderTask { await renderTask.value }
        await files.settleForFixture()
        var screenshots = 0
        func selectedSupportingTabIsVisible(_ view: NSView) -> Bool {
            if let button = view as? ActionButton, button.selected { return button.visibleRect.width > 0 }
            return view.subviews.contains { selectedSupportingTabIsVisible($0) }
        }
        for theme in [WorkspaceAppearance.dark, .light] {
            for width in [1120, 680] {
                store.update { $0.appearance = theme }
                window.setContentSize(NSSize(width: width, height: width == 1120 ? 760 : 480))
                if try capture("identity-revised-" + theme.rawValue + "-" + String(width)) { screenshots += 1 }
                checks["primary_header_\(theme.rawValue)_\(width)"] = tabPairs.count == 1 && tabPairs[primary]?.frame.height == SpookkyStyle.headerHeight
                checks["selected_support_tab_visible_\(theme.rawValue)_\(width)"] = selectedSupportingTabIsVisible(workspaceLayout.headerView)
            }
        }
        checks["desktop_narrow_both_themes"] = screenshots == 4
        store.update {
            $0.recordAgentEvent(AgentEvent(bindingID: binding.id, invocationID: binding.id, secret: UUID(), provider: .codex,
                                          kind: .needsInput, sessionID: codexID.sessionID))
            $0.sidebarCollapsed = true
        }
        window.contentView?.layoutSubtreeIfNeeded()
        checks["rail_preserves_primary_provider_and_activity"] = workspaceRows[workspaceID]?.primary?.image != nil && workspaceRows[workspaceID]?.statusBadge?.image != nil && workspaceRows[workspaceID]?.primary?.accessibilityLabel()?.contains("Needs input") == true
        checks["rail_names_provider_and_title"] = workspaceRows[workspaceID]?.primary?.accessibilityLabel()?.contains("Title changed externally · Codex") == true
        checks["badge_does_not_intercept_clicks"] = workspaceRows[workspaceID]?.statusBadge?.hitTest(NSPoint(x: 5, y: 5)) == nil
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
            draftWorkspace = $0.newWorkspace(directory: root.path)
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
        guard let temporaryShell = store.state.selected?.tabs.first(where: { $0.id != draftTerminal && $0.binding?.tool == .shell }) else {
            throw LaunchError.invalid("Open Terminal did not start the supporting shell.")
        }
        checks["startup_open_terminal_preserves_agent_draft"] = store.state.tab(draftTerminal)?.draft.tool == .codex && store.state.tab(draftTerminal)?.draft.prompt == "Retain this starting instruction" && store.state.tab(draftTerminal)?.binding == nil
        checks["startup_open_terminal_has_no_agent_prompt"] = temporaryShell.launch?.tool == .shell && temporaryShell.launch?.arguments.contains("Retain this starting instruction") == false && temporaryShell.promptDelivery == .none
        checks["startup_shell_does_not_erase_provider_preference"] = store.state.lastAgentTool == .codex
        try await launches.terminate(temporaryShell.id); surfaces.release(temporaryShell.id)
        store.update {
            $0.closeWorkspace(draftWorkspace)
            if let returningWorkspace { $0.selectWorkspace(returningWorkspace) }
        }
        if let renderTask { await renderTask.value }
        try PrivateFiles.write(checks, to: root.appendingPathComponent("identity-checks.json"))
    }
    private func checkSidebar(root: URL) async throws {
        let location = WorkspaceLocation(path: root.path)
        var projectID = UUID(), workspaceID = UUID()
        let name = "Investigate workspace navigation and preserve terminal drafts"
        store.update {
            projectID = $0.registerProject(location)
            workspaceID = $0.newWorkspace(location: location, projectID: projectID)
            $0.renameWorkspace(workspaceID, name)
            $0.editDraft($0.selectedTab!.id, tool: .codex, prompt: "Keep this unsent draft")
        }
        let original = store.state.selected!
        let count = store.state.workspaces.count
        var checks: [String: Bool] = [:]
        try await Task.sleep(for: .milliseconds(50))
        window.contentView?.layoutSubtreeIfNeeded()
        guard let project = projectRows[projectID], let workspace = workspaceRows[workspaceID],
              let title = workspace.primary as? FadingTitleButton, let close = workspace.secondaryButton,
              let pair = tabPairs[original.selectedTabID], let tabClose = pair.arrangedSubviews.last as? ActionButton else {
            throw LaunchError.invalid("Sidebar fixture controls are unavailable.")
        }
        checks["close_hidden_at_rest"] = !close.isRevealed && !tabClose.isRevealed
        checks["compact_tab_close_target"] = abs(tabClose.frame.width - 24) <= 0.5 && abs(tabClose.frame.height - 24) <= 0.5
        let hitPoint = NSPoint(x: close.frame.midX, y: close.frame.midY)
        checks["hidden_close_ignores_pointer_hit"] = close.hitTest(hitPoint) == nil
        guard let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil),
              let exited = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil) else { throw LaunchError.invalid("Sidebar pointer fixture is unavailable.") }
        project.primary?.mouseEntered(with: entered)
        checks["child_hover_reveals_project_action"] = project.secondaryButton?.isRevealed == true
        project.primary?.mouseExited(with: exited)
        workspace.mouseEntered(with: entered)
        checks["hover_reveals_close_and_routes_hit"] = close.isRevealed && close.hitTest(hitPoint) === close
        checks["revealed_close_has_button_role"] = close.accessibilityRole() == .button
        workspace.mouseExited(with: exited)
        checks["hover_exit_hides_close"] = !close.isRevealed && close.hitTest(hitPoint) == nil
        let firstFocused = FadingTitleButton(name, action: {})
        firstFocused.frame = NSRect(x: 0, y: 0, width: 100, height: 28); firstFocused.revealTitle = true
        firstFocused.drawTitle(in: firstFocused.bounds, tint: SpookkyPalette.text)
        let titleLayer = firstFocused.layer?.sublayers?.first?.sublayers?.first
        let firstAnimation = titleLayer?.animation(forKey: "reveal") as? CABasicAnimation
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        checks["first_focused_title_reveal_respects_motion"] = reducedMotion ? firstAnimation == nil :
            firstAnimation?.fromValue as? CGFloat == titleLayer.map { $0.bounds.width / 2 } && (firstAnimation?.duration ?? 0) >= 0.5 && (firstAnimation?.duration ?? 7) <= 6
        firstFocused.title = "Rename a workspace while its long name is already revealing"
        firstFocused.drawTitle(in: firstFocused.bounds, tint: SpookkyPalette.text)
        let renamedAnimation = titleLayer?.animation(forKey: "reveal") as? CABasicAnimation
        checks["renamed_title_reveals_from_start"] = reducedMotion ? renamedAnimation == nil :
            renamedAnimation?.fromValue as? CGFloat == titleLayer.map { $0.bounds.width / 2 }
        let frame = title.frame
        window.makeFirstResponder(title)
        checks["keyboard_reveals_close_and_title"] = close.isRevealed && title.revealTitle
        title.displayIfNeeded()
        checks["visible_title_starts_reveal"] = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ||
            title.layer?.sublayers?.first?.sublayers?.first?.animation(forKey: "reveal") != nil
        checks["title_alignment_stable"] = title.frame == frame
        window.makeFirstResponder(project.primary)
        project.primary?.performClick(nil)
        checks["project_click_hides_rows_immediately"] = workspaceRows[workspaceID] == nil && store.state.projects.first { $0.id == projectID }?.isCollapsed == true
        checks["collapse_preserves_workspace_and_draft"] = store.state.selected == original && store.state.workspaces.count == count
        checks["removed_title_stops_animation"] = title.layer?.sublayers?.first?.sublayers?.first?.animationKeys()?.isEmpty != false
        checks["collapse_preserves_project_keyboard_focus"] = window.firstResponder === projectRows[projectID]?.primary
        checks["collapse_retains_project_control"] = projectRows[projectID] === project
        checks["collapse_releases_workspace_view"] = workspace.superview == nil
        focusSidebar()
        checks["sidebar_focus_reaches_collapsed_project"] = window.firstResponder === projectRows[projectID]?.primary
        projectRows[projectID]?.primary?.performClick(nil)
        checks["expand_restores_rows"] = workspaceRows[workspaceID]?.isHidden == false && store.state.workspaces.count == count
        projectRows[projectID]?.secondaryButton?.performClick(nil)
        checks["separate_plus_creates_one_workspace"] = store.state.workspaces.count == count + 1 && store.state.selected?.projectID == projectID
        store.update { $0.setProjectCollapsed(projectID, true); $0.selectWorkspace(workspaceID) }
        checks["selection_reveals_project"] = workspaceRows[workspaceID]?.isHidden == false
        store.update { $0.sidebarCollapsed = true }
        projectRows[projectID]?.primary?.performClick(nil)
        checks["rail_project_opens_sidebar_without_creation"] = !store.state.sidebarCollapsed && workspaceRows[workspaceID]?.isHidden == false && store.state.workspaces.count == count + 1
        var screenshots: [String] = []
        for (theme, size) in [(WorkspaceAppearance.dark, NSSize(width: 1120, height: 760)), (.light, NSSize(width: 650, height: 450))] {
            store.update { $0.appearance = theme }
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
            window.makeFirstResponder(nil)
            guard let content = window.contentView, let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            var background = NSColor.clear
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                background = window.backgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
                content.cacheDisplay(in: content.bounds, to: image)
            }
            let composite = NSImage(size: content.bounds.size, flipped: false) { bounds in
                background.setFill(); bounds.fill(); image.draw(in: bounds); return true
            }
            if let tiff = composite.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                let file = "sidebar-" + theme.rawValue + ".png"
                try png.write(to: root.appendingPathComponent(file)); screenshots.append(file)
            }
        }
        checks["wide_and_narrow_native_snapshots"] = screenshots.count == 2
        store.update { $0.appearance = .dark }
        window.setContentSize(NSSize(width: 1120, height: 760)); window.contentView?.layoutSubtreeIfNeeded()
        var shellID: UUID?
        store.update { shellID = $0.newTab() }
        guard let shellID else { throw LaunchError.invalid("Sidebar shell fixture is unavailable.") }
        await launches.launch(shellID, tool: .shell)
        for _ in 0..<100 {
            if surfaces.view(shellID) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let surface = surfaces.view(shellID), let binding = store.state.tab(shellID)?.binding else {
            throw LaunchError.invalid("Sidebar shell fixture did not attach.")
        }
        surface.insertText("SPOOKKY_SIDEBAR_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(150))
        let before = try await launches.runtime.inspect(binding)
        projectRows[projectID]?.primary?.performClick(nil)
        let after = try await launches.runtime.inspect(binding)
        checks["collapse_preserves_running_process"] = before?.processID != nil && before?.processID == after?.processID && surfaces.view(shellID) === surface
        projectRows[projectID]?.primary?.performClick(nil)
        checks["collapse_preserves_terminal_input"] = surface.visibleText().contains("SPOOKKY_SIDEBAR_UNSENT")
        checks["agent_draft_survives_shell_and_collapse"] = store.state.tab(original.selectedTabID)?.draft == original.tabs[0].draft
        func cpuSeconds() -> Double {
            var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let idleStart = cpuSeconds(), idleTime = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        let idleCPU = (cpuSeconds() - idleStart) / (ProcessInfo.processInfo.systemUptime - idleTime) * 100
        window.makeFirstResponder(workspaceRows[workspaceID]?.primary)
        let activeStart = cpuSeconds(), activeTime = ProcessInfo.processInfo.systemUptime
        let avatar = await avatarCache.image("superset-sh")
        try await Task.sleep(for: .seconds(2))
        let activeCPU = (cpuSeconds() - activeStart) / (ProcessInfo.processInfo.systemUptime - activeTime) * 100
        window.makeFirstResponder(nil)
        let settledStart = cpuSeconds(), settledTime = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        let settledCPU = (cpuSeconds() - settledStart) / (ProcessInfo.processInfo.systemUptime - settledTime) * 100
        let resources: [String: Double] = ["idle_app_cpu_percent": idleCPU, "reveal_and_avatar_app_cpu_percent": activeCPU,
            "settled_app_cpu_percent": settledCPU, "app_rss_mib": WorkspaceDiagnostics.residentMiB() ?? -1,
            "avatar_bytes": Double(avatar?.count ?? 0), "terminal_session_count": 1]
        try PrivateFiles.write(resources, to: root.appendingPathComponent("sidebar-resources.json"))
        try await store.flush()
        try PrivateFiles.write(checks, to: root.appendingPathComponent("sidebar-checks.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Sidebar fixture failed: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", ") + ". Tab close target: " + String(describing: tabClose.frame.size)) }
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
                    install(ActionButton("New session", symbol: "plus") { [weak self] in self?.newWorkspace() }, in: body)
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
            let message = NSTextField(wrappingLabelWithString: workspace.catalogMetadata?.displayTitle ?? workspace.title)
            message.font = .systemFont(ofSize: 15, weight: .medium)
            let action = ActionButton("Continue saved conversation", symbol: "arrow.up.forward") { [weak self] in self?.openConversationWorkspace(workspace.id) }
            let details = NSTextField(wrappingLabelWithString: historyNotice ?? "Open the exact saved conversation in its original folder. Provider permissions and ownership checks remain active.")
            details.textColor = SpookkyPalette.secondary
            let stack = NSStackView(views: [message, details, action]); stack.orientation = .vertical; stack.alignment = .leading
            stack.spacing = 12; stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
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
            let title = NSTextField(labelWithString: (isPrimary ? owner?.displayTitle ?? tab.title : tab.title) + " · " + SpookkyStyle.abbreviatedPath(directory))
            title.font = .monospacedSystemFont(ofSize: 11, weight: .regular); title.textColor = SpookkyPalette.metadata; title.lineBreakMode = .byTruncatingMiddle
            title.toolTip = directory; paneTitles[tab.id] = title
            let split = ActionButton("", symbol: "rectangle.split.2x1", help: "Split terminal") { [weak self] in self?.split(tab.id) }
            split.isEnabled = tab.status == .running
            let activityLabel = NSTextField(labelWithString: tab.activity?.displayState == .idle ? "" : tab.activity?.displayState.label ?? "")
            activityLabel.font = .systemFont(ofSize: 11); activityLabel.textColor = tab.activity.map { AgentIndicator.color($0.displayState) } ?? SpookkyPalette.metadata
            activityLabel.isHidden = activityLabel.stringValue.isEmpty; activityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            agentHeaderLabels[tab.id] = activityLabel
            var headerViews: [NSView] = [title, NSView(), activityLabel, split]
            if tab.status == .ended {
                headerViews.append(ActionButton("Session ended · New terminal", symbol: "plus") { [weak self] in self?.openTerminal(from: tab.id) })
            }
            if store.state.selected?.split != nil {
                headerViews.append(ActionButton("", symbol: "rectangle", help: "Show one terminal; keep both sessions") { [weak self] in self?.store.update { $0.collapseSplit() } })
            }
            let header = ChromeStackView(views: headerViews); header.spacing = 8; header.cornerRadius = 0
            header.selected = store.state.selected?.split != nil && store.state.selectedTab?.id == tab.id
            paneHeaders[tab.id] = header
            header.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 8)
            let content: NSView
            if let surface, tab.status == .running || tab.status == .ended { content = surface }
            else {
                let message = NSTextField(wrappingLabelWithString: tab.failure?.message ?? "Session " + tab.status.rawValue)
                message.font = .systemFont(ofSize: 13); message.textColor = SpookkyPalette.text
                let stack = NSStackView(views: [message])
                stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
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
                header.topAnchor.constraint(equalTo: container.topAnchor), header.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight),
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
        guard let pair = tabPairs[target], let button = pair.arrangedSubviews.first else { return }
        pair.scrollToVisible(pair.bounds); window.makeFirstResponder(button)
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
        guard let workspace = store.state.selected else { return }
        let row = workspaceRows[workspace.id]
        let button = row?.isHidden == false ? row?.primary : workspace.projectID.flatMap { projectRows[$0]?.primary }
        if let button { window.makeFirstResponder(button) }
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
        store.update { $0.newWorkspace(directory: FileManager.default.homeDirectoryForCurrentUser.path) }
        if hidden { reopen() }
    }
    private func addBlankTab() { files.revealTerminal(); if store.state.selected == nil { newWorkspace() } else { store.update { $0.newTab() } } }
    @objc private func newTab() {
        if store.state.selected == nil { newWorkspace() }
        if !window.isVisible { showWindow() }
        store.update { $0.openSupport(.browser(url: "about:blank"), title: "Browser") }; focusSupportingContent()
    }
    private func openTerminal(from id: UUID) {
        guard let tab = store.state.tab(id) else { return }
        if !tab.draft.prompt.isEmpty || !tab.isEditable || store.state.workspace(containing: id)?.primaryTerminalID == id && tab.binding != nil {
            store.update { $0.newTab() }; if let id = store.state.selectedTab?.id { launch(id, tool: .shell) }
        } else { launch(id, tool: .shell) }
    }
    @objc private func launchSelected() {
        guard let id = store.state.selectedTab?.id, composers[id]?.hasInputFocus == true else { return }; launch(id)
    }
    private func launch(_ id: UUID, tool: SessionTool? = nil) {
        guard let workspace = store.state.workspace(containing: id), let tab = store.state.tab(id),
              !launches.isBusy(id), tab.isEditable || (tab.status == .failed && tab.launch != nil) else { return }
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
        if workspace.anchor != nil || (workspace.locationDraft?.mode != .worktree && workspace.locationOperationID == nil) { launchPrepared(id, tool: tool); return }
        store.update { $0.apply(.preparing, to: id) }
        Task {
            do {
                _ = try await locations.prepare(workspaceID: workspace.id)
                guard store.state.tab(id) != nil else { return }
                launchPrepared(id, tool: tool)
            } catch {
                let recovery: FailureRecovery?
                if case .folderUnavailable = error as? LaunchError { recovery = .locateFolder } else { recovery = nil }
                store.update { $0.apply(.failure(.failed, TabFailure(.validation, error.localizedDescription, recovery: recovery), clearIntent: true), to: id) }
            }
        }
    }
    private func launchPrepared(_ id: UUID, tool: SessionTool? = nil) {
        guard store.state.workspace(containing: id) != nil, !launches.isBusy(id) else { return }
        Task { await agentPreferencesTask?.value; await launches.launch(id, tool: tool) }
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
        guard let project = store.state.projects.first(where: { $0.id == id }) else { return }
        store.update { $0.newWorkspace(location: project.location, projectID: id) }
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
            let alert = NSAlert(); alert.messageText = "Delete worktree?"
            alert.informativeText = request.destination + "\n\nType the exact folder path. Spookky checks session ownership, edits, locks, and merged/pushed commits. The branch is kept."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
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
        let button = tabID.flatMap { tabPairs[$0]?.arrangedSubviews.first as? ActionButton } ?? workspaceID.flatMap { workspaceRows[$0]?.primary }
        guard let button else { return }
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
        let alert = NSAlert(); alert.messageText = "Find workspace"
        let picker = NSComboBox(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
        let entries = store.state.workspaces
        picker.addItems(withObjectValues: entries.map { $0.displayTitle + " · " + ($0.conversationID?.sessionID ?? "") + " · " + $0.directory })
        picker.completes = true; alert.accessoryView = picker
        alert.window.initialFirstResponder = picker
        alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn else { return }
            let index = picker.indexOfSelectedItem
            if entries.indices.contains(index) { self?.store.update { $0.sidebarCollapsed = false }; self?.openConversationWorkspace(entries[index].id) }
        }
    }
    @objc private func closeSelectedTab() {
        if workspaceLayout.hasFocus, workspaceLayout.showsSupportingContent, let id = store.state.selected?.support?.selectedTabID {
            store.update { $0.closeSupport(id) }; focusSupportingContent()
        } else if let id = store.state.selectedWorkspaceID { closeWorkspace(id) }
        else { window.performClose(nil) }
    }
    private func closeWorkspace(_ id: UUID) {
        Task {
            await surfaces.captureViewports()
            store.update { $0.hideWorkspace(id) }
            try? await store.flush()
            if store.state.selected == nil { window.close() }
        }
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
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
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
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
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
        guard !(store.state.locations?.operations.contains(where: { $0.status == .running }) ?? false),
              !store.state.workspaces.flatMap(\.tabs).contains(where: { launches.isBusy($0.id) }) else { return .terminateCancel }
        let live = store.state.workspaces.flatMap(\.tabs).contains {
            [.running, .preparing, .launching, .uncertain, .unavailable].contains($0.status) ||
                ($0.status == .failed && $0.binding != nil)
        }
        Task {
            do {
                try await store.flush()
                if live && !services.installingUpdate {
                    let alert = NSAlert(); alert.messageText = "Quit Spookky?"
                    alert.informativeText = "Choose whether your terminal sessions should keep running. Ending terminals may leave work running on a shared provider server or in the background. Use the provider’s own Stop or Interrupt control to stop that work first."
                    alert.addButton(withTitle: "Keep running and quit"); alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "End terminals and quit").hasDestructiveAction = true
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
        continuationTask?.cancel()
        files.suspend()
        renderTask?.cancel(); surfaces.invalidate(); contentKey = ""
        Task { await surfaces.captureViewports(); if !window.isVisible { surfaces.releaseAll() }; try? await store.flush() }
    }
    func reopen() {
        if store.state.workspaces.isEmpty {
            store.update { $0.newWorkspace(directory: FileManager.default.homeDirectoryForCurrentUser.path) }
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
        if CommandLine.arguments.contains("--workspace-benchmark-browser") {
            guard count == 0, let host = supportingContentHost as? BrowserArtifactContentHost else { throw LaunchError.invalid("Browser fixtures require no launched sessions.") }
            try await SupportingPreviewFixture.run(window: window, host: host, state: { self.store.state },
                mutate: { change in self.store.update(change) }, command: { self.handleCommand($0) },
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
                supportingView: { self.workspaceLayout.panel }, selectWorkspace: { id in self.store.update { $0.selectWorkspace(id) } },
                openSupportingTerminal: { if let id = self.store.state.primaryTerminalID { self.openTerminal(from: id) } },
                reopenSupportingTerminal: { id in self.store.update { state in state.openSupport(.terminal(tabID: id), title: state.tab(id)?.title ?? "Terminal") } },
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

}
