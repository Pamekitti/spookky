import AppKit
import Darwin
import SpookkyCore
import SpookkyRuntime
import SpookkyWorkspace
import SpookkyGit

@MainActor final class WorkspaceWindowController: NSObject, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation {
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
    private let launches: LaunchCoordinator
    private let surfaces: TerminalSurfaceManager
    private let diagnostics: WorkspaceDiagnostics?
    private let rail = NSStackView()
    private let tabs = NSStackView()
    private let body = NSView()
    private lazy var files = FileWorkspaceController(store: store, terminal: body) { [weak self] in
        guard let self, let id = store.state.selectedTab?.id else { return }
        if let surface = surfaces.view(id) { window.makeFirstResponder(surface) }
        else { composers[id]?.focus() }
    }
    private let filesToggle = ActionButton("Code", symbol: "sidebar.right", help: "Show Files and Changes · ⌘L", action: {})
    private let sidebarToggle = ActionButton("", symbol: "sidebar.left", help: "Collapse workspace sidebar · ⌘B", action: {})
    private let tabOverflow = ActionButton("", symbol: "chevron.down", help: "All tabs", action: {})
    private let header = WorkspaceHeaderView()
    private var toggleLeading: NSLayoutConstraint!
    private var tabsLeading: NSLayoutConstraint!
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
    private var renderTask: Task<Void, Never>?
    private var closing = Set<UUID>()
    private var splitView: NSSplitView?
    private var installingSplit = false
    private let runtimeEvents: RuntimeEventMonitor
    private var observationTask: Task<Void, Never>?
    private var observationRequested = false
    private var wakeObserver: NSObjectProtocol?
    private var displayOptionsObserver: NSObjectProtocol?
    private var chromeRevision = ""
    private var sidebarRevision = ""
    private var tabRevision = ""
    private var workspaceRows: [UUID: ContextRow] = [:]
    private var projectRows: [UUID: ContextRow] = [:]
    private var tabPairs: [UUID: ChromeStackView] = [:]
    private var fullscreenTransition = false
    private var announcedError: String?
    private var renameEditor: InlineRenameEditor?
    private var paneHeaders: [UUID: ChromeStackView] = [:]
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
         resolver: any ExecutableResolver = CLIResolver(), backgroundFixture: Bool = false) throws {
        let paths = AppPaths(bundleID: Bundle.main.bundleIdentifier, home: FileManager.default.homeDirectoryForCurrentUser, userID: getuid())
        avatarCache = GitHubAvatarCache(directory: paths.data.appendingPathComponent("AvatarCache"))
        self.backgroundFixture = backgroundFixture
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
            resolver: AgentActivityResolver(base: resolver, root: root, helper: helper))
        surfaces = TerminalSurfaceManager(engine: engine, runtime: runtime, executable: tmux, root: root)
        diagnostics = WorkspaceDiagnostics(root: root)
        super.init()
        store.update { $0.restoreAgentActivity() }
        buildWindow(); buildMenu()
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
        store.onChange = { [weak self] in self?.render(); self?.refreshAgentAttention() }
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
        if backgroundFixture && (window.isKeyWindow || window.isMainWindow) {
            throw LaunchError.invalid("Background fixture took native window focus.")
        }
        Task {
            await locations.reconcileAll()
            await refreshSelectedRepository()
            observeRuntimeEvent()
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
        let old = store.state.workspaces.flatMap(\.tabs).first { $0.binding?.id == event.bindingID || $0.launch?.operationID == event.bindingID }?.activity
        var accepted: UUID?
        store.update(debounced: true) { state in accepted = state.recordAgentEvent(event) }
        guard let id = accepted, let tab = store.state.tab(id), let activity = tab.activity,
              let workspace = store.state.workspace(containing: id), event.childID == nil else { return }
        if event.kind == .attached { agentNotifications.requestPermission() }
        let next = activity.displayState
        if !next.needsAttention { agentNotifications.clear(id); return }
        guard next != old?.displayState || (next == .finished && activity.completionID != old?.completionID) else { return }
        let invocation = activity.invocationID
        let preferences = services.agentPreferences
        agentNotifications.schedule(tabID: id, state: next, workspace: workspace.title, provider: activity.provider.displayName,
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
            if let icon = workspaceRows[workspace.id]?.icon {
                let lifecycle = workspace.tabs.contains { [.failed, .uncertain, .unavailable, .launching, .preparing, .reconnecting].contains($0.status) }
                AgentIndicator.animate(icon, working: workspace.activityState == .working && !lifecycle)
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
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let displayOptionsObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver) }
        observationTask?.cancel()
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
        let workspaceBody = files.layout
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
        for view in [header, railScroll, tabScroll, workspaceBody, sidebarToggle, tabOverflow, filesToggle, warning, cancelLocation] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        rail.translatesAutoresizingMaskIntoConstraints = false; tabs.translatesAutoresizingMaskIntoConstraints = false
        railWidth = railScroll.widthAnchor.constraint(equalToConstant: SpookkyStyle.sidebarWidth)
        toggleLeading = sidebarToggle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 196)
        tabsLeading = tabScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SpookkyStyle.sidebarWidth)
        codeWidth = filesToggle.widthAnchor.constraint(equalToConstant: 64)
        overflowWidth = tabOverflow.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor), header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor), header.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight),
            railScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), railScroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            railScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor), railWidth,
            rail.widthAnchor.constraint(equalTo: railScroll.widthAnchor), rail.heightAnchor.constraint(greaterThanOrEqualTo: railScroll.heightAnchor),
            tabsLeading, tabScroll.trailingAnchor.constraint(equalTo: tabOverflow.leadingAnchor, constant: -4),
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
        let codeTitle = labeled ? "Code" : ""
        if filesToggle.title != codeTitle { filesToggle.title = codeTitle }
        let codeTarget: CGFloat = labeled ? 76 : 28
        if codeWidth.constant != codeTarget { codeWidth.constant = codeTarget }
        filesToggle.selected = store.state.selected?.fileView?.sidebar == true
        filesToggle.setAccessibilityValue(filesToggle.selected ? "Selected" : nil)
        filesToggle.toolTip = (filesToggle.selected ? "Hide" : "Show") + " Files and Changes · ⌘L"
        filesToggle.setAccessibilityLabel(filesToggle.toolTip!)
        sidebarToggle.toolTip = (collapsed ? "Expand" : "Collapse") + " workspace sidebar · ⌘B"
        sidebarToggle.setAccessibilityLabel(sidebarToggle.toolTip!)
        sidebarToggle.setAccessibilityValue(collapsed ? "Collapsed" : "Expanded")
        let overflowing = tabs.fittingSize.width > max(0, content.bounds.width - tabStart - codeTarget - 16)
        tabOverflow.isHidden = !overflowing
        if overflowWidth.constant != (overflowing ? 28 : 0) { overflowWidth.constant = overflowing ? 28 : 0 }
    }
    private func showTabOverflow() {
        guard let workspace = store.state.selected else { return }
        let menu = NSMenu()
        for tab in workspace.tabs {
            let title = tab.title + (tab.activity.map { " · " + $0.displayState.label } ?? "")
            let item = ClosureMenuItem(title) { [weak self] in self?.selectTab(tab.id) }
            item.state = tab.id == workspace.selectedTabID ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("New blank tab") { [weak self] in self?.addBlankTab() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: tabOverflow.bounds.height), in: tabOverflow)
    }
    @objc private func toggleWorkspaceSidebar() { store.update { $0.sidebarCollapsed.toggle() } }
    @objc private func toggleCodeSidebar() {
        let returnFocus = files.hasFocus && store.state.selected?.fileView?.sidebar == true
        files.toggle()
        if returnFocus { focusSelectedContent() }
    }
    private func buildMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), app = NSMenu()
        services.populate(app)
        app.addItem(withTitle: "Quit Spookky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app; main.addItem(appItem)
        let item = NSMenuItem(title: "File", action: nil, keyEquivalent: ""), file = NSMenu(title: "File")
        for (title, action, key) in [("New workspace", #selector(newWorkspace), "n"), ("New tab / Open Terminal", #selector(newTab), "t"),
            ("Close tab", #selector(closeSelectedTab), "w"), ("Start selected CLI", #selector(launchSelected), "\r"),
            ("Find workspace", #selector(findWorkspace), "k")] {
            let entry = file.addItem(withTitle: title, action: action, keyEquivalent: key); entry.target = self
        }
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
        view.addItem(ClosureMenuItem("Focus Files and Changes") { [weak self] in self?.files.focusSidebar() })
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
    private func render() {
        let state = store.state
        let activeLocation = state.locations?.operations.first { $0.status == .running }
        cancelLocation.isHidden = activeLocation == nil
        let appearanceName: NSAppearance.Name? = state.appearance == .system ? nil : state.appearance == .dark ? .darkAqua : .aqua
        if window.appearance?.name != appearanceName { window.appearance = appearanceName.flatMap(NSAppearance.init(named:)) }
        surfaces.setTheme(dark: window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        railWidth.constant = state.sidebarCollapsed ? SpookkyStyle.railWidth : SpookkyStyle.sidebarWidth
        updateHeaderGeometry()
        window.contentView?.layoutSubtreeIfNeeded()
        files.update(state.selected, operation: state.locations?.operations.last(where: { $0.status == .complete })?.request.id)
        files.layout.layoutSubtreeIfNeeded()
        let lastOperation = state.locations?.operations.last
        let locationNotice = lastOperation.flatMap { [.failed, .uncertain, .cancelled].contains($0.status) ? $0.request.kind.rawValue.capitalized + " · " + ($0.error ?? $0.request.destination) : nil }
        warning.stringValue = store.saveError ?? activeLocation.map { $0.request.kind.rawValue.capitalized + " · " + $0.request.destination } ?? locationNotice ?? ""
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
            let identity = w.id.uuidString + w.title + w.directory
            let anchor = (w.anchor?.branch ?? "") + String(describing: w.projectID)
            let tabs = w.tabs.map { tab -> String in
                let activity = tab.activity
                let children = activity?.children.map(\.id).joined() ?? ""
                return [tab.id.uuidString, tab.title, tab.status.rawValue, tab.draft.tool.rawValue,
                        String(describing: activity?.displayState), String(activity?.unread ?? false),
                        children, String(activity?.attached ?? false), activity?.preview ?? ""].joined(separator: "|")
            }.joined()
            return identity + anchor + w.selectedTabID.uuidString + tabs
        }.joined()
        let projectChrome = state.projects.map { project -> String in
            let identity = project.id.uuidString + project.name + project.location.scopePath
            return identity + String(project.location.isGit) + String(project.isCollapsed == true)
        }.joined()
        let selectionChrome = String(describing: state.selectedWorkspaceID) + String(state.sidebarCollapsed)
        let chrome = workspaceChrome + projectChrome + selectionChrome + String(describing: window.effectiveAppearance.name)
        if chrome != chromeRevision {
            chromeRevision = chrome
            window.effectiveAppearance.performAsCurrentDrawingAppearance { renderChrome() }
        }
        for (id, header) in paneHeaders { header.selected = state.selected?.split != nil && state.selectedTab?.id == id }
        for (id, label) in agentHeaderLabels {
            let activity = state.tab(id)?.activity
            let value = activity?.displayState ?? .idle
            label.stringValue = value == .idle ? "" : value.label + ((activity?.children.isEmpty == false) ? " · " + AgentIndicator.childLabel(activity!.children.count) : "")
            label.textColor = AgentIndicator.color(value); label.isHidden = label.stringValue.isEmpty
            label.toolTip = activity.map(AgentIndicator.detail); label.setAccessibilityLabel(label.stringValue)
        }
        let key = state.visibleTabIDs.map { id in id.uuidString + (state.tab(id)?.status.rawValue ?? "") + String(describing: state.tab(id)?.binding?.id) }.joined() + String(describing: state.selectedWorkspaceID) + String(state.selected?.split != nil && body.bounds.width >= 700)
        for id in state.visibleTabIDs {
            if let tab = state.tab(id), let w = state.workspace(containing: id) {
                composers[id]?.repositorySnapshot = w.projectID.flatMap { repositorySnapshots[$0] }
                composers[id]?.update(tab, workspace: w, state: state)
            }
        }
        guard key != contentKey else { return }
        contentKey = key; renderTask?.cancel(); surfaces.invalidate()
        if !files.hasFocus { window.makeFirstResponder(nil) }
        let started = ProcessInfo.processInfo.systemUptime
        renderTask = Task { [weak self] in await self?.renderContent(started: started) }
    }
    private func renderChrome() {
        let state = store.state, collapsed = state.sidebarCollapsed
        let sidebarKey = state.projects.map { $0.id.uuidString + $0.name + $0.location.scopePath + String($0.location.isGit) }.joined() +
            state.workspaces.map { $0.id.uuidString + String(describing: $0.projectID) }.joined() + String(collapsed) + String(describing: window.effectiveAppearance.name)
        if sidebarKey != sidebarRevision {
            renameEditor?.cancel(); renameEditor = nil
            let focusedProject = projectRows.first { $0.value.primary === window.firstResponder }?.key
            let focusedWorkspace = workspaceRows.first { $0.value.primary === window.firstResponder }?.key
            sidebarRevision = sidebarKey; workspaceRows.removeAll(); projectRows.removeAll(); clear(rail)
            avatarTasks.values.forEach { $0.cancel() }; avatarTasks.removeAll()
            let paths = Set(state.projects.map { $0.location.scopePath })
            projectOwners = projectOwners.filter { paths.contains($0.key) }
            let newWorkspace = ActionButton(collapsed ? "" : "New workspace", symbol: "plus", help: "New workspace · ⌘N") { [weak self] in self?.newWorkspace() }
            newWorkspace.emphasis = .secondary
            rail.addArrangedSubview(newWorkspace)
            rail.addArrangedSubview(ActionButton(collapsed ? "" : "Search", symbol: "magnifyingglass", help: "Find workspace · ⌘K") { [weak self] in self?.findWorkspace() })
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
                if project.isCollapsed != true {
                    for w in state.workspaces where w.projectID == project.id { addWorkspaceRow(w, collapsed: collapsed) }
                }
            }
            let unbound = state.workspaces.filter { $0.projectID == nil }
            if !collapsed && !unbound.isEmpty {
                let label = NSTextField(labelWithString: "No project")
                label.textColor = SpookkyPalette.secondary; label.font = .systemFont(ofSize: 11)
                rail.addArrangedSubview(label)
            }
            for workspace in unbound { addWorkspaceRow(workspace, collapsed: collapsed) }
            if let focusedProject, let button = projectRows[focusedProject]?.primary { window.makeFirstResponder(button) }
            else if let focusedWorkspace, let button = workspaceRows[focusedWorkspace]?.primary { window.makeFirstResponder(button) }
        }
        for project in state.projects {
            guard let row = projectRows[project.id] else { continue }
            let nextCollapsed = project.isCollapsed == true
            if row.groupCollapsed != nextCollapsed {
                row.groupCollapsed = nextCollapsed
                row.onInteractionChange?(row.interactionActive)
            }
            row.primary?.setAccessibilityValue(row.groupCollapsed ? "Collapsed" : "Expanded")
            row.primary?.toolTip = (row.groupCollapsed ? "Expand " : "Collapse ") + project.name + " · " + project.location.path
            let entries = state.workspaces.filter { $0.projectID == project.id }
            if row.groupCollapsed {
                for workspace in entries {
                    if let child = workspaceRows.removeValue(forKey: workspace.id) {
                        rail.removeArrangedSubview(child); child.removeFromSuperview()
                    }
                }
            } else if let index = rail.arrangedSubviews.firstIndex(where: { $0 === row }) {
                for (offset, workspace) in entries.enumerated() where workspaceRows[workspace.id] == nil {
                    addWorkspaceRow(workspace, collapsed: collapsed, at: index + 1 + offset)
                }
            }
            if !project.location.isGit { projectOwners[project.location.scopePath] = nil }
        }
        for workspace in state.workspaces {
            guard let row = workspaceRows[workspace.id] else { continue }
            row.primary?.title = collapsed ? "" : workspace.title
            row.primary?.toolTip = workspace.title + " · " + workspace.directory
            row.primary?.setAccessibilityLabel(workspace.title + " · " + workspace.directory)
            row.primary?.setAccessibilityValue(workspace.id == state.selectedWorkspaceID ? "Selected" : "")
            row.secondaryButton?.toolTip = "Close " + workspace.title
            row.secondaryButton?.setAccessibilityLabel("Close " + workspace.title)
            let branch = workspace.anchor?.branch
            let count = String(workspace.tabs.count) + (workspace.tabs.count == 1 ? " tab" : " tabs")
            let statuses = workspace.tabs.map(\.status)
            let attention = [TabStatus.failed, .uncertain, .unavailable, .preparing, .launching, .reconnecting].first { statuses.contains($0) }
                ?? (statuses.allSatisfy { $0 == .ended } ? .ended : nil)
            let kind = workspace.anchor?.isGit == true ? (workspace.anchor?.checkoutIdentity == workspace.anchor?.commonRepository ? "Local" : "Worktree") : (SpookkyStyle.abbreviatedPath(workspace.directory) == "~" ? "Home" : "Folder")
            let context = workspace.anchor == nil ? "Not started" : branch == workspace.title ? kind : branch ?? kind
            let activity = attention == nil || attention == .ended ? workspace.activityState : nil
            let working = workspace.tabs.filter { $0.activity?.displayState == .working }.count
            let activityLabel = activity.map { $0.label + ($0 == .needsInput && working > 0 ? " · \(working) working" : "") }
            row.metadata?.stringValue = activityLabel ?? attention.map { SpookkyStyle.statusLabel($0) + " · " + count } ?? context + " · " + count
            row.metadata?.toolTip = [workspace.directory, branch ?? kind, count] .joined(separator: " · ") + "\n" + workspace.tabs.compactMap { $0.activity.map(AgentIndicator.detail) }.joined(separator: "\n")
            row.metadata?.textColor = activity.map(AgentIndicator.color) ?? (attention == .failed || attention == .uncertain || attention == .unavailable ? SpookkyPalette.warning : SpookkyPalette.metadata)
            let tool = workspace.tabs.first { $0.id == workspace.selectedTabID }.map { $0.activity?.attached == true ? $0.activity!.provider : ($0.binding?.tool ?? $0.draft.tool) } ?? .shell
            row.icon?.image = NSImage(systemSymbolName: activity.flatMap(AgentIndicator.symbol) ?? attention.flatMap(SpookkyStyle.statusSymbol) ?? SpookkyStyle.toolSymbol(tool), accessibilityDescription: nil)
            row.icon?.contentTintColor = row.metadata?.textColor
            row.primary?.setAccessibilityLabel(workspace.title + " · " + (row.metadata?.stringValue ?? context))
            row.primary?.toolTip = workspace.title + "\n" + (row.metadata?.toolTip ?? workspace.directory)
            if collapsed { row.primary?.image = row.icon?.image; row.primary?.contentTintColor = row.icon?.contentTintColor }
            row.selected = workspace.id == state.selectedWorkspaceID
        }
        let tabsKey = String(describing: state.selectedWorkspaceID) + (state.selected?.tabs.map { $0.id.uuidString }.joined() ?? "")
        if tabsKey != tabRevision {
            renameEditor?.cancel(); renameEditor = nil
            tabRevision = tabsKey; tabPairs.removeAll(); clear(tabs)
            if let w = state.selected {
                for tab in w.tabs {
                    let select = ActionButton(tab.title, symbol: SpookkyStyle.toolSymbol(tab.binding?.tool ?? tab.draft.tool), help: tab.title + " · " + tab.status.rawValue) { [weak self] in self?.selectTab(tab.id) }
                    select.drawsInteractionFill = false
                    select.onDoubleClick = { [weak self] in self?.rename(tabID: tab.id) }
                    let close = ActionButton("", symbol: "xmark", help: "Close " + tab.title, height: SpookkyStyle.compactHeight) { [weak self] in self?.closeTabs([tab.id]) }
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
                    pair.menu = NSMenu(); pair.menu?.addItem(ClosureMenuItem("Rename tab…") { [weak self] in self?.rename(tabID: tab.id) })
                    select.onContextMenu = { [weak pair] in pair?.menu }
                    select.onNavigate = { [weak self] key in self?.moveTabFocus(from: tab.id, offset: key == 123 || key == 126 ? -1 : 1) }
                    tabs.addArrangedSubview(pair)
                    tabPairs[tab.id] = pair
                }
                tabs.addArrangedSubview(ActionButton("", symbol: "plus", help: "New blank tab") { [weak self] in self?.addBlankTab() })
            }
        }
        updateHeaderGeometry()
        if let workspace = state.selected {
            for tab in workspace.tabs {
                guard let pair = tabPairs[tab.id], let button = pair.arrangedSubviews.first as? ActionButton else { continue }
                button.title = tab.title; button.toolTip = tab.title + " · " + tab.status.rawValue
                button.setAccessibilityLabel(button.toolTip!)
                button.setAccessibilityValue(tab.id == workspace.selectedTabID ? "Selected" : "")
                let tool = tab.activity?.attached == true ? tab.activity!.provider : (tab.binding?.tool ?? tab.draft.tool)
                button.image = NSImage(systemSymbolName: SpookkyStyle.toolSymbol(tool), accessibilityDescription: nil)
                button.toolTip = tab.title + " · " + tool.displayName + " · " + SpookkyStyle.statusLabel(tab.status) + (tab.activity.map { "\n" + AgentIndicator.detail($0) } ?? "")
                button.setAccessibilityLabel(button.toolTip!)
                if let status = pair.arrangedSubviews[1] as? NSImageView {
                    let activity = [.running, .ended].contains(tab.status) ? tab.activity?.displayState : nil
                    let symbol = activity.flatMap(AgentIndicator.symbol) ?? SpookkyStyle.statusSymbol(tab.status); status.isHidden = symbol == nil
                    status.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                    status.contentTintColor = activity.map(AgentIndicator.color) ?? ([.failed, .uncertain, .unavailable].contains(tab.status) ? SpookkyPalette.warning : SpookkyPalette.metadata)
                    status.toolTip = tab.activity.map(AgentIndicator.detail) ?? SpookkyStyle.statusLabel(tab.status); status.setAccessibilityLabel(status.toolTip!)
                }
                let menu = NSMenu(); menu.addItem(ClosureMenuItem("Rename tab…") { [weak self] in self?.rename(tabID: tab.id) })
                addAgentActions(menu, ids: [tab.id]); pair.menu = menu
                button.contentTintColor = tab.id == workspace.selectedTabID ? SpookkyPalette.text : SpookkyPalette.secondary
                pair.selected = tab.id == workspace.selectedTabID
                if let close = pair.arrangedSubviews.last as? ActionButton { close.setAccessibilityLabel("Close " + tab.title); close.toolTip = "Close " + tab.title }
                if tab.id == workspace.selectedTabID { DispatchQueue.main.async { pair.scrollToVisible(pair.bounds) } }
            }
        }
        updateAgentAnimations()
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
        let action = ActionButton("", symbol: secondarySymbol, help: secondarySymbol == "plus" ? "New workspace for " + title : "Close " + title, action: secondary)
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
        let row = contextRow(title: collapsed ? "" : workspace.title, symbol: "terminal", secondarySymbol: "xmark",
            help: workspace.title + " · " + workspace.directory, selected: workspace.id == store.state.selectedWorkspaceID, nested: workspace.projectID != nil,
            select: { [weak self] in self?.selectWorkspace(workspace.id) },
            secondary: { [weak self] in self?.closeWorkspace(workspace.id) })
        row.primary?.onDoubleClick = { [weak self] in self?.rename(workspaceID: workspace.id) }
        row.secondary = { [weak self] in
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Rename workspace…") { self?.rename(workspaceID: workspace.id) })
            if let self { self.addAgentActions(menu, ids: self.store.state.workspaces.first { $0.id == workspace.id }?.tabs.map(\.id) ?? []) }
            menu.addItem(ClosureMenuItem("Close workspace") { self?.closeWorkspace(workspace.id) })
            if let record = self?.store.state.locations?.checkouts.first(where: { $0.location.checkoutIdentity == (workspace.anchor ?? workspace.selectedLocation).checkoutIdentity }), record.createdBy != nil {
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
            let bounds = body.bounds, fraction = store.state.selected?.split?.fraction ?? 0.5
            var sizes: [UUID: NSSize] = [:]
            for (index, tab) in records.enumerated() {
                let portion = index == 0 ? fraction : 1 - fraction
                let width = records.count == 2 && bounds.width >= 700 ? (bounds.width - 1) * portion : bounds.width
                let height = records.count == 2 && bounds.width < 700 ? (bounds.height - 1) * portion : bounds.height
                sizes[tab.id] = NSSize(width: max(1, width), height: max(1, height - 36))
            }
            let prepared = try await surfaces.prepare(terminals, sizes: sizes)
            guard !Task.isCancelled, let prepared, ids == store.state.visibleTabIDs else { return }
            body.subviews.forEach { $0.removeFromSuperview() }; splitView = nil; paneHeaders.removeAll(); agentHeaderLabels.removeAll()
            guard !records.isEmpty else {
                install(ActionButton("New workspace", symbol: "plus") { [weak self] in self?.newWorkspace() }, in: body)
                return
            }
            let panes = records.map { pane($0, surface: prepared[$0.id]) }
            if panes.count == 2 {
                let split = NSSplitView(); split.dividerStyle = .thin; split.isVertical = body.bounds.width >= 700
                split.delegate = self; installingSplit = true
                panes.forEach { split.addArrangedSubview($0) }; install(split, in: body); body.layoutSubtreeIfNeeded()
                let size = split.isVertical ? split.bounds.width : split.bounds.height
                split.setPosition(size * (store.state.selected?.split?.fraction ?? 0.5), ofDividerAt: 0)
                installingSplit = false; splitView = split
            } else { install(panes[0], in: body) }
            let active = store.state.selectedTab?.id
            if !files.hasFocus {
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
        if tab.isEditable || tab.status == .preparing || tab.status == .launching {
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
            let directory = store.state.workspace(containing: tab.id)?.directory ?? ""
            let title = NSTextField(labelWithString: (tab.binding?.tool ?? tab.draft.tool).displayName + " · " + SpookkyStyle.abbreviatedPath(directory))
            title.font = .monospacedSystemFont(ofSize: 11, weight: .regular); title.textColor = SpookkyPalette.metadata; title.lineBreakMode = .byTruncatingMiddle
            title.toolTip = directory
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
        files.revealTerminal()
        guard let id = store.state.selectedTab?.id else { return }
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
        files.revealTerminal()
        if store.state.selectedTab?.id == id { focusSelectedContent() }
        else { store.update { $0.selectTab(id) } }
        refreshAgentAttention(clearManual: true)
    }
    private func moveTabFocus(from id: UUID, offset: Int) {
        guard let tabs = store.state.selected?.tabs, let index = tabs.firstIndex(where: { $0.id == id }), !tabs.isEmpty else { return }
        let target = tabs[(index + offset + tabs.count) % tabs.count].id
        guard let pair = tabPairs[target], let button = pair.arrangedSubviews.first else { return }
        pair.scrollToVisible(pair.bounds); window.makeFirstResponder(button)
    }
    private func cycleTab(_ offset: Int) {
        guard let tabs = store.state.selected?.tabs, let index = tabs.firstIndex(where: { $0.id == store.state.selectedTab?.id }), !tabs.isEmpty else { return }
        selectTab(tabs[(index + offset + tabs.count) % tabs.count].id)
    }
    @objc private func nextTab() { cycleTab(1) }
    @objc private func previousTab() { cycleTab(-1) }
    @objc private func renameSelectedTab() { if let id = store.state.selectedTab?.id { rename(tabID: id) } }
    @objc private func focusSidebar() {
        guard let workspace = store.state.selected else { return }
        let row = workspaceRows[workspace.id]
        let button = row?.isHidden == false ? row?.primary : workspace.projectID.flatMap { projectRows[$0]?.primary }
        if let button { window.makeFirstResponder(button) }
    }
    @objc private func focusTabStrip() { if let id = store.state.selectedTab?.id { moveTabFocus(from: id, offset: 0) } }
    @objc private func focusOtherPane() {
        guard let ids = store.state.selected?.split.map({ [$0.first, $0.second] }), let other = ids.first(where: { $0 != store.state.selectedTab?.id }) else { return }
        selectTab(other); if let view = surfaces.view(other) { window.makeFirstResponder(view) }
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
        files.revealTerminal()
        if store.state.selected == nil { newWorkspace() }
        else if !window.isVisible { reopen() }
        guard let tab = store.state.selectedTab else { return }
        if tab.isEditable { openTerminal(from: tab.id) } else { addBlankTab() }
    }
    private func openTerminal(from id: UUID) {
        guard let tab = store.state.tab(id), !launches.isBusy(id) else { return }
        if !tab.draft.prompt.isEmpty || !tab.isEditable {
            store.update { $0.newTab() }; if let id = store.state.selectedTab?.id { launch(id, tool: .shell) }
        } else { launch(id, tool: .shell) }
    }
    @objc private func launchSelected() {
        guard let id = store.state.selectedTab?.id, composers[id]?.hasInputFocus == true else { return }; launch(id)
    }
    private func launch(_ id: UUID, tool: SessionTool? = nil) {
        guard let workspace = store.state.workspace(containing: id), let tab = store.state.tab(id),
              !launches.isBusy(id), tab.isEditable || (tab.status == .failed && tab.launch != nil) else { return }
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
        guard let workspace = store.state.workspace(containing: id), !launches.isBusy(id) else { return }
        if let identity = (workspace.anchor ?? workspace.selectedLocation).checkoutIdentity,
           let existing = store.state.workspaces.first(where: { $0.id != workspace.id && $0.anchor?.checkoutIdentity == identity }) {
            guard window.attachedSheet == nil, store.state.selectedWorkspaceID == workspace.id else {
                store.update { $0.apply(.failure(.failed, TabFailure(.validation, "Checkout is already open. Return to this tab and retry to switch and add a tab."), clearIntent: true), to: id) }
                return
            }
            let alert = NSAlert(); alert.messageText = "Checkout already open"
            alert.informativeText = workspace.selectedLocation.scopePath + "\nOpen in " + existing.title + ". These sessions share the same files."
            alert.addButton(withTitle: "Switch and add tab"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] result in
                guard result == .alertFirstButtonReturn, let self, let draft = self.store.state.tab(id)?.draft else { return }
                guard self.store.state.workspaces.contains(where: { $0.id == existing.id }),
                      !existing.tabs.contains(where: { self.closing.contains($0.id) }) else {
                    self.alert("Checkout workspace changed", "Your draft is retained. Choose the location again."); return
                }
                var target: UUID?
                self.store.update {
                    $0.selectWorkspace(existing.id)
                    target = $0.newTab(startDirectory: workspace.selectedLocation.path)
                    if let target { $0.editDraft(target, tool: draft.tool, prompt: draft.prompt) }
                    if workspace.tabs.count == 1 { $0.closeWorkspace(workspace.id) } else { $0.closeTab(id) }
                }
                if let target { self.launch(target, tool: tool) }
            }
            return
        }
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
        guard !launches.isBusy(id), store.state.tab(id)?.status == .running else { return }
        selectTab(id)
        var newID: UUID?
        store.update { state in newID = state.newTab(); if let newID { state.setSplit(first: id, second: newID) } }
        if let newID { launch(newID, tool: .shell) }
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !installingSplit, let split = splitView, split.arrangedSubviews.count == 2 else { return }
        let extent = split.isVertical ? split.bounds.width : split.bounds.height
        let first = split.isVertical ? split.arrangedSubviews[0].frame.width : split.arrangedSubviews[0].frame.height
        if extent > 0 { store.update(debounced: true) { $0.setSplitFraction(first / extent) } }
    }
    func windowDidResize(_ notification: Notification) { renameEditor?.cancel(); renameEditor = nil;
        updateHeaderGeometry(); rememberWindowFrame()
        if let split = splitView, split.isVertical != (body.bounds.width >= 700) { contentKey = ""; render() }
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
        picker.addItems(withObjectValues: entries.map { $0.title + " · " + $0.directory })
        picker.completes = true; alert.accessoryView = picker
        alert.window.initialFirstResponder = picker
        alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn else { return }
            let index = picker.indexOfSelectedItem
            if entries.indices.contains(index) { self?.store.update { $0.sidebarCollapsed = false; $0.selectWorkspace(entries[index].id) } }
        }
    }
    @objc private func closeSelectedTab() {
        if let id = store.state.selectedTab?.id { closeTabs([id]) }
        else { window.performClose(nil) }
    }
    private func closeWorkspace(_ id: UUID) {
        guard let workspace = store.state.workspaces.first(where: { $0.id == id }) else { return }
        closeTabs(workspace.tabs.map(\.id), workspaceID: id)
    }
    private func closeTabs(_ ids: [UUID], workspaceID: UUID? = nil) {
        if diagnostics != nil && CommandLine.arguments.contains("--workspace-benchmark-continuity") {
            fixtureCloseRequests.append(["time": Date().ISO8601Format(), "tabs": ids.map(\.uuidString).joined(separator: ",")])
            fixtureCloseRequests = Array(fixtureCloseRequests.suffix(32))
        }
        renameEditor?.cancel(); renameEditor = nil
        guard ids.allSatisfy({ id in !closing.contains(id) && !launches.isBusy(id) && !(store.state.workspace(containing: id).map { locations.isBusy(workspaceID: $0.id) } ?? false) }) else { return }
        ids.forEach { closing.insert($0) }
        Task {
            defer { ids.forEach { closing.remove($0) } }
            do {
                try await store.flush()
                for id in ids where store.state.tab(id)?.launch != nil { await launches.reconcile(id) }
                if ids.contains(where: { [.running, .uncertain, .unavailable].contains(store.state.tab($0)?.status) }) {
                    let name = workspaceID.flatMap { id in store.state.workspaces.first { $0.id == id }?.title } ?? ids.first.flatMap { store.state.tab($0)?.title } ?? "session"
                    let liveCount = ids.filter { [.running, .uncertain, .unavailable].contains(store.state.tab($0)?.status) }.count
                    guard await confirm("Close “" + name + "”?", String(liveCount) + (liveCount == 1 ? " session will stop." : " sessions will stop.") + " Files and provider history remain.") else { return }
                }
                for id in ids {
                    try await launches.terminate(id)
                    surfaces.release(id)
                    if workspaceID == nil {
                        store.update { $0.closeTab(id) }
                        if store.state.workspaces.isEmpty { window.close() }
                        try await store.flush()
                    }
                }
                if let workspaceID { store.update { $0.closeWorkspace(workspaceID) }; try await store.flush() }
            } catch { alert("Could not finish closing", error.localizedDescription) }
        }
    }
    private func confirm(_ title: String, _ message: String) async -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        let close = alert.addButton(withTitle: "Close")
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
                    alert.informativeText = "Choose whether your terminal sessions should keep running."
                    alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Keep sessions running and quit")
                    alert.addButton(withTitle: "End sessions and quit").hasDestructiveAction = true
                    let result = await present(alert)
                    if result == .alertFirstButtonReturn { NSApp.reply(toApplicationShouldTerminate: false); return }
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
                else { id = $0.newTab() }
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
            store.update { $0.setFileView(view, workspaceID: id) }
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
        if CommandLine.arguments.contains("--workspace-benchmark-sidebar") {
            guard count == 0 else { throw LaunchError.invalid("Sidebar fixtures start without running sessions.") }
            try await checkSidebar(root: root)
        }
        if CommandLine.arguments.contains("--workspace-benchmark-close") {
            guard count == 0 else { throw LaunchError.invalid("Close fixtures start with one unlaunched tab.") }
            try await WorkspaceCloseFixture.run(window: window, state: { self.store.state }, runtime: launches.runtime,
                view: { self.surfaces.view($0) }, command: { self.handleCommand($0) }, reopen: { self.reopen() },
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
            for index in 0..<40 {
                store.update { $0.selectTab(ids[index % 2]) }
                if let renderTask { await renderTask.value }
            }
            let cycleCount = try WorkspaceBenchmarkOptions.cycleCount()
            for index in 0..<cycleCount {
                let id = ids[index % ids.count]
                store.update { $0.selectTab(id) }
                if let renderTask { await renderTask.value }
                guard surfaces.view(id) != nil else { throw LaunchError.invalid("Benchmark attachment failed.") }
            }
            for binding in observations {
                guard try await launches.runtime.inspect(binding)?.processID == pids[binding.id] else { throw LaunchError.invalid("Benchmark process identity changed.") }
            }
            let id = ids[0]
            store.update { $0.selectTab(id) }; if let renderTask { await renderTask.value }
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
        try PrivateFiles.write(["pid": ProcessInfo.processInfo.processIdentifier, "session_count": Int32(observations.count), "surface_count": Int32(surfaces.count)], to: root.appendingPathComponent("ready.json"))
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
