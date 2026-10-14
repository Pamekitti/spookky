import AppKit
import QuartzCore

final class FadingTitleButton: ActionButton {
    var revealTitle = false { didSet { if revealTitle != oldValue { needsDisplay = true } } }
    private let clip = CALayer()
    private let text = CATextLayer()
    private let fade = CAGradientLayer()
    private var animationKey = ""
    override init(_ title: String, symbol: String? = nil, help: String? = nil,
                  height: CGFloat = SpookkyStyle.controlHeight, action: @escaping () -> Void) {
        super.init(title, symbol: symbol, help: help, height: height, action: action)
        wantsLayer = true
        clip.masksToBounds = true; clip.addSublayer(text); layer?.addSublayer(clip)
        text.alignmentMode = .left; text.truncationMode = .none
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    override func layout() { super.layout(); needsDisplay = true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelReveal() }
    }
    override func viewDidHide() { super.viewDidHide(); cancelReveal() }
    private func cancelReveal() {
        text.removeAllAnimations(); animationKey = ""
        CATransaction.begin(); CATransaction.setDisableActions(true)
        text.position.x = text.bounds.width / 2
        CATransaction.commit()
    }
    override func drawTitle(in content: NSRect, tint: NSColor) {
        let label = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: tint])
        let size = label.size(), width = max(0, content.width)
        let overflow = max(0, size.width - width)
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let active = revealTitle && overflow > 1.5 && !reducedMotion
        let key = title + "|" + String(describing: width) + "|" + String(active)
        let sameTitle = (text.string as? NSAttributedString)?.string == title
        let oldPosition = sameTitle ? (text.presentation()?.position.x ?? text.position.x) : size.width / 2
        let destination = size.width / 2 - (active ? overflow : 0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clip.frame = NSRect(x: content.minX, y: bounds.midY - size.height / 2, width: width, height: size.height)
        text.string = label; text.contentsScale = window?.backingScaleFactor ?? 2
        text.bounds = NSRect(origin: .zero, size: size)
        text.position = CGPoint(x: destination, y: size.height / 2)
        fade.frame = clip.bounds
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, NSNumber(value: max(0, Double(width - 14) / max(1, Double(width)))), 1]
        clip.mask = overflow > 1.5 && !active ? fade : nil
        CATransaction.commit()
        if key != animationKey {
            text.removeAllAnimations()
            if overflow > 1.5, oldPosition != destination, !reducedMotion {
                let animation = CABasicAnimation(keyPath: "position.x")
                animation.fromValue = oldPosition; animation.toValue = destination
                animation.duration = active ? min(6, max(0.5, overflow / 32)) : 0.2
                animation.beginTime = CACurrentMediaTime() + (active ? 0.35 : 0)
                animation.timingFunction = CAMediaTimingFunction(name: active ? .linear : .easeOut)
                animation.fillMode = .backwards
                text.add(animation, forKey: "reveal")
            }
            animationKey = key
        }
    }
}
