import AppKit
import Darwin
import SpookkyCore
import SpookkyRuntime
import SpookkyWorkspace
import SpookkyGit

@MainActor final class WorkspaceWindowController: NSObject, NSWindowDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    private(set) var window: NSWindow!
    let store: WorkspaceStore
    let services = AppServices()
    private let locations: LocationCoordinator
    private var repositoryRefreshTask: Task<Void, Never>?
    private var repositorySnapshots: [UUID: RepositorySnapshot] = [:]
    private var repositoryGenerations: [UUID: UUID] = [:]
    private var projectCreation: ProjectCreationController?
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
    private var chromeRevision = ""
    private var sidebarRevision = ""
    private var tabRevision = ""
    private var workspaceRows: [UUID: ContextRow] = [:]
    private var tabPairs: [UUID: ChromeStackView] = [:]
    private var fullscreenTransition = false
    private var announcedError: String?
    private var renameEditor: InlineRenameEditor?
    private var paneHeaders: [UUID: ChromeStackView] = [:]

    init(root: URL, initialStore: WorkspaceStore? = nil, firstUse: Bool = true,
         resolver: any ExecutableResolver = CLIResolver()) throws {
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
        let engine = try GhosttyEngine(root: root)
        launches = LaunchCoordinator(store: store, runtime: runtime, resolver: resolver)
        surfaces = TerminalSurfaceManager(engine: engine, runtime: runtime, executable: tmux, root: root)
        diagnostics = WorkspaceDiagnostics(root: root)
        super.init()
        buildWindow(); buildMenu()
        services.prepareForUpdate = { [weak self] in
            guard let self else { throw LaunchError.invalid("Workspaces are unavailable.") }
            try await self.prepareForUpdate()
        }
        diagnostics?.visibility = { [weak self] in self?.window.occlusionState.contains(.visible) == true }
        store.onChange = { [weak self] in self?.render() }
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
        if firstUse && store.state.workspaces.isEmpty {
            store.update { $0.newWorkspace(directory: FileManager.default.homeDirectoryForCurrentUser.path) }
        }
        if store.state.windowFrame == nil { window.center() }
        window.makeKeyAndOrderFront(nil); rememberWindowFrame(); render()
        Task {
            await locations.reconcileAll()
            await refreshSelectedRepository()
            observeRuntimeEvent()
        }
        runtimeEvents.onChange = { [weak self] in self?.observeRuntimeEvent() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.observeRuntimeEvent() }
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
        observationTask?.cancel()
    }
    private func buildWindow() {
        window = WorkspaceNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Spookky"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
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
        window.isMovableByWindowBackground = true
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
            let item = ClosureMenuItem(tab.title) { [weak self] in self?.selectTab(tab.id) }
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
        let chrome = state.workspaces.map { w in
            w.id.uuidString + w.title + w.directory + (w.anchor?.branch ?? "") + String(describing: w.projectID) + w.selectedTabID.uuidString +
                w.tabs.map { $0.id.uuidString + $0.title + $0.status.rawValue + $0.draft.tool.rawValue }.joined()
        }.joined() + state.projects.map { $0.id.uuidString + $0.name }.joined() + String(describing: state.selectedWorkspaceID) + String(state.sidebarCollapsed) + String(describing: window.effectiveAppearance.name)
        if chrome != chromeRevision {
            chromeRevision = chrome
            window.effectiveAppearance.performAsCurrentDrawingAppearance { renderChrome() }
        }
        for (id, header) in paneHeaders { header.selected = state.selected?.split != nil && state.selectedTab?.id == id }
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
        let sidebarKey = state.projects.map { $0.id.uuidString }.joined() +
            state.workspaces.map { $0.id.uuidString + String(describing: $0.projectID) }.joined() + String(collapsed) + String(describing: window.effectiveAppearance.name)
        if sidebarKey != sidebarRevision {
            renameEditor?.cancel(); renameEditor = nil
            sidebarRevision = sidebarKey; workspaceRows.removeAll(); clear(rail)
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
                    select: { [weak self] in self?.newProjectWorkspace(project.id) },
                    secondary: { [weak self] in self?.newProjectWorkspace(project.id) })
                row.secondary = { [weak self] in
                    let menu = NSMenu()
                    menu.addItem(ClosureMenuItem("Remove project") { self?.store.update { $0.removeProject(project.id) } })
                    return menu
                }
                rail.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: collapsed ? 32 : SpookkyStyle.sidebarWidth - 16).isActive = true
                for w in state.workspaces where w.projectID == project.id { addWorkspaceRow(w, collapsed: collapsed) }
            }
            let unbound = state.workspaces.filter { $0.projectID == nil }
            if !collapsed && !unbound.isEmpty {
                let label = NSTextField(labelWithString: "No project")
                label.textColor = SpookkyPalette.secondary; label.font = .systemFont(ofSize: 11)
                rail.addArrangedSubview(label)
            }
            for workspace in unbound { addWorkspaceRow(workspace, collapsed: collapsed) }
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
            row.metadata?.stringValue = attention.map { SpookkyStyle.statusLabel($0) + " · " + count } ?? context + " · " + count
            row.metadata?.toolTip = workspace.directory + " · " + (attention.map(SpookkyStyle.statusLabel) ?? context) + " · " + count
            row.metadata?.textColor = attention == .failed || attention == .uncertain || attention == .unavailable ? SpookkyPalette.warning : SpookkyPalette.metadata
            let tool = workspace.tabs.first { $0.id == workspace.selectedTabID }.map { $0.binding?.tool ?? $0.draft.tool } ?? .shell
            row.icon?.image = NSImage(systemSymbolName: attention.flatMap(SpookkyStyle.statusSymbol) ?? SpookkyStyle.toolSymbol(tool), accessibilityDescription: nil)
            row.icon?.contentTintColor = attention == .failed || attention == .uncertain || attention == .unavailable ? SpookkyPalette.warning : SpookkyPalette.metadata
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
                    let close = ActionButton("", symbol: "xmark", help: "Close " + tab.title) { [weak self] in self?.closeTabs([tab.id]) }
                    let status = NSImageView(); status.symbolConfiguration = .init(pointSize: 12, weight: .regular)
                    status.widthAnchor.constraint(equalToConstant: 16).isActive = true; status.heightAnchor.constraint(equalToConstant: 16).isActive = true
                    let pair = ChromeStackView(views: [select, status, close]); pair.spacing = 0
                    pair.cornerRadius = 0; pair.drawsTrailingBorder = true
                    select.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).isActive = true
                    pair.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).isActive = true
                    close.widthAnchor.constraint(equalToConstant: SpookkyStyle.compactHeight).isActive = true
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
                let tool = tab.binding?.tool ?? tab.draft.tool
                button.image = NSImage(systemSymbolName: SpookkyStyle.toolSymbol(tool), accessibilityDescription: nil)
                button.toolTip = tab.title + " · " + tool.displayName + " · " + SpookkyStyle.statusLabel(tab.status)
                button.setAccessibilityLabel(button.toolTip!)
                if let status = pair.arrangedSubviews[1] as? NSImageView {
                    let symbol = SpookkyStyle.statusSymbol(tab.status); status.isHidden = symbol == nil
                    status.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                    status.contentTintColor = [.failed, .uncertain, .unavailable].contains(tab.status) ? SpookkyPalette.warning : SpookkyPalette.metadata
                    status.toolTip = SpookkyStyle.statusLabel(tab.status); status.setAccessibilityLabel(SpookkyStyle.statusLabel(tab.status))
                }
                button.contentTintColor = tab.id == workspace.selectedTabID ? SpookkyPalette.text : SpookkyPalette.secondary
                pair.selected = tab.id == workspace.selectedTabID
                if let close = pair.arrangedSubviews.last as? ActionButton { close.setAccessibilityLabel("Close " + tab.title); close.toolTip = "Close " + tab.title }
                if tab.id == workspace.selectedTabID { DispatchQueue.main.async { pair.scrollToVisible(pair.bounds) } }
            }
        }
    }
    private func contextRow(title: String, symbol: String, secondarySymbol: String, help: String, selected: Bool, nested: Bool = false,
                            monogram: String? = nil, select: @escaping () -> Void, secondary: @escaping () -> Void) -> ContextRow {
        let row = ContextRow(); row.translatesAutoresizingMaskIntoConstraints = false
        let collapsed = store.state.sidebarCollapsed
        let primary = ActionButton(title, symbol: collapsed ? symbol : nil, help: help, action: select)
        if collapsed, let monogram { primary.image = SpookkyStyle.monogram(monogram) }
        primary.contentInset = collapsed ? SpookkyStyle.controlInset : 0
        primary.drawsInteractionFill = false
        row.primary = primary
        primary.onContextMenu = { [weak row] in row?.secondary?() }
        primary.onNavigate = { [weak self, weak primary] key in
            guard let self, let primary else { return }
            let controls = self.rail.arrangedSubviews.compactMap { ($0 as? ContextRow)?.primary }
            guard let index = controls.firstIndex(where: { $0 === primary }), !controls.isEmpty else { return }
            let offset = key == 123 || key == 126 ? -1 : 1
            let target = controls[(index + offset + controls.count) % controls.count]
            target.scrollToVisible(target.bounds); self.window.makeFirstResponder(target)
        }
        primary.alignment = .left; primary.lineBreakMode = .byTruncatingTail
        let action = ActionButton("", symbol: secondarySymbol, help: secondarySymbol == "plus" ? "New workspace for " + title : "Close " + title, action: secondary)
        row.secondaryButton = action
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
    private func addWorkspaceRow(_ workspace: Workspace, collapsed: Bool) {
        let row = contextRow(title: collapsed ? "" : workspace.title, symbol: "terminal", secondarySymbol: "xmark",
            help: workspace.title + " · " + workspace.directory, selected: workspace.id == store.state.selectedWorkspaceID, nested: workspace.projectID != nil,
            select: { [weak self] in self?.selectWorkspace(workspace.id) },
            secondary: { [weak self] in self?.closeWorkspace(workspace.id) })
        row.primary?.onDoubleClick = { [weak self] in self?.rename(workspaceID: workspace.id) }
        row.secondary = { [weak self] in
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Rename workspace…") { self?.rename(workspaceID: workspace.id) })
            menu.addItem(ClosureMenuItem("Close workspace") { self?.closeWorkspace(workspace.id) })
            if let record = self?.store.state.locations?.checkouts.first(where: { $0.location.checkoutIdentity == (workspace.anchor ?? workspace.selectedLocation).checkoutIdentity }), record.createdBy != nil {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Delete worktree…") { self?.deleteWorktree(record) })
            }
            return menu
        }
        rail.addArrangedSubview(row)
        workspaceRows[workspace.id] = row
        row.widthAnchor.constraint(equalToConstant: collapsed ? 32 : SpookkyStyle.sidebarWidth - 16).isActive = true
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
            body.subviews.forEach { $0.removeFromSuperview() }; splitView = nil; paneHeaders.removeAll()
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
            var headerViews: [NSView] = [title, NSView(), split]
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
    }
    private func selectTab(_ id: UUID) {
        renameEditor?.cancel(); renameEditor = nil
        files.revealTerminal()
        if store.state.selectedTab?.id == id { focusSelectedContent() }
        else { store.update { $0.selectTab(id) } }
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
    @objc private func focusSidebar() { if let button = workspaceRows[store.state.selectedWorkspaceID ?? UUID()]?.primary { window.makeFirstResponder(button) } }
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
        if !window.isVisible { window.makeKeyAndOrderFront(nil); contentKey = "" }
        store.update { $0.newWorkspace(directory: FileManager.default.homeDirectoryForCurrentUser.path) }
    }
    private func addBlankTab() { files.revealTerminal(); if store.state.selected == nil { newWorkspace() } else { store.update { $0.newTab() } } }
    @objc private func newTab() {
        files.revealTerminal()
        if !window.isVisible { reopen() }
        if store.state.selected == nil { newWorkspace() }
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
        Task { await launches.launch(id, tool: tool) }
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
    func windowWillEnterFullScreen(_ notification: Notification) { fullscreenTransition = true }
    func windowDidEnterFullScreen(_ notification: Notification) { fullscreenTransition = false; updateHeaderGeometry() }
    func windowWillExitFullScreen(_ notification: Notification) { fullscreenTransition = true }
    func windowDidExitFullScreen(_ notification: Notification) { fullscreenTransition = false; updateHeaderGeometry(); rememberWindowFrame() }
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
        let text = operations.suffix(10).map {
            $0.request.kind.rawValue + " · " + $0.status.rawValue + "\n" + $0.request.destination + "\n" + ($0.error ?? $0.receipts.last?.phase.rawValue ?? "intent")
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
        let button = tabID.flatMap { tabPairs[$0]?.arrangedSubviews.first as? ActionButton } ?? workspaceID.flatMap { workspaceRows[$0]?.primary }
        guard let button else { return }
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
            if entries.indices.contains(index) { self?.store.update { $0.selectWorkspace(entries[index].id) } }
        }
    }
    @objc private func closeSelectedTab() { if let id = store.state.selectedTab?.id { closeTabs([id]) } }
    private func closeWorkspace(_ id: UUID) {
        guard let workspace = store.state.workspaces.first(where: { $0.id == id }) else { return }
        closeTabs(workspace.tabs.map(\.id), workspaceID: id)
    }
    private func closeTabs(_ ids: [UUID], workspaceID: UUID? = nil) {
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
                    if workspaceID == nil { store.update { $0.closeTab(id) }; try await store.flush() }
                }
                if let workspaceID { store.update { $0.closeWorkspace(workspaceID) }; try await store.flush() }
            } catch { alert("Could not finish closing", error.localizedDescription) }
        }
    }
    private func confirm(_ title: String, _ message: String) async -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "Close").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
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
        if CommandLine.arguments.contains("--workspace-benchmark-count") && !CommandLine.arguments.contains("--workspace-benchmark-front") { window.orderBack(nil) }
        else { window.makeKeyAndOrderFront(nil) }
        contentKey = ""; render(); observeRuntimeEvent() }
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
            try await surfaces.scrollFixtureHistory(id, offset: CommandLine.arguments.contains("--workspace-benchmark-resize") ? 80 : 25)
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
        for id in ids {
            guard let binding = store.state.tab(id)?.binding,
                  let observed = try await launches.runtime.inspect(binding) else { throw LaunchError.invalid("Fixture session is unavailable") }
            identities[id] = observed.processID
        }
        try PrivateFiles.write(ids.map { ["id": $0.uuidString, "pid": String(identities[$0]!)] }, to: root.appendingPathComponent("baseline-identities.json"))
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
            try await launches.terminate(pair); surfaces.release(pair)
            store.update { $0.closeTab(pair) }
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
            let diagnostics = files.diagnostics
            guard let residentMiB = WorkspaceDiagnostics.residentMiB() else { throw LaunchError.invalid("Fixture RSS could not be measured") }
            let remaining = try await launches.runtime.list().count
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
                "resizeTaskHandles": surfaces.resizeTaskCount, "reconciliationTaskHandles": observationTask == nil ? 0 : 1,
                "renderTaskHandles": renderTask == nil ? 0 : 1], uniquingKeysWith: { _, new in new }))
            try PrivateFiles.write(checkpoints, to: root.appendingPathComponent("continuity-checkpoints.json"))
            guard surfaces.count <= 3 else { throw LaunchError.invalid("Continuity surface budget exceeded") }
            tick += 1
            try await Task.sleep(for: .seconds(min(15, seconds)))
        }
        try await launches.terminate(outputID); surfaces.release(outputID)
        store.update { $0.closeTab(outputID); $0.selectTab(ids[0]) }
        if let renderTask { await renderTask.value }
        try await store.flush()
        try PrivateFiles.write(["same_processes": 1, "draft_preserved": 1, "cycles": cycles.count,
            "checkpoints": checkpoints.count, "elapsedSeconds": Int(started.duration(to: .now).components.seconds)] as [String: Int], to: root.appendingPathComponent("continuity-result.json"))
    }

}
