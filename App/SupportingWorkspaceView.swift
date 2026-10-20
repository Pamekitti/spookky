import AppKit
import SpookkyCore

@MainActor protocol SupportingContentHost: AnyObject {
    func view(for tab: SupportingTab, workspace: Workspace,
              update: @escaping (SupportingTarget, String?) -> Void) -> NSView?
    func retainTabs(_ ids: Set<UUID>)
}

@MainActor final class SupportingWorkspaceView: NSView {
    let primary: NSView
    let panel = SupportingPanelContainer()
    let content = NSView()
    let headerView = WorkspaceRootView()
    private let strip = NSStackView()
    private let scroll = TabStripScrollView()
    private let controls = NSStackView()
    let layoutButton = ActionButton("", symbol: "rectangle.split.2x1", help: "Split view", action: {})
    private let divider = FileDivider()
    private var state = SupportingPanelState()
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onAdd: ((NSView) -> Void)?
    var onLayout: ((SupportingLayout, Double?) -> Void)?
    var onGeometryChange: (() -> Void)?
    private var items: [UUID: WorkspaceTabView] = [:]
    private var primaryItem: WorkspaceTabView?
    private(set) var joinsPrimary = false
    private var supportingTabItems: [WorkspaceTabView] { state.tabs.compactMap { items[$0.id] } }
    var tabItems: [WorkspaceTabView] { (joinsPrimary ? primaryItem.map { [$0] } ?? [] : []) + supportingTabItems }
    private var tabWidth: CGFloat { tabItems.reduce(0) { $0 + $1.naturalWidth } + CGFloat(max(0, tabItems.count - 1)) * strip.spacing }
    var headerFittingWidth: CGFloat { tabWidth + controls.fittingSize.width + layoutButton.intrinsicContentSize.width + SpookkyStyle.points(8) }
    var selectedTabFullyVisible: Bool {
        guard let item = selectedTabItem else { return true }
        return scroll.contentView.bounds.insetBy(dx: -0.5, dy: 0).contains(item.frame)
    }
    var selectedTabCanFit: Bool { selectedTabItem.map { $0.frame.width <= scroll.contentView.bounds.width + 0.5 } ?? true }
    var selectedTabVisibleWidth: CGFloat { selectedTabItem.map { scroll.contentView.bounds.intersection($0.frame).width } ?? 0 }
    private var selectedTabItem: WorkspaceTabView? {
        if joinsPrimary && effectiveFull && state.resolvedFullWidthSelection == .primary { return primaryItem }
        if isSplit || effectiveFull && state.resolvedFullWidthSelection != .primary {
            return state.selectedTabID.flatMap { items[$0] }
        }
        return nil
    }
    var compact = false
    var requestsSplit: Bool { state.layout == .split && !state.tabs.isEmpty }
    var effectiveFull: Bool { state.layout == .fullWidth || compact && requestsSplit }
    var isSplit: Bool { requestsSplit && !compact }
    private var minimumPaneWidth: CGFloat { SpookkyStyle.points(320) }
    var minimumSplitWidth: CGFloat { minimumPaneWidth * 2 + 5 }
    var primaryPaneWidth: CGFloat { primaryPaneWidth(in: bounds.width) }
    func primaryPaneWidth(in width: CGFloat) -> CGFloat {
        isSplit ? max(minimumPaneWidth, min(width - minimumPaneWidth - 5, width * state.fraction)) : width
    }
    var showsSupportingContent: Bool {
        guard !state.tabs.isEmpty, state.layout != .collapsed else { return false }
        return !effectiveFull || state.resolvedFullWidthSelection != .primary
    }
    init(primary: NSView) {
        self.primary = primary
        super.init(frame: .zero)
        [primary, panel, divider].forEach { addSubview($0) }
        panel.addSubview(content)
        headerView.addSubview(scroll); headerView.addSubview(controls); headerView.addSubview(layoutButton)
        headerView.onLayout = { [weak self] in self?.layoutHeader() }
        strip.orientation = .horizontal; strip.spacing = 0; strip.alignment = .centerY
        scroll.documentView = strip; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = .init()
        scroll.horizontalScrollElasticity = .none
        scroll.scrollerStyle = .overlay
        let add = ActionButton("", symbol: "plus", help: "Open supporting tab", action: {})
        add.handler = { [weak self, weak add] in if let add { self?.onAdd?(add) } }
        layoutButton.handler = { [weak self] in
            guard let self else { return }
            onLayout?(state.layout == .split ? .fullWidth : .split, nil)
        }
        controls.orientation = .horizontal; controls.spacing = 0
        for button in [add, layoutButton] {
            button.widthAnchor.constraint(equalToConstant: 28).displayScaled().isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).displayScaled().isActive = true
            if button !== layoutButton { controls.addArrangedSubview(button) }
        }
        divider.setAccessibilityLabel("Resize supporting panel")
        divider.onMove = { [weak self] x in guard let self else { return }; onLayout?(.split, Double(x / max(1, bounds.width))) }
        divider.onKey = { [weak self] delta in guard let self else { return }; onLayout?(.split, state.fraction + delta) }
    }
    required init?(coder: NSCoder) { fatalError() }
    func setPrimaryItem(_ item: WorkspaceTabView?, joined: Bool) {
        if let previous = primaryItem, previous !== item || !joined, previous.superview === strip {
            strip.removeArrangedSubview(previous); previous.removeFromSuperview()
        }
        primaryItem = item; joinsPrimary = joined && item != nil
        if joinsPrimary, let item { item.move(to: strip) }
        for (index, support) in supportingTabItems.enumerated() { support.move(to: strip, at: index + (joinsPrimary ? 1 : 0)) }
        headerView.needsLayout = true
    }
    var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSView {
            return control.isDescendant(of: panel)
        }
        if let primaryItem, responder.isDescendant(of: primaryItem) { return false }
        return responder === panel || responder.isDescendant(of: panel) || responder.isDescendant(of: headerView)
    }
    func update(_ state: SupportingPanelState) {
        self.state = state
        let selected = isSplit || effectiveFull && state.resolvedFullWidthSelection != .primary
        let ids = Set(state.tabs.map(\.id))
        for id in Array(items.keys) where !ids.contains(id) {
            guard let item = items.removeValue(forKey: id) else { continue }
            strip.removeArrangedSubview(item); item.removeFromSuperview()
        }
        for (index, tab) in state.tabs.enumerated() {
            var help = tab.displayTitle + " · " + tab.contentLabel
            switch tab.target {
            case .file(let path), .artifact(let path): help += "\n" + path
            case .browser(let url): help += "\n" + url
            case .changes, .terminal, .startPage: break
            }
            let item: WorkspaceTabView
            if let retained = items[tab.id] { item = retained }
            else {
                item = WorkspaceTabView(title: tab.displayTitle,
                    onSelect: { [weak self] in self?.onSelect?(tab.id) },
                    onClose: { [weak self] in self?.onClose?(tab.id) })
                items[tab.id] = item
            }
            item.update(title: tab.displayTitle,
                image: NSImage(systemSymbolName: SpookkyStyle.supportingSymbol(tab.target), accessibilityDescription: nil),
                help: help, selected: selected && tab.id == state.selectedTabID)
            item.move(to: strip, at: index + (joinsPrimary ? 1 : 0))
        }
        layoutButton.isEnabled = !state.tabs.isEmpty && !compact
        layoutButton.image = NSImage(systemSymbolName: isSplit ? "rectangle" : "rectangle.split.2x1", accessibilityDescription: nil)
        layoutButton.toolTip = compact ? "Widen the window or reduce zoom to show two readable panes" : isSplit ? "Full view" : "Split view"
        layoutButton.setAccessibilityLabel(layoutButton.toolTip!)
        needsLayout = true; headerView.needsLayout = true
    }
    func show(_ view: NSView?) {
        if content.subviews.first === view { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        guard let view else { return }
        view.removeFromSuperview(); view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: content.leadingAnchor), view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     view.topAnchor.constraint(equalTo: content.topAnchor), view.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    }
    override func layout() {
        super.layout()
        let visible = showsSupportingContent
        let full = visible && !isSplit
        primary.isHidden = full; panel.isHidden = !visible; divider.isHidden = !isSplit
        let left = full ? 0 : primaryPaneWidth
        // Hidden terminals retain their last geometry instead of resizing to one column.
        if !full { primary.frame = NSRect(x: 0, y: 0, width: left, height: bounds.height) }
        divider.frame = NSRect(x: left, y: 0, width: 5, height: bounds.height)
        if visible {
            panel.frame = NSRect(x: full ? 0 : left + 5, y: 0, width: max(0, bounds.width - (full ? 0 : left + 5)), height: bounds.height)
            content.frame = panel.bounds
        }
        onGeometryChange?()
    }
    private func layoutHeader() {
        let layoutWidth = layoutButton.intrinsicContentSize.width
        let width = max(0, headerView.bounds.width - controls.fittingSize.width - layoutWidth - SpookkyStyle.points(8))
        for item in tabItems { item.availableWidth = width }
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: SpookkyStyle.headerHeight)
        strip.frame = NSRect(x: 0, y: 0, width: tabWidth, height: SpookkyStyle.headerHeight)
        let controlsX = min(width, tabWidth)
        controls.frame = NSRect(x: controlsX + SpookkyStyle.points(4), y: (SpookkyStyle.headerHeight - SpookkyStyle.controlHeight) / 2, width: controls.fittingSize.width, height: SpookkyStyle.controlHeight)
        layoutButton.frame = NSRect(x: max(0, headerView.bounds.width - layoutWidth), y: SpookkyStyle.points(6), width: layoutWidth, height: SpookkyStyle.controlHeight)
        strip.layoutSubtreeIfNeeded()
        if let selected = selectedTabItem {
            let clip = scroll.contentView
            let viewport = clip.bounds
            var offset = viewport.minX
            if selected.frame.width > viewport.width || selected.frame.minX < viewport.minX { offset = selected.frame.minX }
            else if selected.frame.maxX > viewport.maxX { offset = selected.frame.maxX - viewport.width }
            offset = max(0, min(offset, max(0, tabWidth - viewport.width)))
            if abs(viewport.minX - offset) > 0.5 {
                clip.scroll(to: NSPoint(x: offset, y: 0)); scroll.reflectScrolledClipView(clip)
            }
        }
    }
}

@MainActor final class SupportingPanelContainer: NSView {
    override var acceptsFirstResponder: Bool { true }
}
