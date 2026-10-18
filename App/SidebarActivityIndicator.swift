import AppKit
import SpookkyCore

@MainActor final class SidebarActivityIndicator: NSView {
    var activity: AgentActivityState? { didSet { updateAnimation(); needsDisplay = true } }
    private let spinner = NSProgressIndicator()
    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.isIndeterminate = true; spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false); addSubview(spinner)
        setAccessibilityElement(false)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(updateAnimation), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updateAnimation()
    }
    override func layout() { super.layout(); spinner.frame = bounds; updateAnimation() }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func displayOptionsChanged() { updateAnimation(); needsDisplay = true }
    @objc func updateAnimation() {
        let visible = !isHiddenOrHasHiddenAncestor && !bounds.intersection(visibleRect).isEmpty && window?.occlusionState.contains(.visible) == true
        if activity == .working && visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
    }
    override func draw(_ dirtyRect: NSRect) {
        switch activity {
        case .needsInput, .finished:
            (activity == .needsInput ? SpookkyPalette.warning : NSColor.systemBlue).setFill()
            let size = SpookkyStyle.points(6)
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)).fill()
        case .failed:
            let text = NSAttributedString(string: "!", attributes: [.font: NSFont.systemFont(ofSize: SpookkyStyle.points(12), weight: .semibold), .foregroundColor: SpookkyPalette.destructive])
            text.draw(at: NSPoint(x: bounds.midX - text.size().width / 2, y: bounds.midY - text.size().height / 2))
        case .working where NSWorkspace.shared.accessibilityDisplayShouldReduceMotion:
            SpookkyPalette.secondary.setStroke()
            let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)); path.lineWidth = 1; path.stroke()
        default: break
        }
    }
}
