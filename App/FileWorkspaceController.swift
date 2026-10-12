import AppKit
import SpookkyCore
import SpookkyFiles
import SpookkyGit
import SpookkyWorkspace
import SpookkySyntax

@MainActor final class FileWorkspaceController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let sidebar = NSView(), preview = NSView()
    let layout: FileWorkspaceLayout
    private let store: WorkspaceStore
    private let service = FileService()
    private let changes = GitChanges()
    private let syntax = SyntaxHighlighter()
    private var syntaxTask: Task<Void, Never>?
    private var oldSyntax: SyntaxDocument?, newSyntax: SyntaxDocument?
    private var previewInformation = ""
    private var syntaxReadyMilliseconds: Double?
    private var syntaxCacheBytes = 0
    private let watcher = WorkspaceFileWatcher()
    private let fileTable = FileTable(), diffTable = FileTable()
    private let fileScroll = NSScrollView(), diffScroll = NSScrollView()
    private let search = NSSearchField()
    private let filesMode = ActionButton("Files", symbol: "doc", help: "Show files", action: {})
    private let changesMode = ActionButton("Changes", symbol: "arrow.triangle.branch", help: "Show changes", action: {})
    private let comparison = NSPopUpButton(), reference = NSPopUpButton(), stage = NSPopUpButton()
    private let scope = NSTextField(labelWithString: ""), status = NSTextField(wrappingLabelWithString: ""), title = NSTextField(labelWithString: "")
    private let previewNotice = NSTextField(wrappingLabelWithString: "")
    private let informationButton = ActionButton("", symbol: "info.circle", help: "Preview information", action: {})
    private let informationPopover = NSPopover()
    private var secondaryPreviewActions: [ActionButton] = []
    private weak var inspectionControls: NSStackView?
    private weak var layoutControls: NSStackView?
    private let contextButton = ActionButton("", symbol: "arrow.up.and.down", help: "Show more context", action: {})
    private let layoutButton = ActionButton("", symbol: "rectangle.split.2x1", help: "Split diff", action: {})
    private let unifiedButton = ActionButton("", symbol: "rectangle.grid.1x2", help: "Unified diff", action: {})
    private let previewOverflow = ActionButton("", symbol: "ellipsis", help: "More preview actions", action: {})
    private let oldCaption = NSTextField(labelWithString: ""), newCaption = NSTextField(labelWithString: "")
    private let comparisonCaptions = NSStackView()
    private var workspaceID: UUID?, root = "", identity = "", state = FileViewState()
    private var directories: [String: [FileEntry]] = [:]
    private var rows: [(FileEntry?, ChangedFile?, String)] = []
    private var snapshot: ChangesSnapshot?
    private var diff: [DiffLine] = []
    private var displayRows: [(DiffLine?, DiffLine?)] = []
    private var loadTask: Task<Void, Never>?, previewTask: Task<Void, Never>?
    private var generation = UUID(), previewGeneration = UUID()
    private var splitRendered = false, rendering = false, context = 3
    private var previewWidth: CGFloat = 0
    private var diffNumberWidth: CGFloat = 28, diffTextWidth: CGFloat = 100
    private var isDiff: Bool { selectedFile != nil && selectedFile?.group != .untracked && selectedFile?.group != .conflicts }
    private var lastOperation: UUID?
    private var wasNarrow: Bool?
    private var activation: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    private var onFocusTerminal: () -> Void
    private var selectedFile: ChangedFile?
    private var lastPreviewKey = ""
    private var displaySelectionKey = ""
    private(set) var previewTimings: [String: Double] = [:]
    var diagnostics: [String: Int] { ["rows": rows.count, "diffRows": diff.count, "watchers": watcher.isWatching ? 1 : 0,
        "previewBytes": diff.reduce(0) { $0 + $1.text.utf8.count * 2 + 128 } + (oldSyntax?.cost ?? 0) + (newSyntax?.cost ?? 0) + syntaxCacheBytes, "syntaxTaskHandles": syntaxTask == nil ? 0 : 1, "metadataBytes": metadataCost, "fileTaskHandles": (loadTask == nil ? 0 : 1) + (previewTask == nil ? 0 : 1)] }
    private var metadataCost: Int { directories.values.reduce(0) { total, entries in
        entries.reduce(total) { $0 + $1.path.utf8.count * 2 + 256 }
    } + rows.reduce(0) { $0 + $1.2.utf8.count * 2 + 512 } }

    init(store: WorkspaceStore, terminal: NSView, focusTerminal: @escaping () -> Void) {
        self.store = store; self.onFocusTerminal = focusTerminal
        layout = FileWorkspaceLayout(terminal: terminal, sidebar: sidebar, preview: preview)
        super.init(); build()
        watcher.onChange = { [weak self] in self?.refresh() }
        layout.onResize = { [weak self] fraction in self?.edit { $0.fraction = fraction } }
        layout.onPreviewWidth = { [weak self] width in
            guard let self else { return }
            let changedWidth = abs(previewWidth - width) > 0.5
            previewWidth = width
            updatePreviewControls()
            if splitRendered != (state.splitDiff && isDiff && width >= 600) { renderDiff() }
            else if changedWidth {
                sizeDiffColumns()
                if splitRendered {
                    let splitX = diffTable.rect(ofColumn: 3).minX
                    diffTable.enumerateAvailableRowViews { row, _ in
                        (row as? WorkspaceTableRow)?.splitX = splitX
                        row.needsDisplay = true
                    }
                }
            }
        }
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        diffScroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: diffScroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.rendering else { return }
                let row = max(0, Double(self.diffScroll.contentView.bounds.origin.y / self.diffTable.rowHeight))
                if abs(self.state.scroll - row) >= 1 { self.edit { $0.scroll = row } }
            }
        }
    }
    deinit { loadTask?.cancel(); previewTask?.cancel(); syntaxTask?.cancel(); if let activation { NotificationCenter.default.removeObserver(activation) }; if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
    private func build() {
        [sidebar, preview].forEach { $0.wantsLayer = true }
        filesMode.handler = { [weak self] in self?.changeMode(changes: false) }
        changesMode.handler = { [weak self] in self?.changeMode(changes: true) }
        let modeTabs = NSStackView(views: [filesMode, changesMode]); modeTabs.spacing = 4; modeTabs.distribution = .fillEqually
        modeTabs.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).isActive = true
        for control in [comparison, reference, stage, search] { SpookkyStyle.configure(control) }
        comparison.addItems(withTitles: ["Uncommitted", "Against branch"]); comparison.target = self; comparison.action = #selector(changeComparison)
        comparison.setAccessibilityLabel("Comparison scope")
        reference.target = self; reference.action = #selector(changeReference); reference.setAccessibilityLabel("Comparison branch")
        search.placeholderString = "Search files"; search.delegate = self; search.setAccessibilityLabel("Search workspace files")
        scope.font = .systemFont(ofSize: 11); scope.textColor = SpookkyPalette.metadata; scope.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11); status.textColor = SpookkyPalette.secondary; status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let scopeRow = NSStackView(views: [scope, NSView(), status]); scopeRow.spacing = 8
        scopeRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        let refreshButton = ActionButton("", symbol: "arrow.clockwise", help: "Refresh files and changes") { [weak self] in self?.refresh() }
        let tools = NSStackView(views: [search, refreshButton]); tools.spacing = 4
        refreshButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileTable.style = .plain; fileTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        fileTable.headerView = nil; fileTable.rowHeight = SpookkyStyle.controlHeight; fileTable.intercellSpacing = .zero
        fileTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
        fileTable.tableColumns[0].resizingMask = .autoresizingMask
        fileTable.dataSource = self; fileTable.delegate = self; fileTable.target = self; fileTable.action = #selector(selectRow)
        fileTable.setAccessibilityLabel("Workspace files")
        fileTable.onMenu = { [weak self] index in
            guard let self, index >= 0, index < rows.count else { return nil }
            let row = rows[index]
            guard row.0 != nil || row.1 != nil, row.1?.supported != false else { return nil }
            let url = URL(fileURLWithPath: root).appendingPathComponent(row.2), menu = NSMenu()
            menu.addItem(ClosureMenuItem("Open With…") { [weak self] in self?.openWith(url) })
            menu.addItem(ClosureMenuItem("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            return menu
        }
        fileTable.onKey = { [weak self] event in
            guard let self else { return false }
            if event.keyCode == 36 || event.keyCode == 124 { selectRow(); return true }
            if event.keyCode == 53 { onFocusTerminal(); return true }
            if event.keyCode == 123, fileTable.selectedRow >= 0, fileTable.selectedRow < rows.count, let entry = rows[fileTable.selectedRow].0 {
                edit { $0.expanded.removeAll { $0 == entry.path } }; refresh(); return true
            }
            return false
        }
        fileScroll.documentView = fileTable; fileScroll.hasVerticalScroller = true; fileScroll.autohidesScrollers = true
        let sideStack = NSStackView(views: [modeTabs, scopeRow, comparison, reference, tools, fileScroll])
        sideStack.orientation = .vertical; sideStack.alignment = .centerX; sideStack.spacing = 4
        sideStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        pin(sideStack, to: sidebar)
        for view in [modeTabs, scopeRow, comparison, reference, tools] { view.widthAnchor.constraint(equalTo: sideStack.widthAnchor, constant: -16).isActive = true }
        fileScroll.widthAnchor.constraint(equalTo: sideStack.widthAnchor).isActive = true
        fileScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        fileScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        title.font = .systemFont(ofSize: 12, weight: .medium); title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        layoutButton.handler = { [weak self] in self?.edit { $0.splitDiff = true }; self?.renderDiff() }
        unifiedButton.handler = { [weak self] in self?.edit { $0.splitDiff = false }; self?.renderDiff() }
        let open = ActionButton("", symbol: "arrow.up.forward.square", help: "Open With…") { [weak self] in self?.openWith() }
        let reveal = ActionButton("", symbol: "folder", help: "Reveal in Finder") { [weak self] in self?.reveal() }
        secondaryPreviewActions = [open, reveal]
        let previewMenu = { [weak self] () -> NSMenu in
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Open With…") { self?.openWith() })
            menu.addItem(ClosureMenuItem("Reveal in Finder") { self?.reveal() })
            if let self, self.isDiff {
                menu.addItem(.separator())
                let unified = ClosureMenuItem("Unified diff") { [weak self] in self?.unifiedButton.handler?() }
                let split = ClosureMenuItem("Split diff") { [weak self] in self?.layoutButton.handler?() }
                unified.state = self.state.splitDiff ? .off : .on; split.state = self.state.splitDiff ? .on : .off
                menu.addItem(unified); menu.addItem(split)
                menu.addItem(ClosureMenuItem(self.context == 3 ? "Show more context" : "Hide surrounding context") { [weak self] in self?.contextButton.handler?() })
            }
            if self?.previewInformation.isEmpty == false { menu.addItem(ClosureMenuItem("Preview information…") { self?.informationButton.handler?() }) }
            return menu
        }
        title.menu = previewMenu(); preview.menu = previewMenu()
        previewOverflow.handler = { [weak self] in
            guard let self else { return }; previewMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: previewOverflow.bounds.height), in: previewOverflow)
        }
        previewOverflow.isHidden = true
        diffTable.onMenu = { _ in previewMenu() }
        let maximize = ActionButton("", symbol: "arrow.up.left.and.arrow.down.right", help: "Maximize or restore preview") { [weak self] in self?.edit { $0.maximized.toggle() } }
        let close = ActionButton("", symbol: "xmark", help: "Close file preview") { [weak self] in self?.closePreview() }
        for button in [informationButton, contextButton, unifiedButton, layoutButton, open, reveal, previewOverflow, maximize, close] { button.widthAnchor.constraint(equalToConstant: 28).isActive = true }
        let inspection = NSStackView(views: [informationButton, contextButton]); inspection.spacing = 4; inspectionControls = inspection
        let layouts = NSStackView(views: [unifiedButton, layoutButton]); layouts.spacing = 0; layoutControls = layouts
        let external = NSStackView(views: [open, reveal, previewOverflow]); external.spacing = 4
        let panes = NSStackView(views: [maximize, close]); panes.spacing = 4
        let header = NSStackView(views: [title, NSView(), inspection, layouts, external, panes]); header.spacing = 8
        comparisonCaptions.addArrangedSubview(oldCaption); comparisonCaptions.addArrangedSubview(newCaption)
        comparisonCaptions.distribution = .fillEqually; comparisonCaptions.spacing = 8
        comparisonCaptions.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        for caption in [oldCaption, newCaption] { caption.font = .systemFont(ofSize: 11); caption.textColor = SpookkyPalette.metadata; caption.lineBreakMode = .byTruncatingMiddle }
        comparisonCaptions.heightAnchor.constraint(equalToConstant: 24).isActive = true
        informationButton.isHidden = true
        informationButton.handler = { [weak self] in
            guard let self else { return }
            let text = NSTextField(wrappingLabelWithString: previewInformation)
            text.font = .systemFont(ofSize: 12)
            let height = max(32, ceil((previewInformation as NSString).boundingRect(with: NSSize(width: 256, height: 600), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: text.font!]).height) + 8)
            text.frame = NSRect(x: 12, y: 12, width: 256, height: height)
            let controller = NSViewController(); controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: height + 24)); controller.view.addSubview(text)
            informationPopover.contentViewController = controller; informationPopover.behavior = .transient
            let anchor = informationButton.isHidden ? previewOverflow : informationButton
            informationPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        title.textColor = SpookkyPalette.text
        header.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).isActive = true
        contextButton.handler = { [weak self] in guard let self else { return }; context = context == 3 ? 20_000 : 3; openSelection() }
        stage.addItems(withTitles: ["Working file", "Base", "Ours", "Theirs"]); stage.target = self; stage.action = #selector(changeStage)
        stage.setAccessibilityLabel("Conflict content")
        previewNotice.font = .systemFont(ofSize: 11); previewNotice.textColor = SpookkyPalette.secondary
        diffTable.style = .plain; diffTable.columnAutoresizingStyle = .noColumnAutoresizing
        diffTable.headerView = nil; diffTable.rowHeight = 18; diffTable.intercellSpacing = .zero; diffTable.allowsMultipleSelection = true
        diffTable.dataSource = self; diffTable.delegate = self; diffTable.setAccessibilityLabel("File content and diff")
        diffTable.copyText = { [weak self] in
            guard let self else { return "" }
            return diffTable.selectedRowIndexes.compactMap { index -> String? in
                guard index < self.displayRows.count else { return nil }
                let pair = self.displayRows[index]; return [pair.0?.text, pair.1?.text].compactMap { $0 }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
        diffTable.onKey = { [weak self] event in if event.keyCode == 53 { self?.closePreview(); return true }; return false }
        diffScroll.documentView = diffTable; diffScroll.hasVerticalScroller = true; diffScroll.hasHorizontalScroller = true; diffScroll.autohidesScrollers = true
        let stack = NSStackView(views: [header, comparisonCaptions, stage, previewNotice, diffScroll]); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0); pin(stack, to: preview)
        [header, previewNotice].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true }
        stage.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        comparisonCaptions.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        diffScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        diffScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        diffScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    private func visibleNotice(_ notice: String?) -> String? {
        notice?.components(separatedBy: "\n").filter { !$0.hasPrefix("External Git content filters are disabled") }.joined(separator: "\n")
    }
    private func pin(_ view: NSView, to parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: parent.leadingAnchor), view.trailingAnchor.constraint(equalTo: parent.trailingAnchor), view.topAnchor.constraint(equalTo: parent.topAnchor), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)])
    }
    private func edit(_ body: (inout FileViewState) -> Void) {
        guard let id = workspaceID else { return }; var next = state; body(&next)
        store.update(debounced: true) { $0.setFileView(next, workspaceID: id) }
    }
    var hasFocus: Bool {
        guard let view = layout.window?.firstResponder as? NSView else { return false }
        if view === search.currentEditor() { return true }
        return view.isDescendant(of: sidebar) || view.isDescendant(of: preview) || view === layout.divider
    }
    func revealTerminal() {
        let narrow = (layout.window?.frame.width ?? 0) < 800
        let hidden = layout.terminal.isHidden, fileFocused = hasFocus
        if hidden || (narrow && state.sidebar) {
            edit { if hidden { $0.preview = false; $0.maximized = false }; if narrow { $0.sidebar = false } }
        }
        if hidden || fileFocused { layout.window?.makeFirstResponder(nil) }
    }
    func focusSidebar() {
        if !state.sidebar { edit { $0.sidebar = true } }
        layout.window?.makeFirstResponder(search)
    }
    func toggle() { edit { $0.sidebar.toggle() } }
    func suspend() { watcher.stop(); loadTask?.cancel(); previewTask?.cancel(); releaseSyntax(); clearSyntaxCache() }
    func update(_ workspace: Workspace?, operation: UUID?) {
        var next = workspace?.fileView ?? FileViewState()
        let narrow = (layout.window?.frame.width ?? 1_000) < 800
        let enteringNarrow = narrow && (wasNarrow != true || workspaceID != workspace?.id)
        wasNarrow = narrow
        if enteringNarrow && next.sidebar && next.preview, let workspace {
            next.sidebar = false
            let view = next
            store.update(debounced: true) { $0.setFileView(view, workspaceID: workspace.id) }
        }
        let location = workspace?.anchor ?? workspace?.selectedLocation
        let pending = workspace?.anchor == nil && workspace?.locationDraft?.mode == .worktree
        let nextRoot = pending ? "" : location?.scopePath ?? ""
        let switched = workspaceID != workspace?.id || nextRoot != root
        let visibilityChanged = next.sidebar != state.sidebar || next.preview != state.preview
        let operationChanged = operation != lastOperation
        workspaceID = workspace?.id; root = nextRoot; identity = location?.checkoutIdentity ?? ""; state = next; lastOperation = operation
        layout.showSidebar = state.sidebar; layout.showPreview = state.preview; layout.maximized = state.maximized; layout.fraction = state.fraction; layout.needsLayout = true
        layout.effectiveAppearance.performAsCurrentDrawingAppearance {
            sidebar.layer?.backgroundColor = SpookkyPalette.sidebar.cgColor; preview.layer?.backgroundColor = SpookkyPalette.background.cgColor
            sidebar.layer?.borderColor = SpookkyPalette.border.cgColor; sidebar.layer?.borderWidth = 1
            fileTable.backgroundColor = SpookkyPalette.sidebar; diffTable.backgroundColor = SpookkyPalette.background
            fileScroll.backgroundColor = SpookkyPalette.sidebar; diffScroll.backgroundColor = SpookkyPalette.background
        }
        filesMode.selected = !state.changes; changesMode.selected = state.changes
        filesMode.contentTintColor = state.changes ? SpookkyPalette.secondary : SpookkyPalette.text
        changesMode.contentTintColor = state.changes ? SpookkyPalette.text : SpookkyPalette.secondary
        filesMode.setAccessibilityValue(state.changes ? "" : "Selected")
        changesMode.setAccessibilityValue(state.changes ? "Selected" : "")
        comparison.selectItem(at: state.againstBranch ? 1 : 0)
        comparison.isHidden = !state.changes || identity.isEmpty; reference.isHidden = comparison.isHidden || !state.againstBranch
        scope.stringValue = pending ? "Worktree not created" : (root == FileManager.default.homeDirectoryForCurrentUser.path ? "Home" : URL(fileURLWithPath: root).lastPathComponent)
        scope.toolTip = pending ? "Create the worktree to browse its files" : root
        scope.setAccessibilityLabel("Workspace scope · " + (pending ? "Worktree not created" : root))
        if search.stringValue != state.query { search.stringValue = state.query }
        if switched {
            loadTask?.cancel(); previewTask?.cancel(); releaseSyntax(); clearSyntaxCache(); generation = UUID(); previewGeneration = UUID()
            directories.removeAll(); rows.removeAll(); diff.removeAll(); snapshot = nil; selectedFile = nil; lastPreviewKey = ""; reference.removeAllItems()
            setStatus("")
            fileTable.reloadData(); renderDiff(); context = 3; stage.selectItem(at: 0)
        }
        if state.sidebar || state.preview, !root.isEmpty, layout.window?.isVisible == true {
            watcher.watch(Array(Set([root, location?.checkoutIdentity, location?.commonRepository].compactMap { $0 })).sorted())
            if switched || visibilityChanged || operationChanged { refresh() }
        } else { suspend(); if pending { setStatus("Files will appear after worktree creation.") } }
    }
    private func setStatus(_ text: String) { status.isHidden = text.isEmpty; status.stringValue = text; status.toolTip = text; status.setAccessibilityValue(text) }
    func refresh(refreshPreview: Bool = true) {
        guard !root.isEmpty, state.sidebar || state.preview, layout.window?.isVisible == true else { return }
        loadTask?.cancel(); if refreshPreview { previewTask?.cancel(); syntaxTask?.cancel(); previewGeneration = UUID() }
        let focusedRow = fileTable.selectedRow
        let focusedPath = focusedRow >= 0 && focusedRow < rows.count ? rows[focusedRow].2 : state.selectedPath
        generation = UUID(); let token = generation, root = root, id = workspaceID, view = state
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                var metadataLimited = false
                if view.changes {
                    guard !identity.isEmpty else { rows = []; snapshot = nil; fileTable.reloadData(); setStatus("This folder has no Git repository."); if state.preview && refreshPreview { openSelection() }; return }
                    if refreshPreview || reference.numberOfItems == 0 {
                        let repository = try await changes.git.referenceSnapshot(root)
                        guard token == generation, id == workspaceID, !Task.isCancelled else { return }
                        let previous = reference.itemArray.dropFirst().compactMap { $0.representedObject as? String }
                        if previous != repository.references.map(\.qualifiedName) || reference.numberOfItems == 0 {
                            reference.removeAllItems(); reference.addItem(withTitle: "Choose branch…")
                            for ref in repository.references { reference.addItem(withTitle: ref.name); reference.lastItem?.representedObject = ref.qualifiedName }
                        }
                        if state.reference == nil, repository.defaultSource != "HEAD" {
                            if let item = reference.itemArray.first(where: { $0.title == repository.defaultSource }) { edit { $0.reference = item.representedObject as? String } }
                        }
                    }
                    if let ref = state.reference, let item = reference.itemArray.first(where: { $0.representedObject as? String == ref }) { reference.select(item) }
                    if view.againstBranch && state.reference == nil { rows = []; snapshot = nil; fileTable.reloadData(); if state.preview && refreshPreview { openSelection() }; setStatus(reference.numberOfItems <= 1 ? "No comparison branches are available yet. Use Uncommitted." : "Choose a branch for committed changes."); return }
                    let result = try await changes.snapshot(root: root, reference: view.againstBranch ? state.reference : nil)
                    guard token == generation, id == workspaceID, !Task.isCancelled else { return }
                    snapshot = result; rows = []
                    var cost = 0
                    for group in ChangeGroup.allCases {
                        let values = result.files.filter { $0.group == group && (view.query.isEmpty || $0.path.localizedCaseInsensitiveContains(view.query)) }
                        if !values.isEmpty { rows.append((nil, nil, "\(group.rawValue) · \(values.count)")) }
                        for file in values {
                            cost += file.path.utf8.count * 2 + 512
                            if cost > FileService.metadataBytes / 2 { metadataLimited = true; break }
                            rows.append((nil, file, file.path))
                        }
                        if metadataLimited { break }
                    }
                    let label = result.base.map { "Merge base \($0.prefix(8)) → \(result.head?.prefix(8) ?? "")" } ?? ""
                    setStatus([metadataLimited ? "List limited. Narrow your search." : rows.isEmpty ? "No changes" : label, visibleNotice(result.notice)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
                } else {
                    snapshot = nil; directories.removeAll()
                    if !view.query.isEmpty {
                        let listing = try await service.search(root: root, query: view.query)
                        guard token == generation, !Task.isCancelled else { return }
                        rows = listing.entries.map { ($0, nil, $0.path) }; metadataLimited = listing.incomplete
                    } else {
                        for path in [""] + view.expanded.sorted() {
                            if !path.isEmpty {
                                let parent = (path as NSString).deletingLastPathComponent
                                guard directories[parent]?.contains(where: { $0.path == path && $0.kind == .directory }) == true else { continue }
                            }
                            do {
                                let listing = try await service.list(root: root, path: path)
                                guard token == generation, !Task.isCancelled else { return }
                                let cost = listing.entries.reduce(0) { $0 + $1.path.utf8.count * 2 + 256 }
                                if metadataCost + cost > FileService.metadataBytes / 2 { metadataLimited = true; break }
                                directories[path] = listing.entries; metadataLimited = metadataLimited || listing.incomplete
                            } catch is CancellationError { throw CancellationError() } catch { if path.isEmpty { throw error } }
                        }
                        rows = []
                        @MainActor func append(_ path: String) {
                            for entry in directories[path] ?? [] {
                                rows.append((entry, nil, entry.path))
                                if entry.kind == .directory && view.expanded.contains(entry.path) { append(entry.path) }
                            }
                        }
                        append("")
                    }
                    setStatus(metadataLimited ? "Incomplete results. Narrow your search or open a smaller folder." : "")
                }
                guard token == generation, id == workspaceID, !Task.isCancelled else { return }
                fileTable.reloadData()
                if let path = focusedPath, let index = rows.firstIndex(where: { $0.2 == path && ($0.1?.group.rawValue == self.state.selectedGroup || self.state.selectedGroup == nil) }) { fileTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
                if state.preview && refreshPreview { openSelection() }
            } catch is CancellationError {} catch { if token == generation { setStatus(error.localizedDescription) } }
        }
    }
    private func changeMode(changes: Bool) { edit { $0.changes = changes; $0.query = ""; if !$0.changes { $0.selectedGroup = nil } }; refresh() }
    @objc private func changeComparison() { edit { $0.againstBranch = comparison.indexOfSelectedItem == 1 }; refresh() }
    @objc private func changeReference() { edit { $0.reference = reference.selectedItem?.representedObject as? String }; refresh() }
    @objc private func changeStage() { openSelection() }
    func controlTextDidChange(_ notification: Notification) {
        edit { $0.query = String(search.stringValue.prefix(1_000)) }; refresh(refreshPreview: false)
    }
    @objc private func selectRow() {
        let index = fileTable.selectedRow
        guard index >= 0, index < rows.count else { return }
        let row = rows[index]
        if let entry = row.0, entry.kind == .directory {
            edit { if $0.expanded.contains(entry.path) { $0.expanded.removeAll { $0 == entry.path } } else if $0.expanded.count < 1_000 { $0.expanded.append(entry.path) } }; refresh(refreshPreview: false); return
        }
        guard row.0 != nil || row.1 != nil else { return }
        if row.1?.supported == false { setStatus("Unsupported filename. Inspect it in Terminal."); return }
        stage.selectItem(at: 0); context = 3
        edit { $0.selectedPath = row.2; $0.selectedGroup = row.1?.group.rawValue; $0.preview = true; $0.scroll = 0
            if (layout.window?.frame.width ?? 0) < 800 { $0.sidebar = false }
        }
        openSelection()
        if (layout.window?.frame.width ?? 0) < 800 { layout.window?.makeFirstResponder(diffTable) }
    }
    private func closePreview() { edit { $0.preview = false; $0.maximized = false }; previewTask?.cancel(); releaseSyntax(); clearSyntaxCache(); onFocusTerminal() }
    private func openSelection() {
        guard state.preview, let path = state.selectedPath, !root.isEmpty else { return }
        let contextLabel = context == 3 ? "Show more context" : "Hide surrounding context"
        contextButton.image = NSImage(systemSymbolName: context == 3 ? "arrow.up.and.down" : "arrow.down.to.line", accessibilityDescription: nil)
        contextButton.toolTip = contextLabel; contextButton.setAccessibilityLabel(contextLabel)
        previewTask?.cancel(); syntaxTask?.cancel(); previewGeneration = UUID()
        let token = previewGeneration, root = root, selectedGroup = state.selectedGroup, stageIndex = stage.indexOfSelectedItem, snapshot = snapshot
        let file = state.changes ? snapshot?.files.first {
            $0.path == path && (selectedGroup == nil || $0.group.rawValue == selectedGroup)
        } : nil
        if selectedGroup != nil && file == nil {
            selectedFile = nil; diff = []; renderDiff(); title.stringValue = path
            stage.isHidden = true; layoutButton.isHidden = true; unifiedButton.isHidden = true; contextButton.isHidden = true; comparisonCaptions.isHidden = true
            previewNotice.isHidden = false; previewNotice.stringValue = "This change is no longer available in the selected comparison."; return
        }
        selectedFile = file; title.stringValue = path; title.toolTip = path
        stage.isHidden = file?.group != .conflicts
        layoutButton.isHidden = !isDiff; unifiedButton.isHidden = !isDiff
        contextButton.isHidden = layoutButton.isHidden
        let key = root + ":" + path + ":" + (file?.group.rawValue ?? "") + ":\(stageIndex)"
        if key != lastPreviewKey {
            informationPopover.close(); previewInformation = ""; informationButton.isHidden = true
            previewNotice.isHidden = true; previewNotice.stringValue = ""
            releaseSyntax(); diff = []; renderDiff(); lastPreviewKey = key
        }
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: [DiffLine], notice: String?
                var plainSource: String?, worktreeSignature: String?
                if let file, let snapshot, file.group != .untracked && file.group != .conflicts {
                    let value = try await changes.diff(root: root, file: file, snapshot: snapshot, context: context)
                    result = value.lines; notice = value.notice; previewTimings = value.timings; worktreeSignature = value.worktreeSignature
                } else {
                    let value: FilePreview
                    if let file, file.group == .conflicts, stageIndex > 0 { value = FileService.decode(try await changes.conflictStage(root: root, file: file, stage: stageIndex)) }
                    else { value = try await service.preview(root: root, path: path) }
                    if !value.limited { plainSource = value.text }
                    result = value.text.isEmpty ? [] : value.text.components(separatedBy: "\n").enumerated().map { DiffLine(file?.group == .untracked ? .addition : .context, new: $0.offset + 1, text: $0.element) }
                    notice = [file?.group == .conflicts ? "Merge conflict. Resolve in your CLI or editor." : nil, value.notice].compactMap { $0 }.joined(separator: "\n")
                }
                guard token == previewGeneration, !Task.isCancelled else { return }
                let hasLongLines = result.contains { $0.text.utf8.count > 16_384 && $0.text.count > 16_384 }
                releaseSyntax(); diff = result
                previewInformation = notice?.contains("External Git content filters are disabled") == true ? "Git content filters are disabled. This preview shows repository content without running external filters." : ""
                updatePreviewControls()
                let visible = visibleNotice(notice)
                previewNotice.textColor = SpookkyPalette.secondary
                previewNotice.isHidden = (visible ?? "").isEmpty && !hasLongLines
                previewNotice.stringValue = [visible, hasLongLines ? "Long lines are clipped in this preview. Open in an editor for full display." : nil].compactMap { $0 }.joined(separator: "\n")
                let renderStarted = ProcessInfo.processInfo.systemUptime
                renderDiff()
                previewTimings["render_ms"] = (ProcessInfo.processInfo.systemUptime - renderStarted) * 1000
                loadSyntax(path: path, file: file, snapshot: snapshot, plainSource: plainSource, signature: worktreeSignature, token: token)
            } catch is CancellationError {} catch {
                if token == previewGeneration { previewNotice.isHidden = false; previewNotice.textColor = SpookkyPalette.warning; previewNotice.stringValue = error.localizedDescription; previewNotice.setAccessibilityValue(error.localizedDescription) }
            }
        }
    }
    private func releaseSyntax() {
        syntaxTask?.cancel(); syntaxTask = nil; oldSyntax = nil; newSyntax = nil; syntaxReadyMilliseconds = nil
    }
    private func clearSyntaxCache() {
        syntaxCacheBytes = 0
        Task { await syntax.clearCache() }
    }
    private func loadSyntax(path: String, file: ChangedFile?, snapshot: ChangesSnapshot?, plainSource: String?, signature: String?, token: UUID) {
        if let plainSource, SyntaxHighlighter.language(path: path, text: plainSource) == nil { return }
        let root = root, started = ProcessInfo.processInfo.systemUptime
        syntaxTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == previewGeneration { syntaxTask = nil } }
            do {
                let old: SyntaxDocument?, new: SyntaxDocument?
                var sourceNotice: String?
                if let plainSource {
                    old = nil; new = try await syntax.highlight(plainSource, path: path)
                } else if let file, let snapshot, file.group != .untracked && file.group != .conflicts {
                    let sources = try await changes.sources(root: root, file: file, snapshot: snapshot, expectedWorktreeSignature: signature)
                    old = try await sources.old.asyncSyntax(syntax, path: file.group == .unstaged ? path : file.oldPath ?? path)
                    new = try await sources.new.asyncSyntax(syntax, path: path)
                    sourceNotice = sources.notice
                } else { return }
                let cacheBytes = await syntax.retainedBytes
                try Task.checkCancellation()
                guard token == previewGeneration else { return }
                guard (old?.cost ?? 0) + (new?.cost ?? 0) <= 32 * 1024 * 1024 else { throw SyntaxFailure.limit }
                if let sourceNotice { addPreviewInformation(sourceNotice) }
                oldSyntax = old; newSyntax = new; syntaxCacheBytes = cacheBytes
                syntaxReadyMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
                previewTimings["syntax_ms"] = syntaxReadyMilliseconds
                restyleVisibleRows()
            } catch is CancellationError {} catch {
                if token == previewGeneration { addPreviewInformation(error.localizedDescription) }
            }
        }
    }
    private func addPreviewInformation(_ text: String) {
        previewInformation = [previewInformation, text].filter { !$0.isEmpty }.joined(separator: "\n")
        updatePreviewControls()
    }
    private func restyleVisibleRows() {
        diffTable.enumerateAvailableRowViews { [weak self] _, row in
            guard let self, row < displayRows.count else { return }
            for (index, column) in diffTable.tableColumns.enumerated() {
                guard let cell = diffTable.view(atColumn: index, row: row, makeIfNecessary: false) as? DiffCell else { continue }
                styleCell(cell, column: column.identifier.rawValue, row: row)
            }
        }
    }
    private func styleCell(_ cell: DiffCell, column: String, row: Int) {
        guard ["text", "before", "after"].contains(column) else { return }
        let pair = displayRows[row]
        let line = splitRendered && column == "after" ? pair.1 : pair.0
        guard let line, line.kind != .header, line.kind != .notice else { return }
        let oldSide = splitRendered ? column == "before" : line.kind == .removal
        let document = oldSide ? oldSyntax : newSyntax
        let number = oldSide ? line.old : line.new
        let styled = NSMutableAttributedString(string: line.text, attributes: [.font: DiffCell.codeFont, .foregroundColor: SpookkyPalette.text, .paragraphStyle: DiffCell.codeParagraph])
        if let document, let number, number > 0, number <= document.lines.count {
            let syntaxLine = document.lines[number - 1]
            if syntaxLine.text == line.text {
                for span in syntaxLine.spans where NSMaxRange(span.range) <= styled.length {
                    styled.addAttribute(.foregroundColor, value: SpookkyPalette.syntax(span.role), range: span.range)
                    if span.role == .comment { styled.addAttribute(.font, value: DiffCell.commentFont, range: span.range) }
                }
            }
        }
        cell.label.attributedStringValue = styled
    }
    private func renderDiff() {
        rendering = true; defer { rendering = false }
        let previousRows = displayRows, selection = diffTable.selectedRowIndexes
        let sameSelection = !lastPreviewKey.isEmpty && displaySelectionKey == lastPreviewKey
        displaySelectionKey = lastPreviewKey
        splitRendered = state.splitDiff && isDiff && previewWidth >= 600
        layoutButton.selected = splitRendered; unifiedButton.selected = !splitRendered
        layoutButton.setAccessibilityValue(splitRendered ? "Selected" : nil); unifiedButton.setAccessibilityValue(splitRendered ? nil : "Selected")
        layoutButton.toolTip = state.splitDiff && previewWidth < 600 ? "Split diff · widen preview to 600 points" : "Split diff"
        updateComparisonCaptions(); updatePreviewControls()
        displayRows = []
        if splitRendered {
            var index = 0
            while index < diff.count {
                let line = diff[index]
                if line.kind == .removal || line.kind == .addition {
                    var removed: [DiffLine] = [], added: [DiffLine] = []
                    while index < diff.count && (diff[index].kind == .removal || diff[index].kind == .addition) {
                        if diff[index].kind == .removal { removed.append(diff[index]) } else { added.append(diff[index]) }; index += 1
                    }
                    for row in 0..<max(removed.count, added.count) { displayRows.append((row < removed.count ? removed[row] : nil, row < added.count ? added[row] : nil)) }
                } else { displayRows.append((line, line)); index += 1 }
            }
        } else { displayRows = diff.map { ($0, nil) } }
        let names = splitRendered ? ["old", "oldSign", "before", "new", "newSign", "after"] : isDiff ? ["old", "new", "sign", "text"] : ["new", "text"]
        let dimensions = diff.reduce(into: (characters: 0, lineNumber: 0)) { result, line in
            let columns: Int
            if line.text.utf8.contains(9) {
                columns = line.text.reduce(0) { $1 == "\t" ? (($0 / 4) + 1) * 4 : $0 + 1 }
            } else if line.text.utf8.count == line.text.utf16.count {
                columns = line.text.utf8.count
            } else {
                columns = line.text.count
            }
            result.characters = max(result.characters, columns)
            result.lineNumber = max(result.lineNumber, line.old ?? 0, line.new ?? 0)
        }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        diffNumberWidth = max(28, ceil((String(dimensions.lineNumber) as NSString).size(withAttributes: [.font: font]).width) + 12)
        let glyphWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        diffTextWidth = CGFloat(min(16_384, dimensions.characters)) * glyphWidth + 16
        if diffTable.tableColumns.map({ $0.identifier.rawValue }) != names {
            diffTable.tableColumns.forEach { diffTable.removeTableColumn($0) }
            for name in names { diffTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))) }
        }
        sizeDiffColumns()
        diffTable.reloadData()
        if sameSelection {
            let surviving = selection.filter { index in
                index < previousRows.count && index < displayRows.count && previousRows[index].0 == displayRows[index].0 && previousRows[index].1 == displayRows[index].1
            }
            diffTable.selectRowIndexes(IndexSet(surviving), byExtendingSelection: false)
        }
        diffScroll.contentView.scroll(to: NSPoint(x: 0, y: min(CGFloat(state.scroll) * diffTable.rowHeight, max(0, diffTable.bounds.height - diffScroll.contentView.bounds.height))))
        diffScroll.reflectScrolledClipView(diffScroll.contentView)
    }
    private func updatePreviewControls() {
        let compact = previewWidth < 360
        for button in secondaryPreviewActions { button.isHidden = previewWidth < 480 }
        previewOverflow.isHidden = previewWidth >= 480
        informationButton.isHidden = compact || previewInformation.isEmpty
        contextButton.isHidden = compact || !isDiff
        unifiedButton.isHidden = compact || !isDiff; layoutButton.isHidden = compact || !isDiff
        inspectionControls?.isHidden = informationButton.isHidden && contextButton.isHidden
        layoutControls?.isHidden = compact || !isDiff
    }
    private func updateComparisonCaptions() {
        comparisonCaptions.isHidden = selectedFile == nil
        guard let file = selectedFile else { return }
        let before: String, after: String
        switch file.group {
        case .unstaged: before = "Index"; after = "Working copy"
        case .staged: before = snapshot?.head.map { "HEAD · " + $0.prefix(8) } ?? "Empty repository"; after = "Index"
        case .committed: before = snapshot?.base.map { "Base · " + $0.prefix(8) } ?? "Base"; after = snapshot?.head.map { "HEAD · " + $0.prefix(8) } ?? "HEAD"
        case .conflicts: before = "Conflict · " + (stage.titleOfSelectedItem ?? "Working file"); after = ""
        case .untracked: before = "Untracked file"; after = ""
        }
        oldCaption.stringValue = splitRendered || after.isEmpty ? before : before + " → " + after
        newCaption.stringValue = after; newCaption.isHidden = !splitRendered || after.isEmpty
        oldCaption.setAccessibilityLabel(splitRendered ? "Before · " + before : oldCaption.stringValue)
        newCaption.setAccessibilityLabel("After · " + after)
        let help = [snapshot?.reference, snapshot?.base, snapshot?.head, file.oldPath].compactMap { $0 }.joined(separator: " · ")
        oldCaption.toolTip = help; newCaption.toolTip = help
    }
    private func sizeDiffColumns() {
        let overhead = splitRendered ? diffNumberWidth + 16 : isDiff ? diffNumberWidth * 2 + 16 : diffNumberWidth
        let available = (splitRendered ? previewWidth / 2 : previewWidth) - overhead
        let textWidth = max(100, available, diffTextWidth)
        for column in diffTable.tableColumns {
            let name = column.identifier.rawValue
            let width = name == "old" || name == "new" ? diffNumberWidth : name.lowercased().contains("sign") ? 16 : textWidth
            if column.minWidth != width || column.maxWidth != width || abs(column.width - width) > 0.5 {
                column.resizingMask = []; column.minWidth = width; column.maxWidth = width; column.width = width
            }
        }
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = WorkspaceTableRow()
        if tableView === diffTable, row < displayRows.count {
            func fill(_ line: DiffLine?) -> NSColor? {
                line?.kind == .addition ? SpookkyPalette.addition : line?.kind == .removal ? SpookkyPalette.removal : nil
            }
            view.leftFill = fill(displayRows[row].0)
            if splitRendered { view.rightFill = fill(displayRows[row].1); view.splitX = tableView.rect(ofColumn: 3).minX }
        }
        return view
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === fileTable ? rows.count : displayRows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < (tableView === fileTable ? rows.count : displayRows.count) else { return nil }
        let key = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("file")
        if tableView === fileTable {
            let cell = tableView.makeView(withIdentifier: key, owner: self) as? FileListCell ?? FileListCell(frame: .zero)
            cell.identifier = key
            let value = rows[row]
            let depth = state.query.isEmpty && !state.changes ? max(0, value.2.split(separator: "/").count - 1) : 0
            let name = state.changes || !state.query.isEmpty ? value.2 : value.0?.name ?? value.2
            let symbol: String
            switch value.0?.kind {
            case .directory:
                symbol = state.expanded.contains(value.2) ? "chevron.down" : "chevron.right"
            case .repository: symbol = "folder.badge.gearshape"
            case .symlink: symbol = "arrow.turn.up.right"
            default: symbol = SpookkyStyle.fileSymbol(name)
            }
            let help = value.1?.oldPath.map { value.2 + " (renamed from " + $0 + ")" } ?? value.2
            cell.configure(path: name, symbol: symbol, status: value.1?.status ?? "", depth: depth, group: value.0 == nil && value.1 == nil, showParent: state.changes || !state.query.isEmpty, help: help)
            return cell
        } else {
            let name = key.rawValue, number = name == "old" || name == "new", sign = name.lowercased().contains("sign")
            let cell = tableView.makeView(withIdentifier: key, owner: self) as? DiffCell ?? DiffCell(identifier: key, number: number, sign: sign)
            let pair = displayRows[row]
            let line = splitRendered && ["after", "new", "newSign"].contains(name) ? pair.1 : pair.0
            if name == "old" { cell.label.stringValue = line?.old.map(String.init) ?? "" }
            else if name == "new" { cell.label.stringValue = line?.new.map(String.init) ?? "" }
            else if sign { cell.label.stringValue = line?.kind == .addition ? "+" : line?.kind == .removal ? "−" : "" }
            else { cell.label.stringValue = line?.text ?? "" }
            cell.label.textColor = number ? SpookkyPalette.metadata : line?.kind == .notice || line?.kind == .header ? SpookkyPalette.secondary : SpookkyPalette.text
            cell.toolTip = nil
            cell.setAccessibilityLabel(cell.label.stringValue); styleCell(cell, column: name, row: row); return cell
        }
    }
    func settleForFixture() async {
        for _ in 0..<32 {
            let loading = generation, previewing = previewGeneration
            if let loadTask { await loadTask.value }
            if let previewTask { await previewTask.value }
            if loading == generation && previewing == previewGeneration { break }
        }
        layout.layoutSubtreeIfNeeded()
    }
    func previewForFixture(path: String, group: String?, split: Bool = false, waitForSyntax: Bool = true) async throws -> Double {
        guard CommandLine.arguments.contains("--workspace-benchmark-files") else { throw ChangesError.unsupported("File measurements require a disposable benchmark.") }
        let started = ProcessInfo.processInfo.systemUptime
        edit { $0.selectedPath = path; $0.selectedGroup = group; $0.preview = true; $0.splitDiff = split }
        await settleForFixture()
        openSelection(); await settleForFixture()
        let layoutStarted = ProcessInfo.processInfo.systemUptime
        layout.layoutSubtreeIfNeeded(); preview.layoutSubtreeIfNeeded()
        previewTimings["layout_ms"] = (ProcessInfo.processInfo.systemUptime - layoutStarted) * 1000
        guard !diff.isEmpty else {
            throw ChangesError.unsupported(previewNotice.stringValue + " Fixture: changes=\(state.changes), files=\(snapshot?.files.count ?? -1), group=\(state.selectedGroup ?? "none").")
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        previewTimings["total_ms"] = elapsed
        if !waitForSyntax { return elapsed }
        await settleSyntaxForFixture()
        previewTimings["syntax_ready_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
        previewTimings["syntax_colored"] = (oldSyntax != nil || newSyntax != nil) ? 1 : 0
        return elapsed
    }
    func settleSyntaxForFixture() async {
        guard CommandLine.arguments.contains("--workspace-benchmark-files") else { return }
        if let syntaxTask { await syntaxTask.value }
        preview.layoutSubtreeIfNeeded()
    }
    func interactionChecksForFixture() async throws -> [String: Bool] {
        guard CommandLine.arguments.contains("--workspace-benchmark-files") else { throw ChangesError.unsupported("Disposable file fixture required.") }
        for index in 0..<12 {
            edit { $0.selectedPath = index % 2 == 0 ? "sample.swift" : "other.swift"; $0.selectedGroup = "Unstaged" }
            openSelection(); try await Task.sleep(for: .milliseconds(5))
        }
        if let previewTask { await previewTask.value }
        let lastSelection = state.selectedPath == "other.swift" && diff.contains { $0.kind == .addition && $0.text.contains(String(repeating: "z", count: 40)) }
        diffTable.selectRowIndexes(IndexSet(integersIn: 0..<min(4, displayRows.count)), byExtendingSelection: false)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let copied = diffTable.copySelection(to: pasteboard) && pasteboard.string(forType: .string) == diffTable.copyText?()
        let selectedRows = diffTable.selectedRowIndexes, selectedText = diffTable.copyText?()
        let contentFrame = diffScroll.frame, contentCount = diff.count
        let informationVisible = !informationButton.isHidden
        refresh(); openSelection(); preview.layoutSubtreeIfNeeded(); sidebar.layoutSubtreeIfNeeded()
        let quietSidebar = status.isHidden
        let quietPreview = previewNotice.isHidden && diff.count == contentCount && diffScroll.frame == contentFrame
        let informationStable = (!informationButton.isHidden) == informationVisible
        await settleForFixture()
        let selectionSurvivedRefresh = diffTable.selectedRowIndexes == selectedRows && diffTable.copyText?() == selectedText
        changeMode(changes: false); await settleForFixture()
        let rawFile = selectedFile == nil && !diff.contains { $0.kind == .addition || $0.kind == .removal }
        changeMode(changes: true); await settleForFixture()
        let restoredComparison = selectedFile?.group == .unstaged && diff.contains { $0.kind == .addition }
        let live = URL(fileURLWithPath: root).appendingPathComponent("live.txt")
        try Data("event 0".utf8).write(to: live)
        edit { $0.changes = false; $0.selectedPath = "live.txt"; $0.selectedGroup = nil; $0.preview = true }
        refresh(); await settleForFixture()
        layout.window?.makeFirstResponder(fileTable)
        let writer = Task.detached {
            for index in 1...40 {
                try Data("event \(index)".utf8).write(to: live)
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await writer.value
        for _ in 0..<150 {
            if diff.contains(where: { $0.text == "event 40" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let refreshed = diff.contains { $0.text == "event 40" }
        let focused = layout.window?.firstResponder === fileTable
        try FileManager.default.removeItem(at: live)
        refresh(); await settleForFixture()
        let unavailableVisible = !previewNotice.isHidden && !previewNotice.stringValue.isEmpty
        let unavailableText = previewNotice.stringValue
        refresh(); openSelection()
        let errorSurvivedRefresh = !previewNotice.isHidden && previewNotice.stringValue == unavailableText
        await settleForFixture()
        edit { $0.preview = false; $0.sidebar = false }
        return ["latest_selection_wins": lastSelection, "selected_rows_copy": copied, "preview_selection_survived_refresh": selectionSurvivedRefresh,
                "sidebar_refresh_quiet": quietSidebar, "preview_refresh_geometry_stable": quietPreview,
                "preview_information_control_stable": informationStable, "unavailable_preview_notice_visible": unavailableVisible,
                "error_notice_survived_refresh": errorSurvivedRefresh,
                "files_changes_scope_switch": rawFile && restoredComparison,
                "continuous_edits_refreshed": refreshed, "refresh_preserved_focus": focused,
                "hidden_watcher_stopped": diagnostics["watchers"] == 0]
    }
    private func selectedURL() -> URL? {
        guard let path = state.selectedPath, !root.isEmpty else { return nil }
        return URL(fileURLWithPath: root).appendingPathComponent(path)
    }
    private func reveal() { if let url = selectedURL() { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    private func openWith(_ explicitURL: URL? = nil) {
        guard let url = explicitURL ?? selectedURL(), let window = layout.window else { return }
        let panel = NSOpenPanel(); panel.title = "Choose an application"; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.applicationBundle]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let application = panel.url else { return }
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { self?.previewNotice.isHidden = false; self?.previewNotice.stringValue = error.localizedDescription } }
            }
        }
    }
}

private extension Optional where Wrapped == String {
    func asyncSyntax(_ highlighter: SyntaxHighlighter, path: String) async throws -> SyntaxDocument? {
        guard let value = self else { return nil }
        return try await highlighter.highlight(value, path: path)
    }
}
