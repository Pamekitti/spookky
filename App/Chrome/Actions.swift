import AppKit
import ImageIO
import SpookkyCore
import SpookkyGit
import SpookkySyntax
import SpookkyWorkspace
import UniformTypeIdentifiers

class ActionButton: NSButton {
    enum Emphasis { case quiet, secondary, primary, destructive }
    var emphasis: Emphasis = .quiet { didSet { needsDisplay = true } }
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var drawsInteractionFill = true
    var circular = false
    var detail: String?
    var handler: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    var onNavigate: ((UInt16) -> Void)?
    var onCancel: (() -> Void)?
    var contentInset: CGFloat = SpookkyStyle.controlInset
    var menuIndicator = false { didSet { invalidateIntrinsicContentSize() } }
    var compactUtility = false
    var alignsToBounds = false
    var revealOnInteraction = false { didSet { updateInteractionVisibility() } }
    var interactionActive = false { didSet { updateInteractionVisibility() } }
    var onFocusChange: ((Bool) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var keyboardFocused = false
    private var receivingPointer = false
    private var iconCache: (source: NSImage, color: NSColor, size: CGFloat, image: NSImage)?
    var showsKeyboardFocus: Bool { keyboardFocused && window?.firstResponder === self && window?.isKeyWindow == true }
    private let targetHeight: CGFloat
    var isRevealed: Bool { !revealOnInteraction || interactionActive || keyboardFocused }
    func updateInteractionVisibility() {
        alphaValue = isRevealed ? 1 : 0
        setAccessibilityElement(isRevealed)
        setAccessibilityRole(.button)
        needsDisplay = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { isRevealed ? super.hitTest(point) : nil }
    private var hovered = false
    private var tracking: NSTrackingArea?
    init(_ title: String, symbol: String? = nil, help: String? = nil, height: CGFloat? = nil, action: @escaping () -> Void) {
        let height = height ?? SpookkyStyle.controlHeight
        handler = action; targetHeight = height / DisplayMetrics.preferences.zoom
        super.init(frame: .zero)
        self.title = title; target = self; self.action = #selector(invoke)
        isBordered = false; SpookkyStyle.suppressFocusRing(self); font = .systemFont(ofSize: SpookkyStyle.points(13))
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
        compactUtility = symbol == "plus" || symbol == "xmark"
        toolTip = help ?? title; setAccessibilityLabel(help ?? title)
        heightAnchor.constraint(greaterThanOrEqualToConstant: height).displayScaled(alreadyScaled: true).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    override var alignmentRectInsets: NSEdgeInsets {
        // Custom targets can opt out of native symbol alignment outside their bounds.
        alignsToBounds || (compactUtility || circular) && title.isEmpty ? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) : super.alignmentRectInsets
    }
    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: SpookkyStyle.points(13))]).width
        let iconWidth = image == nil ? 0 : SpookkyStyle.iconSlot + SpookkyStyle.iconLabelGap
        return NSSize(width: title.isEmpty ? SpookkyStyle.points(targetHeight) :
            ceil(text) + 1 + 2 * contentInset + iconWidth + (menuIndicator ? 16 : 0), height: SpookkyStyle.points(targetHeight))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; onHoverChange?(true); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; onHoverChange?(false); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { keyboardFocused = !receivingPointer; updateInteractionVisibility(); onFocusChange?(keyboardFocused) }
        needsDisplay = true; return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { keyboardFocused = false; updateInteractionVisibility(); onFocusChange?(false) }
        needsDisplay = true; return result
    }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true
        let compact = compactUtility && title.isEmpty
        let fillBounds = circular ? bounds : compact ? NSRect(x: bounds.midX - SpookkyStyle.points(10), y: bounds.midY - SpookkyStyle.points(10), width: SpookkyStyle.points(20), height: SpookkyStyle.points(20)) : bounds.insetBy(dx: 1, dy: 1)
        let shape = circular ? NSBezierPath(ovalIn: fillBounds) : NSBezierPath(roundedRect: fillBounds, xRadius: compact ? 5 : SpookkyStyle.cornerRadius, yRadius: compact ? 5 : SpookkyStyle.cornerRadius)
        let fill: NSColor = switch emphasis {
        case .primary: SpookkyPalette.text
        case .secondary: SpookkyPalette.raised
        case .destructive: SpookkyPalette.destructive
        case .quiet: pressed || selected ? SpookkyPalette.selected : showsKeyboardFocus ? SpookkyPalette.keyboardFocus : hovered ? SpookkyPalette.hover : .clear
        }
        if emphasis != .quiet || drawsInteractionFill && (selected || pressed || (hovered || showsKeyboardFocus) && isEnabled) {
            fill.withAlphaComponent(fill.alphaComponent * (isEnabled ? 1 : 0.45)).setFill(); shape.fill()
        }
        if emphasis != .quiet, isEnabled, pressed || hovered || showsKeyboardFocus {
            let overlay = emphasis == .secondary ? (pressed ? SpookkyPalette.selected : SpookkyPalette.hover)
                : SpookkyPalette.background.withAlphaComponent(pressed ? 0.15 : 0.08)
            overlay.setFill(); shape.fill()
        }
        let baseTint: NSColor = switch emphasis {
        case .primary: SpookkyPalette.background
        case .destructive: .white
        case .secondary: SpookkyPalette.text
        case .quiet: contentTintColor ?? (title.isEmpty && !hovered && !selected ? SpookkyPalette.secondary : SpookkyPalette.text)
        }
        let tint = baseTint.withAlphaComponent(isEnabled ? 1 : 0.45)
        var content = bounds.insetBy(dx: contentInset, dy: 0)
        if menuIndicator {
            let arrow = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 9, weight: .medium).applying(.init(paletteColors: [tint])))
            arrow?.draw(in: NSRect(x: content.maxX - 10, y: bounds.midY - 5, width: 10, height: 10))
            content.size.width = max(0, content.width - 16)
        }
        if let image {
            let utility = title.isEmpty
            let config = NSImage.SymbolConfiguration(
                pointSize: utility ? (compactUtility ? SpookkyStyle.points(12) : SpookkyStyle.utilityIconSize) : SpookkyStyle.leadingIconSize,
                weight: utility && !compactUtility ? .medium : .regular).applying(.init(paletteColors: [tint]))
            let symbol = image.withSymbolConfiguration(config) ?? image
            let slot = NSRect(x: utility ? bounds.midX - SpookkyStyle.iconSlot / 2 : content.minX,
                y: bounds.midY - SpookkyStyle.iconSlot / 2, width: SpookkyStyle.iconSlot, height: SpookkyStyle.iconSlot)
            let size = symbol.size
            let scale = min(1, SpookkyStyle.iconSlot / max(size.width, size.height, 1))
            let drawn = NSRect(x: slot.midX - size.width * scale / 2, y: slot.midY - size.height * scale / 2,
                width: size.width * scale, height: size.height * scale)
            if image.isTemplate {
                let resolved = tint.usingColorSpace(.deviceRGB) ?? tint
                let cached: NSImage
                if let iconCache, iconCache.source === image, iconCache.color == resolved, iconCache.size == SpookkyStyle.iconSlot {
                    cached = iconCache.image
                } else {
                    cached = NSImage(size: symbol.size, flipped: false) { bounds in
                        symbol.draw(in: bounds); resolved.setFill(); bounds.fill(using: .sourceAtop); return true
                    }
                    iconCache = (image, resolved, SpookkyStyle.iconSlot, cached)
                }
                cached.draw(in: backingAligned(drawn))
            } else { symbol.draw(in: backingAligned(drawn)) }
            if !utility {
                let width = SpookkyStyle.iconSlot + SpookkyStyle.iconLabelGap
                content.origin.x += width; content.size.width = max(0, content.width - width)
            }
        }
        drawTitle(in: content, tint: tint)
    }
    private func backingAligned(_ rect: NSRect) -> NSRect {
        let backing = convertToBacking(rect)
        return convertFromBacking(NSRect(x: backing.minX.rounded(), y: backing.minY.rounded(), width: backing.width.rounded(), height: backing.height.rounded()))
    }
    func drawTitle(in content: NSRect, tint: NSColor) {
        guard !title.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = alignment
        let label = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: SpookkyStyle.points(13)), .foregroundColor: tint, .paragraphStyle: paragraph])
        let h = label.size().height
        let detailOffset = SpookkyStyle.points(8) * (isFlipped ? -1 : 1)
        label.draw(in: NSRect(x: content.minX, y: bounds.midY - h / 2 + (detail == nil ? 0 : detailOffset), width: content.width, height: h))
        if let detail {
            let text = NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: SpookkyStyle.points(11)), .foregroundColor: SpookkyPalette.secondary, .paragraphStyle: paragraph])
            text.draw(in: NSRect(x: content.minX, y: bounds.midY - detailOffset - text.size().height / 2, width: content.width, height: text.size().height))
        }
    }
    @objc private func invoke() { handler?() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        keyboardFocused = true; updateInteractionVisibility(); onFocusChange?(true)
        if event.keyCode == 53, let onCancel { onCancel() }
        else if event.keyCode == 109, event.modifierFlags.contains(.shift), let menu = onContextMenu?() {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
            if window?.attachedSheet == nil { window?.makeFirstResponder(self) }
        } else if [123, 124, 125, 126].contains(event.keyCode), let onNavigate {
            onNavigate(event.keyCode)
        } else if event.keyCode == 49 || event.keyCode == 36 {
            performClick(nil)
        } else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        receivingPointer = true; keyboardFocused = false; updateInteractionVisibility(); onFocusChange?(false)
        defer { receivingPointer = false }
        if event.clickCount == 2, let onDoubleClick { onDoubleClick() } else { super.mouseDown(with: event) }
    }
}

final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ContextRow: NSView {
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    private var hovered = false
    private var focusedControls = Set<ObjectIdentifier>()
    private var hoveredControls = Set<ObjectIdentifier>()
    var onInteractionChange: ((Bool) -> Void)?
    var interactionActive: Bool { hovered || !hoveredControls.isEmpty || !focusedControls.isEmpty }
    func trackHover(_ button: ActionButton, _ inside: Bool) {
        if inside { hoveredControls.insert(ObjectIdentifier(button)) } else { hoveredControls.remove(ObjectIdentifier(button)) }
        onInteractionChange?(interactionActive); needsDisplay = true
    }
    func trackFocus(_ button: ActionButton, _ focused: Bool) {
        if focused { focusedControls.insert(ObjectIdentifier(button)) } else { focusedControls.remove(ObjectIdentifier(button)) }
        onInteractionChange?(interactionActive); needsDisplay = true
    }
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; onInteractionChange?(interactionActive); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; onInteractionChange?(interactionActive); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if selected || interactionActive {
            (selected ? SpookkyPalette.selected : SpookkyPalette.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: SpookkyStyle.cornerRadius, yRadius: SpookkyStyle.cornerRadius).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func mouseDown(with event: NSEvent) { primary?.handler?() }
    var icon: NSImageView?
    var statusBadge: NSImageView?
    var restingIcon: NSImage?
    var groupCollapsed = false
    var primary: ActionButton?
    var secondaryButton: ActionButton?
    var metadata: NSTextField?
    var secondary: (() -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { secondary?() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109, event.modifierFlags.contains(.shift), let menu = secondary?() {
            menu.popUp(positioning: nil, at: NSPoint(x: 12, y: bounds.height), in: self)
        } else { super.keyDown(with: event) }
    }
}
