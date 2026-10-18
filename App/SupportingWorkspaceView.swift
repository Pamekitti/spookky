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
    private let layoutButton = ActionButton("", symbol: "rectangle.split.2x1", action: {})
    private let divider = FileDivider()
    private var state = SupportingPanelState()
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onAdd: ((NSView) -> Void)?
    var onLayout: ((SupportingLayout, Double?) -> Void)?
    var onGeometryChange: (() -> Void)?
    private var stripKey = ""
    var headerFittingWidth: CGFloat { strip.fittingSize.width + 60 }
    var isSplit: Bool { state.layout == .split && !state.tabs.isEmpty }
    var primaryPaneWidth: CGFloat {
        isSplit ? max(160, min(bounds.width - 200, bounds.width * state.fraction)) : bounds.width
    }
    var showsSupportingContent: Bool {
        guard !state.tabs.isEmpty, state.layout != .collapsed else { return false }
        return state.layout != .fullWidth || state.resolvedFullWidthSelection != .primary
    }
    init(primary: NSView) {
        self.primary = primary
        super.init(frame: .zero)
        [primary, panel, divider].forEach { addSubview($0) }
        panel.addSubview(content)
        headerView.addSubview(scroll); headerView.addSubview(controls)
        headerView.onLayout = { [weak self] in self?.layoutHeader() }
        strip.orientation = .horizontal; strip.spacing = 2
        scroll.documentView = strip; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        let add = ActionButton("", symbol: "plus", help: "Open supporting tab", action: {})
        add.handler = { [weak self, weak add] in if let add { self?.onAdd?(add) } }
        layoutButton.handler = { [weak self] in
            guard let self else { return }
            onLayout?(state.layout == .split ? .fullWidth : .split, nil)
        }
        controls.orientation = .horizontal; controls.spacing = 0
        for button in [add, layoutButton] {
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            controls.addArrangedSubview(button)
        }
        divider.setAccessibilityLabel("Resize supporting panel")
        divider.onMove = { [weak self] x in guard let self else { return }; onLayout?(.split, Double(x / max(1, bounds.width))) }
        divider.onKey = { [weak self] delta in guard let self else { return }; onLayout?(.split, state.fraction + delta) }
    }
    required init?(coder: NSCoder) { fatalError() }
    var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSView {
            return control.isDescendant(of: panel)
        }
        return responder === panel || responder.isDescendant(of: panel) || responder.isDescendant(of: headerView)
    }
    func update(_ state: SupportingPanelState) {
        self.state = state
        let selected = state.layout == .split || (state.layout == .fullWidth && state.resolvedFullWidthSelection != .primary)
        let key = state.tabs.map { $0.id.uuidString + $0.displayTitle + $0.contentLabel }.joined() + String(describing: state.selectedTabID) + String(selected)
        if key != stripKey {
            stripKey = key
            strip.arrangedSubviews.forEach { strip.removeArrangedSubview($0); $0.removeFromSuperview() }
            for tab in state.tabs {
                let select = ActionButton(tab.displayTitle, symbol: SpookkyStyle.supportingSymbol(tab.target), help: tab.displayTitle + " · " + tab.contentLabel) { [weak self] in self?.onSelect?(tab.id) }
                switch tab.target {
                case .file(let path), .artifact(let path): select.toolTip = tab.displayTitle + " · " + tab.contentLabel + "\n" + path
                case .browser(let url): select.toolTip = tab.displayTitle + " · Browser\n" + url
                case .changes, .terminal: break
                }
                select.selected = selected && tab.id == state.selectedTabID; select.drawsInteractionFill = false
                select.setAccessibilityValue(select.selected ? "Selected" : nil)
                select.lineBreakMode = .byTruncatingTail
                select.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
                select.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).isActive = true
                let close = ActionButton("", symbol: "xmark", help: "Close " + tab.displayTitle) { [weak self] in self?.onClose?(tab.id) }
                close.widthAnchor.constraint(equalToConstant: 24).isActive = true
                close.heightAnchor.constraint(equalToConstant: 24).isActive = true
                let pair = ChromeStackView(views: [select, close]); pair.spacing = 0
                pair.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).isActive = true
                pair.selected = select.selected; pair.cornerRadius = 0; pair.drawsTrailingBorder = true
                strip.addArrangedSubview(pair)
            }
        }
        layoutButton.isEnabled = !state.tabs.isEmpty
        layoutButton.image = NSImage(systemSymbolName: isSplit ? "arrow.up.left.and.arrow.down.right" : "rectangle.split.2x1", accessibilityDescription: nil)
        layoutButton.toolTip = isSplit ? "Show selected supporting tab at full width" : "Show conversation and supporting tab side by side"
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
        let width = max(0, headerView.bounds.width - 60)
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: SpookkyStyle.headerHeight)
        strip.frame = NSRect(x: 0, y: 0, width: max(width, strip.fittingSize.width), height: SpookkyStyle.headerHeight)
        controls.frame = NSRect(x: width + 4, y: 6, width: 56, height: 28)
        strip.layoutSubtreeIfNeeded()
        if isSplit || (state.layout == .fullWidth && state.resolvedFullWidthSelection != .primary),
           let index = state.tabs.firstIndex(where: { $0.id == state.selectedTabID }), strip.arrangedSubviews.indices.contains(index) {
            let selected = strip.arrangedSubviews[index]; selected.scrollToVisible(selected.bounds)
        }
    }
}

@MainActor final class SupportingPanelContainer: NSView {
    override var acceptsFirstResponder: Bool { true }
}
