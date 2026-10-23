import AppKit
import ImageIO
import SpookkyCore
import SpookkyGit
import SpookkySyntax
import SpookkyWorkspace
import UniformTypeIdentifiers

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("Use init") }
    @objc private func invoke() { handler() }
}

final class WorkspaceHeaderView: NSView {
    var sidebarWidth: CGFloat = SpookkyStyle.sidebarWidth { didSet { needsDisplay = true } }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { (window as? WorkspaceNativeWindow)?.dragHeader(with: event) }
    override func draw(_ dirtyRect: NSRect) {
        SpookkyPalette.background.setFill(); bounds.fill()
        SidebarPalette.background.setFill(); NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height).fill()
        SpookkyPalette.border.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
final class TabStripScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let maximum = max(0, (documentView?.bounds.width ?? 0) - contentView.bounds.width)
        contentView.scroll(to: NSPoint(x: min(maximum, max(0, contentView.bounds.minX - delta * (event.hasPreciseScrollingDeltas ? 1 : 10))), y: 0))
        reflectScrolledClipView(contentView)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { (window as? WorkspaceNativeWindow)?.dragHeader(with: event) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target === contentView || target === documentView ? self : target
    }
}

final class WorkspaceNativeWindow: NSWindow {
    var acceptsUserFocus = true
    var allowsHeaderDragging = true
    override var canBecomeKey: Bool { acceptsUserFocus && super.canBecomeKey }
    override var canBecomeMain: Bool { acceptsUserFocus && super.canBecomeMain }
    var onPointerMove: ((NSEvent) -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved || event.type == .leftMouseDragged { onPointerMove?(event) }
        super.sendEvent(event)
    }
    func positionWindowButtons(headerHeight: CGFloat) {
        guard !styleMask.contains(.fullScreen), let content = contentView else { return }
        let buttons = [ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { standardWindowButton($0) }
        guard let first = buttons.first, let parent = first.superview else { return }
        let origin = content.convert(NSPoint(x: 20, y: content.bounds.height - headerHeight / 2), to: parent)
        let offset = origin.x - first.frame.minX
        for button in buttons {
            let point = NSPoint(x: button.frame.minX + offset, y: origin.y - button.frame.height / 2)
            if button.frame.origin != point { button.setFrameOrigin(point) }
        }
    }
    var onCommand: ((NSEvent) -> Bool)?
    func dragHeader(with event: NSEvent) {
        guard allowsHeaderDragging, !styleMask.contains(.fullScreen) else { return }
        performDrag(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onCommand?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
