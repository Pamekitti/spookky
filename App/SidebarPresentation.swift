import AppKit
import QuartzCore
import SpookkyCore

@MainActor enum SidebarPalette {
    static let background = SpookkyPalette.color("151515", "f3f3f3")
    static let text = SpookkyPalette.color("d9d9d9", "252525")
    static let secondary = SpookkyPalette.color("929292", "656565")
    static let hover = SpookkyPalette.color("272727", "e6e6e6")
    static let selected = SpookkyPalette.color("2d2d2d", "dfdfdf")
    static let blue = SpookkyPalette.color("3686fc", "176bd6")
    static let inputFill = SpookkyPalette.color("1f2536", "dfeafb")
    static let card = SpookkyPalette.color("262626", "ffffff")
    static let border = SpookkyPalette.color("393939", "d5d5d5")
    static func pullRequest(_ state: PullRequestState) -> NSColor {
        switch state {
        case .draft: secondary
        case .open: SpookkyPalette.color("54b979", "16763b")
        case .closed: SpookkyPalette.color("ed6a66", "c52e2b")
        case .merged: SpookkyPalette.color("b26aff", "8240c9")
        }
    }
}

@MainActor enum SidebarMotion {
    // The override belongs only to the disposable native acceptance fixture.
    static var reducedOverride: Bool?
    static var reduced: Bool { reducedOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

@MainActor enum SidebarSymbols {
    static let worktree: NSImage = {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            let path = NSBezierPath(); path.lineWidth = 1; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 1, y: 7)); path.line(to: NSPoint(x: 6, y: 7)); path.line(to: NSPoint(x: 12, y: 12))
            path.move(to: NSPoint(x: 8, y: 12)); path.line(to: NSPoint(x: 12, y: 12)); path.line(to: NSPoint(x: 12, y: 8))
            path.move(to: NSPoint(x: 8, y: 5)); path.line(to: NSPoint(x: 12, y: 1))
            path.move(to: NSPoint(x: 8, y: 1)); path.line(to: NSPoint(x: 12, y: 1)); path.line(to: NSPoint(x: 12, y: 5))
            NSColor.black.setStroke(); path.stroke(); return true
        }
        image.isTemplate = true; return image
    }()
    static let merged: NSImage = {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            let path = NSBezierPath(); path.lineWidth = 1.1; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 3, y: 9.25)); path.line(to: NSPoint(x: 3, y: 4.75))
            path.move(to: NSPoint(x: 3, y: 9.25)); path.curve(to: NSPoint(x: 9.25, y: 6), controlPoint1: NSPoint(x: 3, y: 6), controlPoint2: NSPoint(x: 6, y: 6))
            for center in [NSPoint(x: 3, y: 11), NSPoint(x: 3, y: 3), NSPoint(x: 11, y: 6)] {
                path.appendOval(in: NSRect(x: center.x - 1.75, y: center.y - 1.75, width: 3.5, height: 3.5))
            }
            NSColor.black.setStroke(); path.stroke(); return true
        }
        image.isTemplate = true; return image
    }()
    static let pin: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let transform = NSAffineTransform(); transform.translateX(by: 8, yBy: 8); transform.rotate(byDegrees: -40); transform.concat()
            NSImage(systemSymbolName: "pin", accessibilityDescription: nil)?.draw(in: NSRect(x: -6, y: -6, width: 12, height: 12))
            return true
        }
        image.isTemplate = true; return image
    }()
}

@MainActor final class SidebarTitleField: NSTextField {
    var revealing = false { didSet { if oldValue != revealing { updateReveal() } } }
    private let clip = CALayer(), textLayer = CALayer(), fade = CAGradientLayer()
    private var animationKey = ""
    private(set) var animating = false
    var revealOffset: CGFloat { animating ? textLayer.presentation()?.transform.m41 ?? textLayer.transform.m41 : 0 }
    init() {
        super.init(frame: .zero)
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        lineBreakMode = .byTruncatingTail; maximumNumberOfLines = 1
        wantsLayer = true; clip.masksToBounds = true; clip.addSublayer(textLayer); layer?.addSublayer(clip)
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    override var stringValue: String { didSet { if oldValue != stringValue { updateReveal() } } }
    override func layout() { super.layout(); updateReveal() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateReveal() }
    override func viewDidHide() { super.viewDidHide(); stopReveal() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); animationKey = ""; updateReveal() }
    override func draw(_ dirtyRect: NSRect) { if !animating { super.draw(dirtyRect) } }
    func stopReveal() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        textLayer.removeAllAnimations(); textLayer.transform = CATransform3DIdentity; textLayer.contents = nil
        fade.removeAllAnimations(); clip.isHidden = true
        CATransaction.commit()
        animating = false; animationKey = ""; needsDisplay = true
    }
    private func textImage(size: NSSize, scale: CGFloat) -> CGImage? {
        let pixelsWide = ceil(size.width * scale), pixelsHigh = ceil(size.height * scale)
        guard pixelsWide > 0, pixelsHigh > 0, pixelsWide <= 16_384, pixelsHigh <= 16_384,
              pixelsWide * pixelsHigh <= 4_194_304,
              let textCell = cell?.copy() as? NSTextFieldCell,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixelsWide),
                pixelsHigh: Int(pixelsHigh), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        textCell.lineBreakMode = .byClipping
        context.cgContext.scaleBy(x: scale, y: scale)
        if isFlipped { context.cgContext.translateBy(x: 0, y: size.height); context.cgContext.scaleBy(x: 1, y: -1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: isFlipped)
        effectiveAppearance.performAsCurrentDrawingAppearance { textCell.draw(withFrame: NSRect(origin: .zero, size: size), in: self) }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }
    func updateReveal() {
        let font = font ?? .systemFont(ofSize: SpookkyStyle.points(14))
        let overflow = max(0, ceil(cell?.cellSize.width ?? 0) - bounds.width)
        let active = revealing && !SidebarMotion.reduced && overflow > 1 && bounds.height > 0 && window?.isKeyWindow == true &&
            window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
        guard active else { if animating { stopReveal() }; return }
        let scale = window?.backingScaleFactor ?? 2
        let key = stringValue + "|\(bounds.size)|\(font)|\(String(describing: textColor))|\(scale)"
        guard key != animationKey else { return }
        stopReveal()
        let size = NSSize(width: bounds.width + overflow, height: bounds.height)
        guard let image = textImage(size: size, scale: scale) else { return }
        animationKey = key; animating = true
        let travel = Double(overflow / SpookkyStyle.points(30)), duration = 0.5 + travel
        let edgeTime = min(travel / 2, Double(SpookkyStyle.points(8) / SpookkyStyle.points(30)))
        let opaque = NSColor.black.cgColor, clear = NSColor.clear.cgColor
        let start = [opaque, opaque, opaque, clear], moving = [clear, opaque, opaque, clear], end = [clear, opaque, opaque, opaque]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clip.frame = bounds; clip.isHidden = false
        textLayer.frame = NSRect(origin: .zero, size: size); textLayer.contentsScale = scale; textLayer.contents = image
        textLayer.transform = CATransform3DMakeTranslation(-overflow, 0, 0)
        fade.frame = clip.bounds; fade.colors = end
        let fraction = min(0.2, SpookkyStyle.points(8) / max(1, bounds.width))
        fade.locations = [0, NSNumber(value: fraction), NSNumber(value: 1 - fraction), 1]; clip.mask = fade
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -overflow]
        animation.keyTimes = [0, NSNumber(value: 0.5 / duration), 1]
        animation.duration = duration; animation.calculationMode = .linear
        textLayer.add(animation, forKey: "sidebar-title")
        let mask = CAKeyframeAnimation(keyPath: "colors")
        mask.values = [start, start, moving, moving, end]
        mask.keyTimes = [0, NSNumber(value: 0.5 / duration), NSNumber(value: (0.5 + edgeTime) / duration), NSNumber(value: (duration - edgeTime) / duration), 1]
        mask.duration = duration; mask.calculationMode = .linear
        fade.add(mask, forKey: "sidebar-title-fade")
        CATransaction.commit(); needsDisplay = true
    }
}

@MainActor private final class SidebarHoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class SidebarHoverCard {
    private let panel = SidebarHoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let content = SidebarHoverContent()
    var onExit: (() -> Void)? { didSet { content.onExit = onExit } }
    var frame: NSRect { panel.frame }
    var isVisible: Bool { panel.isVisible }
    var visibleContent: NSView? { panel.isVisible ? content : nil }
    init() {
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
        panel.contentView = content
    }
    func show(_ item: WorkspaceSidebarItem, relativeTo rect: NSRect, in window: NSWindow) {
        content.configure(item); content.layoutSubtreeIfNeeded()
        let width = SpookkyStyle.points(320)
        let size = content.sizeThatFits(width)
        let anchor = window.convertToScreen(rect)
        let screen = window.screen?.visibleFrame ?? anchor.insetBy(dx: -width, dy: -400)
        let origin = NSPoint(x: min(max(screen.minX + 4, anchor.maxX - SpookkyStyle.points(5)), screen.maxX - size.width - 4),
            y: min(max(screen.minY + 4, anchor.maxY - size.height), screen.maxY - size.height - 4))
        panel.appearance = window.effectiveAppearance; panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window { panel.parent?.removeChildWindow(panel); window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
    func close() { panel.orderOut(nil); panel.parent?.removeChildWindow(panel) }
}

@MainActor private final class SidebarHoverContent: NSView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let time = SpookkyStyle.label("")
    private let project = SpookkyStyle.label("")
    private let folder = NSImageView()
    private let worktree = NSImageView()
    private let pr = ActionButton("", symbol: "arrow.triangle.pull", action: {})
    private var tracking: NSTrackingArea?
    var onExit: (() -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.isSelectable = false; title.textColor = SidebarPalette.text
        time.textColor = SidebarPalette.secondary; project.textColor = SidebarPalette.text
        folder.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); folder.contentTintColor = SidebarPalette.secondary
        worktree.image = SidebarSymbols.worktree; worktree.contentTintColor = SidebarPalette.secondary
        pr.drawsInteractionFill = false; pr.compactUtility = true
        [title, time, project, folder, worktree, pr].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    func configure(_ item: WorkspaceSidebarItem) {
        title.stringValue = item.title; title.font = .systemFont(ofSize: SpookkyStyle.points(14))
        title.preferredMaxLayoutWidth = SpookkyStyle.points(230)
        project.stringValue = item.projectName ?? "No project"
        time.stringValue = item.updatedAt.map {
            let seconds = max(0, Int(Date().timeIntervalSince($0)))
            if seconds < 60 { return "now" }
            if seconds < 3600 { return "\(seconds / 60)m" }
            if seconds < 86400 { return "\(seconds / 3600)h" }
            return "\(seconds / 86400)d"
        } ?? ""
        time.font = .systemFont(ofSize: SpookkyStyle.points(11))
        worktree.isHidden = item.checkout?.linkedWorktree != true
        pr.isHidden = item.pullRequest == nil
        if let status = item.pullRequest {
            pr.image = status.state == .merged ? SidebarSymbols.merged : NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)
            pr.toolTip = status.label; pr.setAccessibilityLabel("Open " + status.label)
            pr.contentTintColor = SidebarPalette.pullRequest(status.state)
            pr.handler = { NSWorkspace.shared.open(status.association.url) }
        }
        setAccessibilityLabel(item.help); needsLayout = true; needsDisplay = true
    }
    func sizeThatFits(_ width: CGFloat) -> NSSize {
        let rect = (title.stringValue as NSString).boundingRect(with: NSSize(width: width - SpookkyStyle.points(worktree.isHidden ? 65 : 90), height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: title.font!])
        return NSSize(width: width, height: max(SpookkyStyle.points(60), ceil(rect.height) + SpookkyStyle.points(42)))
    }
    override func layout() {
        super.layout(); let p = SpookkyStyle.points
        let titleHeight = max(p(18), bounds.height - p(42))
        title.frame = NSRect(x: p(9), y: p(9), width: bounds.width - p(worktree.isHidden ? 65 : 90), height: titleHeight)
        time.frame = NSRect(x: bounds.width - p(53), y: p(12), width: p(45), height: p(16)); time.lineBreakMode = .byTruncatingTail
        worktree.frame = NSRect(x: bounds.width - p(79), y: p(11), width: p(14), height: p(14))
        folder.frame = NSRect(x: p(10), y: title.frame.maxY + p(8), width: p(14), height: p(14))
        project.frame = NSRect(x: p(32), y: title.frame.maxY + p(6), width: bounds.width - p(66), height: p(20))
        pr.frame = NSRect(x: bounds.width - p(36), y: title.frame.maxY + p(2), width: p(28), height: p(28))
    }
    override func draw(_ dirtyRect: NSRect) {
        SidebarPalette.card.setFill(); let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: SpookkyStyle.points(14), yRadius: SpookkyStyle.points(14))
        shape.fill(); SidebarPalette.border.setStroke(); shape.lineWidth = 1; shape.stroke()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
