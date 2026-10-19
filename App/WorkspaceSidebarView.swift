import AppKit
import SpookkyCore

@MainActor struct WorkspaceSidebarItem {
    enum Kind { case project, conversation, more, section }
    let id: String
    var kind: Kind
    var title: String
    var image: NSImage?
    var help: String
    var selected: Bool
    var nested: Bool
    var collapsed: Bool
    var activity: AgentActivityState?

    init(id: String, kind: Kind, title: String, image: NSImage? = nil, help: String = "",
         selected: Bool = false, nested: Bool = false, collapsed: Bool = false,
         activity: AgentActivityState? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.image = image
        self.help = help.isEmpty ? title : help; self.selected = selected; self.nested = nested
        self.collapsed = collapsed; self.activity = activity
    }
}

@MainActor final class WorkspaceSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onActivate: ((String) -> Void)?
    var onAddProjectSession: ((String) -> Void)?
    var onAddProject: ((NSView) -> Void)?
    var onMore: ((String) -> Void)?
    var onContextMenu: ((String) -> NSMenu?)?
    var pointerLocation: (NSWindow) -> NSPoint? = { $0.mouseLocationOutsideOfEventStream } {
        didSet { reconcileHover() }
    }
    private let scroll = NSScrollView()
    private let table = WorkspaceSidebarTable()
    private var items: [WorkspaceSidebarItem] = []
    private var indexByID: [String: Int] = [:]
    private var collapsed = false
    private var keyboardNavigation = false
    private var trackingMenus = Set<ObjectIdentifier>()
    private var pendingUpdate: (items: [WorkspaceSidebarItem], collapsed: Bool)?
    private(set) var hoveredItemID: String?
    private(set) var focusedItemID: String?
    var keyboardFocusItemID: String? { hasKeyboardFocus && keyboardNavigation ? focusedItemID : nil }
    var itemCount: Int { items.count }
    var selectedItemIDs: [String] { items.filter(\.selected).map(\.id) }
    var visibleCellCount: Int {
        var count = 0
        table.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        table.style = .plain
        table.headerView = nil; table.backgroundColor = .clear; table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none; SpookkyStyle.suppressFocusRing(table)
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: .init("session"))
        column.minWidth = 0
        column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.delegate = self; table.dataSource = self
        table.target = self; table.action = #selector(clickedRow)
        table.onPointerChange = { [weak self] in self?.reconcileHover() }
        table.onKey = { [weak self] key in self?.handleKey(key) }
        table.onFocusChange = { [weak self] in self?.focusChanged() }
        table.onContextMenu = { [weak self] row in self?.keyboardNavigation = false; return self?.contextMenu(row: row) }
        table.setAccessibilityLabel("Projects and conversations")
        scroll.contentView = WorkspaceSidebarClipView()
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = .init()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay; scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingChanged), name: name, object: nil)
        }
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(table) == true }
    override func layout() {
        super.layout(); scroll.frame = bounds
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: table.frame.height))
        if let column = table.tableColumns.first { column.width = scroll.contentSize.width }
        reconcileHover()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didResizeNotification] {
            center.removeObserver(self, name: name, object: nil)
            if let window { center.addObserver(self, selector: #selector(geometryChanged), name: name, object: window) }
        }
        reconcileHover(); refreshVisibleRows()
    }

    func displayChanged() {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
        refreshVisibleRows(); needsLayout = true
    }
    func update(items: [WorkspaceSidebarItem], collapsed: Bool) {
        guard trackingMenus.isEmpty else { pendingUpdate = (items, collapsed); return }
        let restoreKeyboardFocus = hasKeyboardFocus
        let origin = scroll.contentView.bounds.origin
        let firstRow = table.row(at: NSPoint(x: 0, y: origin.y))
        let anchorID = self.items.indices.contains(firstRow) ? self.items[firstRow].id : nil
        let anchorOffset = firstRow >= 0 ? origin.y - table.rect(ofRow: firstRow).minY : 0
        var seen = Set<String>()
        let items = items.filter { (!collapsed || $0.kind != .section) && seen.insert($0.id).inserted }
        self.items = items; self.collapsed = collapsed
        indexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        if focusedItemID.flatMap({ indexByID[$0] }) == nil {
            focusedItemID = items.first(where: { $0.selected })?.id ?? items.first(where: { $0.kind != .section })?.id
        }
        table.reloadData()
        let selected = items.firstIndex(where: { $0.selected })
        table.selectRowIndexes(selected.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        table.layoutSubtreeIfNeeded()
        let y = anchorID.flatMap { indexByID[$0] }.map { table.rect(ofRow: $0).minY + anchorOffset } ?? origin.y
        let limit = max(0, table.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), limit)))
        scroll.reflectScrolledClipView(scroll.contentView)
        if restoreKeyboardFocus { window?.makeFirstResponder(table) }
        reconcileHover(); refreshVisibleRows()
    }

    @objc private func menuTrackingChanged(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        if notification.name == NSMenu.didBeginTrackingNotification { trackingMenus.insert(ObjectIdentifier(menu)) }
        else { trackingMenus.remove(ObjectIdentifier(menu)) }
        if trackingMenus.isEmpty, let pendingUpdate {
            self.pendingUpdate = nil
            update(items: pendingUpdate.items, collapsed: pendingUpdate.collapsed)
        }
    }

    func focusItem(_ id: String? = nil) {
        let row = (id ?? focusedItemID).flatMap { indexByID[$0] } ?? items.firstIndex(where: { $0.kind != .section })
        if let row { focus(row: row) }
        window?.makeFirstResponder(table)
        keyboardNavigation = true; refreshVisibleRows()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row].kind { case .project: SpookkyStyle.points(28); case .conversation, .more: SpookkyStyle.points(32); case .section: SpookkyStyle.points(28) }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items[row].kind == .conversation }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { WorkspaceSidebarRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("workspace-sidebar-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? WorkspaceSidebarCell ?? WorkspaceSidebarCell()
        cell.identifier = identifier
        configure(cell, row: row)
        return cell
    }
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) { refreshRow(row) }

    private var hasKeyboardFocus: Bool {
        guard window?.isKeyWindow == true, let responder = window?.firstResponder as? NSView else { return false }
        return responder === table || responder.isDescendant(of: table)
    }
    private func configure(_ cell: WorkspaceSidebarCell, row: Int) {
        let item = items[row]
        let focused = keyboardFocusItemID == item.id
        cell.configure(item, collapsed: collapsed, interactionActive: hoveredItemID == item.id || focused)
        cell.onPress = { [weak self] in
            guard let self, let current = indexByID[item.id] else { return }
            press(row: current)
        }
        cell.onAccessory = { [weak self] anchor in
            guard let self, let current = indexByID[item.id] else { return }
            focus(row: current, scrollIntoView: false)
            if item.id == "section:projects" { onAddProject?(anchor) }
            else if item.kind == .project { onAddProjectSession?(item.id) }
            else if let menu = onContextMenu?(item.id) {
                menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.maxX, y: anchor.bounds.minY), in: anchor)
            }
        }
        cell.onFocus = { [weak self] focused in
            guard let self else { return }
            keyboardNavigation = focused
            if focused { focusedItemID = item.id }
            DispatchQueue.main.async { [weak self] in self?.refreshVisibleRows() }
        }
        cell.onNavigate = { [weak self] in self?.handleKey($0) }
    }
    private func refreshRow(_ row: Int) {
        guard items.indices.contains(row) else { return }
        let item = items[row]
        let focused = keyboardFocusItemID == item.id
        if let view = table.rowView(atRow: row, makeIfNecessary: false) as? WorkspaceSidebarRow {
            view.modelSelected = item.selected; view.hovered = hoveredItemID == item.id; view.keyboardFocused = focused
            view.needsDisplay = true
        }
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? WorkspaceSidebarCell { configure(cell, row: row) }
    }
    private func refreshVisibleRows() {
        table.enumerateAvailableRowViews { [weak self] _, row in self?.refreshRow(row) }
    }
    @objc private func geometryChanged(_ notification: Notification) {
        reconcileHover()
        if notification.name != NSView.boundsDidChangeNotification { refreshVisibleRows() }
        else { table.enumerateAvailableRowViews { view, _ in
            for cell in view.subviews { for case let status as SidebarActivityIndicator in cell.subviews { status.updateAnimation() } }
        } }
    }
    private func reconcileHover() {
        let previous = hoveredItemID
        hoveredItemID = nil
        if let window, window.isKeyWindow, let point = pointerLocation(window) {
            let local = table.convert(point, from: nil)
            let row = table.row(at: local)
            if table.visibleRect.contains(local), items.indices.contains(row), items[row].kind != .section { hoveredItemID = items[row].id }
        }
        if previous != hoveredItemID {
            if let previous, let row = indexByID[previous] { refreshRow(row) }
            if let hoveredItemID, let row = indexByID[hoveredItemID] { refreshRow(row) }
        }
    }
    private func focusChanged() {
        if NSApp.currentEvent?.type == .keyDown { keyboardNavigation = true }
        if focusedItemID == nil { focusedItemID = items.first(where: { $0.selected })?.id ?? items.first(where: { $0.kind != .section })?.id }
        DispatchQueue.main.async { [weak self] in self?.refreshVisibleRows() }
    }
    @objc private func clickedRow() {
        press(row: table.clickedRow)
    }
    private func press(row: Int) {
        keyboardNavigation = false
        guard items.indices.contains(row), items[row].kind != .section else { return }
        focus(row: row, scrollIntoView: false); activate(row: row)
    }
    private func focus(row: Int, scrollIntoView: Bool = true) {
        guard items.indices.contains(row), items[row].kind != .section else { return }
        focusedItemID = items[row].id
        if scrollIntoView { table.scrollRowToVisible(row) }
        refreshVisibleRows()
    }
    private func activate(row: Int) {
        guard items.indices.contains(row) else { return }
        switch items[row].kind {
        case .more: onMore?(items[row].id)
        case .project, .conversation: onActivate?(items[row].id)
        case .section: break
        }
    }
    private func handleKey(_ key: UInt16) {
        keyboardNavigation = true
        guard !items.isEmpty else { return }
        let current = focusedItemID.flatMap { indexByID[$0] } ?? 0
        if key == 36 || key == 49 || key == 76 { activate(row: current); return }
        if key == 109, let menu = contextMenu(row: current) {
            menu.popUp(positioning: nil, at: NSPoint(x: 12, y: table.rect(ofRow: current).maxY), in: table); return
        }
        if key == 123 || key == 124 {
            let item = items[current]
            if item.kind == .project, item.collapsed == (key == 124) { activate(row: current) }
            return
        }
        let direction = key == 125 ? 1 : -1
        var next = current + direction
        while items.indices.contains(next), items[next].kind == .section { next += direction }
        if items.indices.contains(next) { focus(row: next) }
    }
    private func contextMenu(row: Int) -> NSMenu? {
        guard items.indices.contains(row), items[row].kind != .section else { return nil }
        focus(row: row, scrollIntoView: false)
        return onContextMenu?(items[row].id)
    }
}

@MainActor final class WorkspaceSidebarClipView: NSClipView {
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: newOrigin.y))
    }
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        constrained.origin.x = 0
        return constrained
    }
}

@MainActor private final class WorkspaceSidebarTable: NSTableView {
    var onPointerChange: (() -> Void)?
    var onKey: ((UInt16) -> Void)?
    var onFocusChange: (() -> Void)?
    var onContextMenu: ((Int) -> NSMenu?)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); onPointerChange?()
    }
    override func mouseEntered(with event: NSEvent) { onPointerChange?() }
    override func mouseExited(with event: NSEvent) { onPointerChange?() }
    override func mouseMoved(with event: NSEvent) { onPointerChange?() }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); if result { onFocusChange?() }; return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder(); if result { onFocusChange?() }; return result
    }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, [UInt16(123), 124, 125, 126, 36, 49, 76].contains(event.keyCode) || event.keyCode == 109 && event.modifierFlags.contains(.shift) {
            onKey?(event.keyCode)
        } else { super.keyDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?(row(at: convert(event.locationInWindow, from: nil))) }
}

@MainActor private final class WorkspaceSidebarRow: NSTableRowView {
    var modelSelected = false
    var hovered = false
    var keyboardFocused = false
    override func drawBackground(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: SpookkyStyle.cornerRadius, yRadius: SpookkyStyle.cornerRadius)
        if modelSelected || hovered || keyboardFocused {
            (modelSelected ? SpookkyPalette.selected : keyboardFocused ? SpookkyPalette.keyboardFocus : SpookkyPalette.hover).setFill(); path.fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor private final class WorkspaceSidebarCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = SpookkyStyle.label( "")
    private let status = SidebarActivityIndicator(frame: .zero)
    private let accessory = ActionButton("", symbol: "ellipsis", action: {})
    private var item: WorkspaceSidebarItem?
    private var collapsed = false
    var onPress: (() -> Void)?
    var onAccessory: ((NSView) -> Void)?
    var onFocus: ((Bool) -> Void)?
    var onNavigate: ((UInt16) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
        icon.imageScaling = .scaleProportionallyUpOrDown
        accessory.revealOnInteraction = true
        accessory.handler = { [weak self] in guard let self else { return }; onAccessory?(accessory) }
        accessory.onFocusChange = { [weak self] in self?.onFocus?($0) }
        accessory.onNavigate = { [weak self] in self?.onNavigate?($0) }
        [icon, label, status, accessory].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    override func accessibilityPerformPress() -> Bool {
        guard let item, item.kind != .section, let onPress else { return false }
        onPress(); return true
    }
    func configure(_ item: WorkspaceSidebarItem, collapsed: Bool, interactionActive: Bool) {
        self.item = item; self.collapsed = collapsed
        label.stringValue = item.title
        label.font = .systemFont(ofSize: SpookkyStyle.points(item.kind == .section ? 11 : 13), weight: item.kind == .section ? .semibold : .regular)
        label.textColor = item.kind == .section || item.kind == .more ? SpookkyPalette.metadata : SpookkyPalette.text
        if item.kind == .project && interactionActive && !collapsed {
            icon.image = NSImage(systemSymbolName: item.collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        } else if collapsed && item.kind == .more {
            icon.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        } else { icon.image = item.image }
        icon.contentTintColor = SpookkyPalette.secondary
        label.isHidden = collapsed; icon.isHidden = item.kind == .section || item.kind == .more && !collapsed
        status.activity = item.activity
        status.isHidden = item.activity == nil || item.activity == .unknown || item.activity == .idle || item.activity == .interrupted || interactionActive
        status.toolTip = item.activity?.label; status.updateAnimation()
        let projectHeading = item.id == "section:projects"
        accessory.image = NSImage(systemSymbolName: item.kind == .project || projectHeading ? "plus" : "ellipsis", accessibilityDescription: nil)
        accessory.compactUtility = true
        accessory.isHidden = collapsed || !projectHeading && (item.kind != .project && item.kind != .conversation || window?.isKeyWindow != true || !interactionActive)
        accessory.interactionActive = projectHeading || interactionActive
        let action = projectHeading ? "Add project" : item.kind == .project ? "New chat in " + item.title : "Actions for " + item.title
        accessory.toolTip = action; accessory.setAccessibilityLabel(action)
        toolTip = item.help; setAccessibilityLabel(item.help); setAccessibilityIdentifier(item.id)
        setAccessibilityValue(item.selected ? "Selected" : nil)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let item else { return }
        let p = SpookkyStyle.points
        let inset: CGFloat = collapsed ? 0 : SpookkyStyle.controlInset
        let leading: CGFloat = collapsed ? bounds.midX - p(8) : inset + (item.nested ? p(12) : 0)
        icon.frame = NSRect(x: leading, y: bounds.midY - p(8), width: p(16), height: p(16))
        let accessoryWidth: CGFloat = item.kind == .project || item.kind == .conversation || item.id == "section:projects" ? p(28) : 0
        accessory.frame = NSRect(x: bounds.width - inset - accessoryWidth, y: bounds.midY - p(14), width: p(28), height: p(28))
        status.frame = NSRect(x: bounds.width - inset - p(collapsed ? 12 : 20), y: bounds.midY - p(6), width: p(12), height: p(12))
        let x = leading + (icon.isHidden && item.kind != .more ? 0 : p(22))
        label.frame = NSRect(x: x, y: bounds.midY - p(9), width: max(0, bounds.width - inset - x - accessoryWidth), height: p(18))

    }
}
