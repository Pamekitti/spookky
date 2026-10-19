import AppKit

@MainActor final class WorkspaceTabView: NSView {
    static var minimumWidth: CGFloat { SpookkyStyle.points(96) }
    static var maximumWidth: CGFloat { SpookkyStyle.points(220) }
    let titleButton: ActionButton
    let closeButton: ActionButton
    private var widthConstraint: NSLayoutConstraint!
    private var tracking: NSTrackingArea?
    private var hovered = false
    var availableWidth: CGFloat? { didSet { if oldValue != availableWidth { needsLayout = true; invalidateIntrinsicContentSize() } } }
    var selected = false { didSet { updateAppearance() } }
    var isHeading = false { didSet { needsDisplay = true } }
    var closable = true { didSet { updateInteraction() } }
    var preferredWidth: CGFloat {
        min(Self.maximumWidth, max(Self.minimumWidth, titleButton.intrinsicContentSize.width + SpookkyStyle.points(closable ? 28 : 0)))
    }
    var naturalWidth: CGFloat {
        min(availableWidth.map { max(SpookkyStyle.points(48), $0) } ?? Self.maximumWidth, preferredWidth)
    }

    init(title: String, image: NSImage? = nil, help: String? = nil, closable: Bool = true,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void = {}) {
        titleButton = ActionButton(title, help: help, height: SpookkyStyle.headerHeight, action: onSelect)
        closeButton = ActionButton("", symbol: "xmark", help: "Close " + title, height: SpookkyStyle.points(24), action: onClose)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleButton.image = image
        titleButton.imagePosition = .imageLeading
        titleButton.alignment = .left
        titleButton.drawsInteractionFill = false
        titleButton.lineBreakMode = .byTruncatingTail
        closeButton.revealOnInteraction = true
        titleButton.onFocusChange = { [weak self] focused in self?.focusChanged(focused) }
        closeButton.onFocusChange = { [weak self] focused in self?.focusChanged(focused) }
        addSubview(titleButton); addSubview(closeButton)
        widthConstraint = widthAnchor.constraint(equalToConstant: naturalWidth)
        NSLayoutConstraint.activate([widthConstraint, heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).displayScaled(alreadyScaled: true)])
        self.closable = closable
        updateAppearance(); updateInteraction()
    }
    required init?(coder: NSCoder) { fatalError("Use init") }

    func update(title: String, image: NSImage?, help: String?, selected: Bool, closable: Bool = true) {
        titleButton.title = title; titleButton.image = image
        titleButton.toolTip = help ?? title; titleButton.setAccessibilityLabel(help ?? title)
        closeButton.toolTip = "Close " + title; closeButton.setAccessibilityLabel("Close " + title)
        self.selected = selected; self.closable = closable
        widthConstraint.constant = naturalWidth
        invalidateIntrinsicContentSize(); needsLayout = true
    }
    override var intrinsicContentSize: NSSize { NSSize(width: naturalWidth, height: SpookkyStyle.headerHeight) }
    func move(to stack: NSStackView, at index: Int = 0) {
        if superview === stack, stack.arrangedSubviews.firstIndex(where: { $0 === self }) == index { return }
        let previousWindow = window
        let responder = window?.firstResponder as? NSView
        let restoresFocus = responder.map { $0 === titleButton || $0 === closeButton } == true
        if let previous = superview as? NSStackView { previous.removeArrangedSubview(self) }
        removeFromSuperview()
        stack.insertArrangedSubview(self, at: min(max(0, index), stack.arrangedSubviews.count))
        if restoresFocus, window === previousWindow, let responder { window?.makeFirstResponder(responder) }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { titleButton.performClick(nil) }

    override func layout() {
        super.layout()
        titleButton.contentInset = SpookkyStyle.controlInset
        widthConstraint.constant = naturalWidth
        titleButton.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - SpookkyStyle.points(closable ? 28 : 0)), height: bounds.height)
        titleButton.contentInset = min(SpookkyStyle.controlInset, max(0, (titleButton.frame.width - SpookkyStyle.iconSlot) / 2))
        closeButton.frame = NSRect(x: max(0, bounds.width - SpookkyStyle.points(28)), y: bounds.midY - SpookkyStyle.points(12), width: SpookkyStyle.points(24), height: SpookkyStyle.points(24))
        reconcileHover()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        reconcileHover()
    }
    override func mouseEntered(with event: NSEvent) { reconcilePointer(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { reconcilePointer(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { reconcilePointer(at: event.locationInWindow) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeInteractionChanges() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeInteractionChanges() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    private func observeInteractionChanges() {
        let center = NotificationCenter.default
        center.removeObserver(self)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didResizeNotification] {
                center.addObserver(self, selector: #selector(interactionGeometryChanged), name: name, object: window)
            }
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(interactionGeometryChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
        reconcileHover()
    }
    @objc private func interactionGeometryChanged(_ notification: Notification) { reconcileHover() }
    func reconcilePointer(at point: NSPoint) {
        let next = window?.isKeyWindow == true && !isHiddenOrHasHiddenAncestor && bounds.intersection(visibleRect).contains(convert(point, from: nil))
        guard hovered != next else { return }
        hovered = next
        updateInteraction()
    }
    private func reconcileHover() {
        hovered = window.map { $0.isKeyWindow && bounds.intersection(visibleRect).contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        updateInteraction()
    }
    private func focusChanged(_ focused: Bool) {
        if focused { closeButton.interactionActive = closable; needsDisplay = true }
        DispatchQueue.main.async { [weak self] in self?.updateInteraction() }
    }
    private var containsKeyboardFocus: Bool {
        titleButton.showsKeyboardFocus || closeButton.showsKeyboardFocus
    }
    private func updateAppearance() {
        titleButton.selected = selected
        titleButton.contentTintColor = selected ? SpookkyPalette.text : SpookkyPalette.secondary
        titleButton.setAccessibilityValue(selected ? "Selected" : nil)
        needsDisplay = true
    }
    private func updateInteraction() {
        let hidden = !closable || window?.isKeyWindow != true
        let active = closable && (hovered || containsKeyboardFocus)
        if closeButton.isHidden != hidden { closeButton.isHidden = hidden }
        if closeButton.interactionActive != active { closeButton.interactionActive = active }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !isHeading else { return }
        if selected || hovered || containsKeyboardFocus {
            (containsKeyboardFocus ? SpookkyPalette.keyboardFocus : selected ? SpookkyPalette.selected : SpookkyPalette.hover).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: SpookkyStyle.points(3), dy: SpookkyStyle.points(4)), xRadius: SpookkyStyle.cornerRadius, yRadius: SpookkyStyle.cornerRadius).fill()
        }
    }
}
