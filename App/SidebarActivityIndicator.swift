import AppKit
import QuartzCore
import SpookkyCore

@MainActor final class SidebarActivityIndicator: NSView {
    var activity: AgentActivityState? { didSet { updateAnimation(); needsDisplay = true } }
    private let spinner = CAShapeLayer()
    var rotating: Bool { spinner.animation(forKey: "rotation") != nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.addSublayer(spinner)
        spinner.fillColor = nil; spinner.lineWidth = 1.5; spinner.strokeEnd = 0.82; spinner.lineCap = .round
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
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spinner.frame = bounds
        let size = SpookkyStyle.points(10)
        spinner.path = CGPath(ellipseIn: NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size), transform: nil)
        spinner.lineWidth = SpookkyStyle.points(1.2)
        effectiveAppearance.performAsCurrentDrawingAppearance { spinner.strokeColor = SidebarPalette.secondary.cgColor }
        CATransaction.commit(); updateAnimation()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true; needsDisplay = true }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func displayOptionsChanged() { updateAnimation(); needsDisplay = true }
    @objc func updateAnimation() {
        let visible = !isHiddenOrHasHiddenAncestor && !bounds.intersection(visibleRect).isEmpty && window?.occlusionState.contains(.visible) == true
        spinner.isHidden = activity != .working || !visible
        if activity == .working && visible && !SidebarMotion.reduced {
            if spinner.animation(forKey: "rotation") == nil {
                let animation = CABasicAnimation(keyPath: "transform.rotation.z")
                animation.fromValue = 0; animation.toValue = 2 * Double.pi; animation.duration = 1; animation.repeatCount = .infinity
                spinner.add(animation, forKey: "rotation")
            }
        } else { spinner.removeAllAnimations() }
    }
    override func draw(_ dirtyRect: NSRect) {
        switch activity {
        case .finished:
            SidebarPalette.blue.setFill()
            let size = SpookkyStyle.points(8)
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)).fill()
        case .failed:
            let text = NSAttributedString(string: "!", attributes: [.font: NSFont.systemFont(ofSize: SpookkyStyle.points(12), weight: .semibold), .foregroundColor: SpookkyPalette.destructive])
            text.draw(at: NSPoint(x: bounds.midX - text.size().width / 2, y: bounds.midY - text.size().height / 2))
        case .needsInput:
            SidebarPalette.inputFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
            let text = NSAttributedString(string: "Needs input", attributes: [.font: NSFont.systemFont(ofSize: SpookkyStyle.points(13)), .foregroundColor: SidebarPalette.blue])
            text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2, y: (bounds.height - text.size().height) / 2))
        default: break
        }
    }
}
