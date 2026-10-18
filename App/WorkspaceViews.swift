import AppKit
import SpookkyCore
import SpookkyGit
import SpookkySyntax

enum SpookkyPalette {
    static func color(_ dark: String, _ light: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            let value = UInt32(hex, radix: 16)!
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
    static func foregroundWash(dark: CGFloat, light: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let base = isDark ? NSColor(srgbRed: 234 / 255, green: 232 / 255, blue: 230 / 255, alpha: 1)
                : NSColor(srgbRed: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)
            return base.withAlphaComponent(isDark ? dark : light)
        }
    }
    static let background = color("151110", "f9f9fa")
    static let sidebar = color("1a1716", "ececec")
    static let raised = color("201e1c", "ffffff")
    static let border = color("2a2827", "e5e5e5")
    static let ring = color("3a3837", "a1a1a1")
    static let selected = foregroundWash(dark: 0.10, light: 0.06)
    static let hover = foregroundWash(dark: 0.07, light: 0.04)
    static let keyboardFocus = foregroundWash(dark: 0.16, light: 0.10)
    static let text = color("eae8e6", "0a0a0a")
    static let secondary = color("a8a5a3", "4a4847")
    static let metadata = color("9a9795", "605e5d")
    static let destructive = color("cc4444", "e7000b")
    static let warning = color("e5c07b", "906d01")
    static let success = color("5fb37f", "009966")
    static let addition = color("203329", "e5f2e8")
    static let removal = color("3b2424", "fbe7e7")
    static func syntax(_ role: SyntaxRole) -> NSColor {
        switch role {
        case .keyword: return color("c678dd", "75507b")
        case .comment: return metadata
        case .string: return color("7ec699", "3e7905")
        case .number: return color("e5c07b", "805600")
        case .function: return color("61afef", "3465a4")
        case .type: return color("56b6c2", "07666d")
        case .variable: return color("dc6b6b", "9d1732")
        }
    }
}
final class WorkspaceRootView: NSView {
    var onAppearance: (() -> Void)?
    var onBeforeLayout: (() -> Void)?
    var onLayout: (() -> Void)?
    override func layout() { onBeforeLayout?(); super.layout(); onLayout?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearance?() }
}

@MainActor enum SpookkyStyle {
    static func points(_ value: CGFloat) -> CGFloat { DisplayMetrics.points(value) }
    static var controlHeight: CGFloat { points(28) }
    static var compactHeight: CGFloat { points(24) }
    static var headerHeight: CGFloat { points(40) }
    static var workspaceRowHeight: CGFloat { points(32) }
    static var sidebarWidth: CGFloat { points(232) }
    static var sidebarOuterInset: CGFloat { points(12) }
    static var railWidth: CGFloat { points(58) }
    static var fileSidebarWidth: CGFloat { points(248) }
    static var composerWidth: CGFloat { points(800) }
    static var composerRadius: CGFloat { points(13) }
    static var cornerRadius: CGFloat { points(8) }
    static var iconSlot: CGFloat { points(16) }
    static var leadingIconSize: CGFloat { points(14) }
    static var utilityIconSize: CGFloat { points(14) }
    static var iconLabelGap: CGFloat { points(6) }
    static var controlInset: CGFloat { points(8) }
    static func configure(_ control: NSControl, size: CGFloat = 12) {
        suppressFocusRing(control)
        control.font = .systemFont(ofSize: points(size))
        control.controlSize = .small
        if let popup = control as? NSPopUpButton { popup.isBordered = false }
    }
    static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: points(13)); return field
    }
    static func suppressFocusRing(_ control: NSControl) {
        control.focusRingType = .none; control.cell?.focusRingType = .none
    }
    static func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    static func fieldGroup(_ title: String, control: NSControl) -> NSStackView {
        let label = SpookkyStyle.label( title)
        label.font = .systemFont(ofSize: SpookkyStyle.points(11)); label.textColor = SpookkyPalette.metadata
        let group = NSStackView(views: [label, control])
        group.orientation = .vertical; group.alignment = .leading; group.spacing = SpookkyStyle.points(4)
        group.setContentHuggingPriority(.required, for: .vertical)
        control.heightAnchor.constraint(equalToConstant: controlHeight).isActive = true
        control.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }
    static func monogram(_ title: String) -> NSImage {
        let words = title.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let letters = words.count > 1 ? String(words.prefix(2).compactMap(\.first)) : String(title.prefix(2))
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { bounds in
            SpookkyPalette.selected.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
            let value = NSAttributedString(string: letters.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: SpookkyStyle.points(8), weight: .semibold), .foregroundColor: SpookkyPalette.secondary])
            let size = value.size(); value.draw(at: NSPoint(x: (16 - size.width) / 2, y: (16 - size.height) / 2)); return true
        }
    }
    static func toolImage(_ tool: SessionTool) -> NSImage? {
        guard tool != .shell else { return NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal") }
        let name = tool == .codex ? "ProviderCodex" : "ProviderClaude"
        let image = NSImage(named: name)?.copy() as? NSImage
        image?.size = NSSize(width: leadingIconSize, height: leadingIconSize)
        image?.isTemplate = true
        image?.accessibilityDescription = tool.displayName
        return image
    }
    static func supportingSymbol(_ target: SupportingTarget) -> String {
        switch target {
        case .startPage: "globe"
        case .changes: "arrow.triangle.branch"
        case .file: "doc.text"
        case .browser: "globe"
        case .artifact: "doc.richtext"
        case .terminal: "terminal"
        }
    }
    static func toolSymbol(_ tool: SessionTool) -> String {
        switch tool { case .shell: "terminal"; case .codex: "chevron.left.forwardslash.chevron.right"; case .claude: "sparkles" }
    }
    static func statusSymbol(_ status: TabStatus) -> String? {
        switch status {
        case .draft, .running: nil
        case .preparing, .launching: "clock"
        case .reconnecting: "arrow.clockwise"
        case .ended: "stop.circle"
        case .failed: "exclamationmark.triangle"
        case .uncertain: "questionmark.circle"
        case .unavailable: "network.slash"
        }
    }
    static func statusLabel(_ status: TabStatus) -> String {
        switch status {
        case .draft: "Not started"; case .preparing: "Preparing location"; case .launching: "Starting CLI"
        case .running: "Running process"; case .reconnecting: "Reconnecting"; case .ended: "Session ended"
        case .failed: "Failed"; case .uncertain: "Needs checking"; case .unavailable: "Unavailable"
        }
    }
    static func fileSymbol(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased(), ext = (name as NSString).pathExtension
        if ["package.json", "makefile", "dockerfile", "cargo.toml", ".gitignore", ".gitattributes", ".editorconfig"].contains(name) || ["json", "yaml", "yml", "toml", "ini", "conf", "config", "lock"].contains(ext) { return "gearshape" }
        if ["swift", "py", "js", "jsx", "ts", "tsx", "rs", "go", "sh", "bash", "zsh", "html", "css", "sql", "c", "h", "cpp", "java", "rb"].contains(ext) { return "chevron.left.forwardslash.chevron.right" }
        if ["md", "markdown", "txt", "rtf", "pdf", "doc", "docx"].contains(ext) { return "doc.richtext" }
        if ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "ico"].contains(ext) { return "photo" }
        if ["zip", "gz", "tar", "bz2", "xz", "7z"].contains(ext) { return "archivebox" }
        return "doc"
    }
}

final class ChromeTextField: NSTextField {
    override init(frame: NSRect = .zero) { super.init(frame: frame); SpookkyStyle.suppressFocusRing(self) }
    required init?(coder: NSCoder) { super.init(coder: coder); SpookkyStyle.suppressFocusRing(self) }
}
final class ChromeSearchField: NSSearchField {
    override init(frame: NSRect = .zero) {
        super.init(frame: frame); cell = ChromeSearchCell(textCell: "")
        isEditable = true; isSelectable = true
        isBezeled = false; drawsBackground = false; cell?.lineBreakMode = .byTruncatingTail
        (cell as? NSSearchFieldCell)?.searchButtonCell?.imageScaling = .scaleProportionallyUpOrDown
        (cell as? NSSearchFieldCell)?.cancelButtonCell?.imageScaling = .scaleProportionallyUpOrDown
        font = .systemFont(ofSize: SpookkyStyle.points(13))
        SpookkyStyle.suppressFocusRing(self)
    }
    required init?(coder: NSCoder) { super.init(coder: coder); SpookkyStyle.suppressFocusRing(self) }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        SpookkyPalette.raised.setFill(); path.fill()
        SpookkyPalette.border.setStroke(); path.lineWidth = 1; path.stroke()
        super.draw(dirtyRect)
    }
}
final class ChromeSearchCell: NSSearchFieldCell {
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let height = ceil((font?.ascender ?? 10) - (font?.descender ?? -3) + 4)
        let inset = SpookkyStyle.points(28)
        return NSRect(x: rect.minX + inset, y: rect.midY - height / 2, width: max(0, rect.width - inset * 2), height: height)
    }
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        let size = SpookkyStyle.points(14)
        return NSRect(x: rect.minX + SpookkyStyle.points(8), y: rect.midY - size / 2, width: size, height: size)
    }
    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        let size = SpookkyStyle.points(14)
        return NSRect(x: rect.maxX - SpookkyStyle.points(22), y: rect.midY - size / 2, width: size, height: size)
    }
}
final class ChromePopUpButton: NSPopUpButton {
    override init(frame: NSRect = .zero, pullsDown: Bool = false) { super.init(frame: frame, pullsDown: pullsDown); SpookkyStyle.suppressFocusRing(self) }
    required init?(coder: NSCoder) { super.init(coder: coder); SpookkyStyle.suppressFocusRing(self) }
}
final class ChromeButton: NSButton {
    override init(frame: NSRect = .zero) { super.init(frame: frame); SpookkyStyle.suppressFocusRing(self) }
    required init?(coder: NSCoder) { super.init(coder: coder); SpookkyStyle.suppressFocusRing(self) }
}
final class ChromeAlert: NSAlert {
    @discardableResult override func addButton(withTitle title: String) -> NSButton {
        let button = super.addButton(withTitle: title); SpookkyStyle.suppressFocusRing(button); return button
    }
}

final class ChromeStackView: NSStackView {
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var raised = false
    var cornerRadius: CGFloat = SpookkyStyle.cornerRadius
    var drawsTrailingBorder = false
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
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        (raised ? SpookkyPalette.raised : selected ? SpookkyPalette.selected : interactionActive ? SpookkyPalette.hover : .clear).setFill(); path.fill()
        if raised {
            SpookkyPalette.border.setStroke(); path.lineWidth = 1; path.stroke()
        }
        if drawsTrailingBorder { SpookkyPalette.border.setFill(); NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class InlineRenameEditor: NSObject, NSTextFieldDelegate {
    private let field = ChromeTextField()
    private weak var button: ActionButton?
    private let completion: (String?, Bool) -> Void
    private var finished = false
    init(button: ActionButton, completion: @escaping (String?, Bool) -> Void) {
        self.button = button; self.completion = completion
        super.init()
        guard let root = button.window?.contentView else { return }
        let rect = root.convert(button.bounds, from: button)
        field.frame = NSRect(x: rect.minX, y: rect.midY - 12, width: max(80, rect.width), height: 24)
        field.stringValue = button.title; field.font = button.font; field.delegate = self
        field.isEditable = true; field.isSelectable = true; field.bezelStyle = .roundedBezel
        field.setAccessibilityLabel("Rename " + button.title)
        root.addSubview(field); button.alphaValue = 0; button.setAccessibilityElement(false)
        root.window?.makeFirstResponder(field); field.selectText(nil)
    }
    func cancel(restoreFocus: Bool = false) { finish(nil, restoreFocus: restoreFocus) }
    private func finish(_ name: String?, restoreFocus: Bool) {
        guard !finished else { return }; finished = true
        field.removeFromSuperview(); button?.alphaValue = 1; button?.setAccessibilityElement(true); button?.setAccessibilityRole(.button)
        completion(name, restoreFocus)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) { cancel(restoreFocus: true); return true }
        if command == #selector(NSResponder.insertNewline(_:)) {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { field.toolTip = "Enter a name"; NSSound.beep() } else { finish(name, restoreFocus: true) }; return true
        }
        return false
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        // Selecting a title can restart AppKit's shared field editor before focus settles.
        DispatchQueue.main.async { [weak self] in
            guard let self, !finished, field.currentEditor() == nil else { return }; cancel()
        }
    }
}

final class ResponsiveStackView: NSStackView {
    var breakpoint: CGFloat = 420
    override func layout() {
        let next: NSUserInterfaceLayoutOrientation = bounds.width < breakpoint ? .vertical : .horizontal
        if orientation != next { orientation = next; alignment = next == .vertical ? .leading : .centerY }
        super.layout()
    }
}

final class PromptTextView: NSTextView {
    private let draftUndoManager: UndoManager = { let manager = UndoManager(); manager.levelsOfUndo = 50; return manager }()
    override var undoManager: UndoManager? { draftUndoManager }
    var onFocusChange: (() -> Void)?
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); onFocusChange?(); return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); onFocusChange?(); return result }
    override var string: String { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            NSAttributedString(string: "Start a session…", attributes: [.font: font ?? NSFont.systemFont(ofSize: SpookkyStyle.points(14)), .foregroundColor: SpookkyPalette.secondary])
                .draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height))
        }
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
}

class ActionButton: NSButton {
    enum Emphasis { case quiet, secondary, primary, destructive }
    var emphasis: Emphasis = .quiet { didSet { needsDisplay = true } }
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var drawsInteractionFill = true
    var handler: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    var onNavigate: ((UInt16) -> Void)?
    var contentInset: CGFloat = SpookkyStyle.controlInset
    var menuIndicator = false { didSet { invalidateIntrinsicContentSize() } }
    var compactUtility = false
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
        // Custom symbol buttons have no native bezel outside their declared target.
        compactUtility && title.isEmpty ? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) : super.alignmentRectInsets
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
        let fillBounds = compact ? NSRect(x: bounds.midX - SpookkyStyle.points(10), y: bounds.midY - SpookkyStyle.points(10), width: SpookkyStyle.points(20), height: SpookkyStyle.points(20)) : bounds.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: fillBounds, xRadius: compact ? 5 : SpookkyStyle.cornerRadius, yRadius: compact ? 5 : SpookkyStyle.cornerRadius)
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
        label.draw(in: NSRect(x: content.minX, y: bounds.midY - h / 2, width: content.width, height: h))
    }
    @objc private func invoke() { handler?() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        keyboardFocused = true; updateInteractionVisibility(); onFocusChange?(true)
        if event.keyCode == 109, event.modifierFlags.contains(.shift), let menu = onContextMenu?() {
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

private final class ComposerDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor final class LaunchComposerView: NSView, NSTextViewDelegate {
    let tabID: UUID
    let prompt = PromptTextView()
    let locationOptions = WorktreeOptionsView(frame: .zero)
    var repositorySnapshot: RepositorySnapshot?
    private let picker = ActionButton("Codex", help: "Choose provider", action: {})
    private let folder = ActionButton("Home", symbol: "folder", help: "Choose folder or project", action: {})
    private let launch = ActionButton("", symbol: "arrow.up", action: {})
    private let card = ChromeStackView()
    private let controls = NSStackView()
    private let promptScroll = NSScrollView()
    private var promptHeight: NSLayoutConstraint!
    private var launchWidth: NSLayoutConstraint!
    private let message = ChromeTextField(wrappingLabelWithString: "")
    private let terminalRow = NSStackView()
    private let terminal = ActionButton("Open Terminal", symbol: "terminal", help: "Open Terminal and keep this session draft", action: {})
    private let locationPopover = NSPopover()
    private let locationPanel = NSStackView()
    private let projectPicker = ActionButton("Choose project", symbol: "folder", action: {})
    private let directory = SpookkyStyle.label( "")
    private let locationActions = NSStackView()
    private let chooseFolder = ActionButton("Use folder once…", action: {})
    private let addProject = ActionButton("Add project…", symbol: "plus", action: {})
    private let locate = ActionButton("Locate folder…", symbol: "folder", action: {})
    private var projects: [Project] = []
    private var selectedProjectID: UUID?
    private var currentTool: SessionTool?
    private var folderTitle = "Home"
    var onDraft: ((SessionTool?, String?) -> Void)?
    var onLaunch: (() -> Void)?
    var onTerminal: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onProject: ((UUID) -> Void)?
    var onAddProject: ((NSView) -> Void)?
    var onLocate: (() -> Void)?
    var onFocus: (() -> Void)?

    init(tabID: UUID) {
        self.tabID = tabID
        super.init(frame: .zero)
        prompt.font = .systemFont(ofSize: SpookkyStyle.points(14))
        prompt.isRichText = false; prompt.allowsUndo = true; prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        DisplayMetrics.registerRoot(self)
        prompt.textContainerInset = NSSize(width: 12, height: 12)
        prompt.delegate = self; prompt.drawsBackground = false; prompt.textColor = SpookkyPalette.text
        prompt.onFocusChange = { [weak card] in card?.needsDisplay = true }
        prompt.setAccessibilityLabel("Optional prompt for new session")
        promptScroll.documentView = prompt; promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .noBorder; promptScroll.drawsBackground = false
        prompt.isVerticallyResizable = true; prompt.isHorizontallyResizable = false
        prompt.autoresizingMask = [.width]; prompt.textContainer?.widthTracksTextView = true
        promptHeight = promptScroll.heightAnchor.constraint(equalToConstant: 80).displayScaled(); promptHeight.isActive = true
        promptScroll.autohidesScrollers = true
        picker.menuIndicator = true; folder.menuIndicator = true
        picker.handler = { [weak self] in self?.chooseTool() }
        folder.handler = { [weak self] in self?.showLocationPicker() }
        launch.handler = { [weak self] in self?.onLaunch?() }
        launch.emphasis = .primary
        launchWidth = launch.widthAnchor.constraint(equalToConstant: SpookkyStyle.controlHeight).displayScaled(alreadyScaled: true); launchWidth.isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [picker, folder, spacer, launch] { controls.addArrangedSubview(view) }
        controls.spacing = SpookkyStyle.points(4); controls.alignment = .centerY
        controls.edgeInsets = NSEdgeInsets(top: 0, left: SpookkyStyle.points(12), bottom: SpookkyStyle.points(8), right: SpookkyStyle.points(12))
        controls.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).displayScaled(alreadyScaled: true).isActive = true
        picker.widthAnchor.constraint(greaterThanOrEqualToConstant: SpookkyStyle.controlHeight).displayScaled(alreadyScaled: true).isActive = true
        folder.widthAnchor.constraint(greaterThanOrEqualToConstant: SpookkyStyle.controlHeight).displayScaled(alreadyScaled: true).isActive = true
        folder.widthAnchor.constraint(lessThanOrEqualToConstant: 300).displayScaled().isActive = true
        folder.lineBreakMode = .byTruncatingMiddle
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.required, for: .horizontal)
        card.orientation = .vertical; card.alignment = .leading; card.spacing = SpookkyStyle.points(4)
        card.raised = true; card.cornerRadius = SpookkyStyle.composerRadius
        card.setAccessibilityLabel("New chat"); card.setAccessibilityRole(.group)
        card.addArrangedSubview(promptScroll); card.addArrangedSubview(controls)
        promptScroll.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
        controls.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
        terminal.handler = { [weak self] in self?.onTerminal?() }
        terminal.emphasis = .quiet
        terminalRow.addArrangedSubview(terminal); terminalRow.addArrangedSubview(NSView()); terminalRow.spacing = SpookkyStyle.points(8)
        message.font = .systemFont(ofSize: SpookkyStyle.points(11)); message.textColor = SpookkyPalette.warning
        message.maximumNumberOfLines = 3
        let stack = NSStackView(views: [message, card, terminalRow])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = SpookkyStyle.points(8)
        let scroll = NSScrollView(), document = ComposerDocumentView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false; document.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll); stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -48).displayScaled()
        preferredWidth.priority = .defaultHigh
        let preferredHeight = document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor, constant: 48).displayScaled(), preferredHeight,
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24).displayScaled(),
            stack.topAnchor.constraint(greaterThanOrEqualTo: document.topAnchor, constant: 24).displayScaled(),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: SpookkyStyle.composerWidth).displayScaled(alreadyScaled: true),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 24).displayScaled(),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -24).displayScaled(), preferredWidth,
            card.widthAnchor.constraint(equalTo: stack.widthAnchor), terminalRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        configureLocationPicker()
    }
    required init?(coder: NSCoder) { fatalError("Use init") }

    private func configureLocationPicker() {
        locationPopover.behavior = .transient
        let controller = NSViewController(), scroll = NSScrollView(), document = ComposerDocumentView()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 240))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document; scroll.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(scroll)
        locationPanel.orientation = .vertical; locationPanel.alignment = .leading; locationPanel.spacing = SpookkyStyle.points(12)
        locationPanel.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(locationPanel)
        let title = SpookkyStyle.label( "Folder and project")
        title.font = .systemFont(ofSize: SpookkyStyle.points(13), weight: .medium); title.textColor = SpookkyPalette.text
        directory.font = .monospacedSystemFont(ofSize: SpookkyStyle.points(11), weight: .regular)
        directory.textColor = SpookkyPalette.metadata; directory.lineBreakMode = .byTruncatingMiddle
        projectPicker.menuIndicator = true; projectPicker.setAccessibilityLabel("Choose project")
        projectPicker.handler = { [weak self] in
            guard let self else { return }
            projectMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: projectPicker.bounds.height), in: projectPicker)
        }
        chooseFolder.handler = { [weak self] in self?.locationPopover.performClose(nil); self?.onChooseFolder?() }
        addProject.handler = { [weak self] in
            guard let self else { return }; locationPopover.performClose(nil); onAddProject?(folder)
        }
        locate.handler = { [weak self] in self?.locationPopover.performClose(nil); self?.onLocate?() }
        for view in [chooseFolder, addProject] { locationActions.addArrangedSubview(view) }
        locationActions.spacing = SpookkyStyle.points(8)
        for view in [title, directory, projectPicker, locationOptions, locationActions, locate] { locationPanel.addArrangedSubview(view) }
        for view in [directory, projectPicker, locationOptions, locationActions] { view.widthAnchor.constraint(equalTo: locationPanel.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: controller.view.topAnchor), scroll.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            locationPanel.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12).displayScaled(),
            locationPanel.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12).displayScaled(),
            locationPanel.topAnchor.constraint(equalTo: document.topAnchor, constant: 12).displayScaled(),
            locationPanel.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12).displayScaled()
        ])
        DisplayMetrics.registerRoot(controller.view)
        locationPopover.contentViewController = controller
    }

    func update(_ tab: WorkspaceTab, workspace: Workspace, state: WorkspaceState) {
        if prompt.string != tab.draft.prompt { prompt.string = tab.draft.prompt }
        currentTool = tab.draft.tool; projects = state.projects; selectedProjectID = workspace.projectID
        let project = projects.first { $0.id == workspace.projectID }
        let enabled = tab.isEditable
        let needsLocate = tab.failure?.recovery == .locateFolder
        let canChooseLocation = enabled && workspace.anchor == nil
        locationOptions.update(snapshot: repositorySnapshot, workspace: workspace, project: project,
            operation: state.locations?.operations.first { $0.id == workspace.locationOperationID }, enabled: enabled)
        prompt.isEditable = enabled; picker.isEnabled = enabled; folder.isEnabled = enabled || needsLocate
        promptScroll.isHidden = tab.draft.tool == .shell
        let needsBranch = workspace.anchor == nil && workspace.locationDraft?.mode == .worktree && workspace.locationDraft?.branchMode == .existing && workspace.locationDraft?.branch.isEmpty == true
        launch.isEnabled = enabled && !needsBranch
        let hasPrompt = !tab.draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let launchTitle = tab.draft.tool == .shell ? "Open Terminal" : (hasPrompt ? "Start " : "Open ") + tab.draft.tool.displayName
        launch.image = NSImage(systemSymbolName: tab.draft.tool == .shell ? "terminal" : "arrow.up", accessibilityDescription: nil)
        launch.setAccessibilityLabel(launchTitle); launch.toolTip = launchTitle + " · ⌘Return"
        picker.image = SpookkyStyle.toolImage(tab.draft.tool)
        picker.setAccessibilityLabel("Choose provider · " + tab.draft.tool.displayName)
        picker.toolTip = "Choose provider · " + tab.draft.tool.displayName
        terminalRow.isHidden = tab.draft.tool == .shell; terminal.isEnabled = enabled
        let path = workspace.directory
        directory.stringValue = SpookkyStyle.abbreviatedPath(path); directory.toolTip = path
        let name = project?.name ?? (path == FileManager.default.homeDirectoryForCurrentUser.path ? "Home" : URL(fileURLWithPath: path).lastPathComponent)
        let git = workspace.anchor?.isGit ?? workspace.selectedLocation.isGit
        folderTitle = name + (git ? (workspace.locationDraft?.mode == .worktree ? " · Worktree" : " · Local") : "")
        folder.toolTip = folderTitle + "\n" + path
        folder.setAccessibilityLabel("Choose folder or project · " + folderTitle)
        projectPicker.title = project?.name ?? "Choose project"
        projectPicker.toolTip = project?.location.path ?? "Projects are optional"
        projectPicker.isEnabled = canChooseLocation
        chooseFolder.isHidden = !canChooseLocation; addProject.isHidden = !canChooseLocation
        locationActions.isHidden = !canChooseLocation; locate.isHidden = !needsLocate
        if let failure = tab.failure { message.stringValue = failure.message }
        else if needsBranch { message.stringValue = "Choose an existing branch before starting." }
        else {
            switch tab.status {
            case .preparing: message.stringValue = "Preparing location…"
            case .launching: message.stringValue = "Starting " + tab.draft.tool.displayName + "…"
            case .uncertain: message.stringValue = "Session status needs checking."
            case .unavailable: message.stringValue = "Session unavailable."
            case .failed: message.stringValue = "Could not start session."
            default: message.stringValue = ""
            }
        }
        message.isHidden = message.stringValue.isEmpty; message.toolTip = message.stringValue
        message.setAccessibilityLabel(message.stringValue)
        message.textColor = tab.failure != nil || needsBranch || [.failed, .uncertain, .unavailable].contains(tab.status) ? SpookkyPalette.warning : SpookkyPalette.secondary
        configureFooter(); resizePrompt(); card.needsDisplay = true
        if locationPopover.isShown { resizeLocationPicker() }
    }

    private func configureFooter() {
        let tool = currentTool ?? .codex, compact = card.bounds.width > 0 && card.bounds.width < SpookkyStyle.points(280)
        let providerTitle = compact ? "" : tool == .claude ? "Claude" : tool.displayName
        if picker.title != providerTitle { picker.title = providerTitle }
        let title = compact ? "" : folderTitle
        if folder.title != title { folder.title = title }
        let launchTitle = tool == .shell && card.bounds.width >= SpookkyStyle.points(380) ? "Open Terminal" : ""
        if launch.title != launchTitle { launch.title = launchTitle }
        let width = launchTitle.isEmpty ? SpookkyStyle.controlHeight : launch.intrinsicContentSize.width
        if abs(launchWidth.constant - width) > 0.5 { launchWidth.constant = width }
        let inset = SpookkyStyle.points(compact ? 8 : 12)
        if controls.edgeInsets.left != inset { controls.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: SpookkyStyle.points(8), right: inset) }
    }
    private func showLocationPicker() {
        if locationPopover.isShown { locationPopover.performClose(nil); return }
        resizeLocationPicker()
        locationPopover.show(relativeTo: folder.bounds, of: folder, preferredEdge: .maxY)
        resizeLocationPicker()
    }
    private func resizeLocationPicker() {
        let available = window?.contentView?.bounds.size ?? bounds.size
        let width = min(560, max(280, available.width - 48))
        let maximumHeight = max(140, min(420, available.height - 48))
        let current = locationPopover.contentSize
        let provisional = NSSize(width: width, height: min(maximumHeight, max(100, current.height)))
        if abs(current.width - provisional.width) > 0.5 || abs(current.height - provisional.height) > 0.5 { locationPopover.contentSize = provisional }
        if !locationPopover.isShown { locationPopover.contentViewController?.view.setFrameSize(provisional) }
        locationPopover.contentViewController?.view.layoutSubtreeIfNeeded()
        let height = min(maximumHeight, max(100, ceil(locationPanel.fittingSize.height) + 24))
        if abs(locationPopover.contentSize.height - height) > 0.5 { locationPopover.contentSize = NSSize(width: width, height: height) }
    }
    private func projectMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let recent = projects.filter { $0.lastUsed != nil }.sorted { $0.lastUsed! > $1.lastUsed! }.prefix(5)
        let recentIDs = Set(recent.map(\.id))
        func append(_ project: Project) {
            let item = ClosureMenuItem(project.name + " · " + SpookkyStyle.abbreviatedPath(project.location.path)) { [weak self] in
                self?.locationPopover.performClose(nil); self?.onProject?(project.id)
            }
            item.toolTip = project.location.path; item.state = project.id == selectedProjectID ? .on : .off
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil); menu.addItem(item)
        }
        if !recent.isEmpty {
            let label = NSMenuItem(title: "Recent projects", action: nil, keyEquivalent: ""); label.isEnabled = false; menu.addItem(label)
            recent.forEach(append)
        }
        let remaining = projects.filter { !recentIDs.contains($0.id) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !remaining.isEmpty {
            if !recent.isEmpty { menu.addItem(.separator()) }
            remaining.forEach(append)
        }
        if !projects.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem("Use folder once…") { [weak self] in self?.locationPopover.performClose(nil); self?.onChooseFolder?() })
        menu.addItem(ClosureMenuItem("Add project…") { [weak self] in
            guard let self else { return }; locationPopover.performClose(nil); onAddProject?(folder)
        })
        return menu
    }
    private func chooseTool() {
        let menu = NSMenu()
        for tool in [SessionTool.codex, .claude] {
            let item = ClosureMenuItem(tool == .claude ? "Claude" : tool.displayName) { [weak self] in self?.onDraft?(tool, nil); self?.focus() }
            item.image = SpookkyStyle.toolImage(tool)
            item.state = currentTool == tool ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: picker.bounds.height), in: picker)
    }
    func focus() { window?.makeFirstResponder(currentTool == .shell ? launch : prompt) }
    var hasInputFocus: Bool {
        !locationPopover.isShown && (window?.firstResponder === prompt || window?.firstResponder === launch || window?.firstResponder === picker)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { locationPopover.performClose(nil) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func layout() { super.layout(); configureFooter(); resizePrompt() }
    private func resizePrompt() {
        guard let manager = prompt.layoutManager, let container = prompt.textContainer, promptScroll.contentSize.width > 0 else { return }
        manager.ensureLayout(for: container)
        let content = manager.usedRect(for: container).height + prompt.textContainerInset.height * 2
        let height = max(SpookkyStyle.points(80), min(content, SpookkyStyle.points(300), max(SpookkyStyle.points(80), bounds.height / 2)))
        if abs(promptHeight.constant - height) > 0.5 { promptHeight.constant = height }
    }
    func textDidChange(_ notification: Notification) { resizePrompt(); onDraft?(nil, prompt.string) }
    func textDidBeginEditing(_ notification: Notification) { onFocus?() }
}

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
        SpookkyPalette.sidebar.setFill(); NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height).fill()
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
