import AppKit
import ImageIO
import SpookkyCore
import SpookkyGit
import SpookkySyntax
import SpookkyWorkspace
import UniformTypeIdentifiers

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
    static var sidebarWidth: CGFloat { points(264) }
    static var sidebarOuterInset: CGFloat { points(12) }
    static var fileSidebarWidth: CGFloat { points(248) }
    static var composerWidth: CGFloat { points(620) }
    static var composerRadius: CGFloat { points(16) }
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
    var onPasteImage: ((Data) -> Void)?
    var imagePasteboard: NSPasteboard = .general
    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if let type = imagePasteboard.availableType(from: [.png, .tiff]), let data = imagePasteboard.data(forType: type) {
            onPasteImage?(data)
        } else { super.paste(sender) }
    }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), imagePasteboard.availableType(from: [.png, .tiff]) != nil { return isEditable }
        return super.validateUserInterfaceItem(item)
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); onFocusChange?(); return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); onFocusChange?(); return result }
    override var string: String { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            NSAttributedString(string: "What would you like to work on?", attributes: [.font: font ?? NSFont.systemFont(ofSize: SpookkyStyle.points(14)), .foregroundColor: SpookkyPalette.secondary])
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
        alignsToBounds || compactUtility && title.isEmpty ? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) : super.alignmentRectInsets
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

private final class ComposerPopoverBackground: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { SpookkyPalette.raised.setFill(); bounds.fill() }
}

@MainActor private final class SpookkyWelcomeMark: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let size = min(bounds.width, bounds.height)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: size * 0.2, y: size * 0.12))
        path.line(to: NSPoint(x: size * 0.2, y: size * 0.62))
        path.curve(to: NSPoint(x: size * 0.8, y: size * 0.62), controlPoint1: NSPoint(x: size * 0.2, y: size), controlPoint2: NSPoint(x: size * 0.8, y: size))
        path.line(to: NSPoint(x: size * 0.8, y: size * 0.12))
        for (x, y) in [(0.65, 0.24), (0.5, 0.12), (0.35, 0.24), (0.2, 0.12)] { path.line(to: NSPoint(x: size * x, y: size * y)) }
        path.lineWidth = SpookkyStyle.points(1.5); path.lineJoinStyle = .round
        SpookkyPalette.secondary.withAlphaComponent(0.7).setStroke(); path.stroke()
        SpookkyPalette.secondary.withAlphaComponent(0.7).setFill()
        for x in [0.4, 0.6] { NSBezierPath(ovalIn: NSRect(x: size * x - 1, y: size * 0.56, width: 2, height: 2)).fill() }
    }
}

@MainActor private struct ComposerChoice {
    let title: String
    let detail: String?
    let symbol: String?
    let selected: Bool
    let alwaysVisible: Bool
    let action: (() -> Void)?
    init(_ title: String, detail: String? = nil, symbol: String? = nil, selected: Bool = false,
         alwaysVisible: Bool = false, action: (() -> Void)? = nil) {
        self.title = title; self.detail = detail; self.symbol = symbol; self.selected = selected
        self.alwaysVisible = alwaysVisible; self.action = action
    }
}

@MainActor private final class ComposerChoicePopover: NSObject, NSSearchFieldDelegate, NSPopoverDelegate {
    private let popover = NSPopover()
    private let controller = NSViewController()
    private let search = NSSearchField()
    private let rows = NSStackView()
    private let scroll = NSScrollView()
    private var values: [ComposerChoice] = []
    private var buttons: [ActionButton] = []
    private(set) weak var anchor: NSView?
    var isShown: Bool { popover.isShown }

    override init() {
        super.init()
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        controller.view = ComposerPopoverBackground(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        popover.contentViewController = controller
        search.delegate = self; search.sendsSearchStringImmediately = true
        SpookkyStyle.configure(search)
        let document = ComposerDocumentView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = SpookkyStyle.points(2)
        rows.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(rows)
        let stack = NSStackView(views: [search, scroll])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = SpookkyStyle.points(6)
        stack.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 8).displayScaled(),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -8).displayScaled(),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 8).displayScaled(),
            stack.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -8).displayScaled(),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor), rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        DisplayMetrics.registerRoot(controller.view)
    }
    func show(from anchor: NSView, title: String, search placeholder: String, rows: [ComposerChoice]) {
        close(); self.anchor = anchor; search.stringValue = ""; search.placeholderString = placeholder
        search.setAccessibilityLabel(placeholder); controller.view.setAccessibilityLabel(title)
        values = rows; render()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        controller.view.window?.makeFirstResponder(search)
    }
    func close() {
        let previous = anchor
        if popover.isShown { popover.performClose(nil) }
        anchor = nil
        previous?.window?.makeFirstResponder(previous)
    }
    func update(_ values: [ComposerChoice]) { self.values = values; render() }
    private func render() {
        let focused = (controller.view.window?.firstResponder as? NSButton)?.title
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        buttons = []
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = values.filter { $0.alwaysVisible || query.isEmpty || ($0.title + " " + ($0.detail ?? "")).localizedCaseInsensitiveContains(query) }
        var height: CGFloat = 0
        for value in matches {
            let button = ActionButton(value.title, symbol: value.selected ? "checkmark" : value.symbol, action: {})
            button.isEnabled = value.action != nil; button.selected = value.selected
            button.lineBreakMode = .byTruncatingMiddle; button.alignment = .left
            button.setAccessibilityLabel(value.title + (value.detail.map { " · " + $0 } ?? ""))
            button.toolTip = value.title + (value.detail.map { "\n" + $0 } ?? "")
            button.handler = { [weak self] in self?.close(); value.action?() }
            button.onNavigate = { [weak self, weak button] key in
                guard let self, let button, let index = buttons.firstIndex(of: button) else { return }
                let next = max(0, min(buttons.count - 1, index + (key == 126 ? -1 : 1)))
                controller.view.window?.makeFirstResponder(buttons[next]); buttons[next].scrollToVisible(buttons[next].bounds)
            }
            let row = NSStackView(views: [button]); row.orientation = .vertical; row.alignment = .leading
            row.spacing = 0; rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            button.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            if let detail = value.detail {
                let label = NSTextField(wrappingLabelWithString: detail)
                label.font = .systemFont(ofSize: SpookkyStyle.points(11)); label.textColor = SpookkyPalette.secondary
                label.maximumNumberOfLines = 2; row.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -16).displayScaled().isActive = true
                height += SpookkyStyle.points(32)
            }
            if value.action != nil { buttons.append(button) }
            height += SpookkyStyle.points(32)
        }
        if matches.isEmpty {
            let empty = SpookkyStyle.label("No matches"); rows.addArrangedSubview(empty); height = SpookkyStyle.points(32)
        }
        let available = anchor?.window?.contentView?.bounds.size ?? NSSize(width: 400, height: 600)
        popover.contentSize = NSSize(width: min(SpookkyStyle.points(340), max(240, available.width - 48)),
            height: min(max(140, available.height - 80), SpookkyStyle.points(410), max(100, height + SpookkyStyle.points(52))))
        if let focused, let button = buttons.first(where: { $0.title == focused }) { controller.view.window?.makeFirstResponder(button) }
    }
    func controlTextDidChange(_ notification: Notification) { render() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        if command == #selector(NSResponder.moveDown(_:)), let first = buttons.first { controller.view.window?.makeFirstResponder(first); return true }
        if command == #selector(NSResponder.insertNewline(_:)), let first = buttons.first { first.performClick(nil); return true }
        return false
    }
    func popoverDidClose(_ notification: Notification) { if let anchor { anchor.window?.makeFirstResponder(anchor) } }
}

@MainActor final class LaunchComposerView: NSView, NSTextViewDelegate {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { SpookkyPalette.background.setFill(); bounds.fill() }
    let tabID: UUID
    let prompt = PromptTextView()
    let locationOptions = WorktreeOptionsView(frame: .zero)
    var repositorySnapshot: RepositorySnapshot?
    private let picker = ActionButton("Codex", help: "Choose provider", action: {})
    private let folder = ActionButton("Home", symbol: "folder", help: "Choose folder or project", action: {})
    private let location = ActionButton("Local", symbol: "folder", help: "Choose checkout", action: {})
    private let source = ActionButton("", symbol: "point.3.connected.trianglepath.dotted", help: "Starting branch", action: {})
    private let model = ActionButton("Default model", help: "Choose model", action: {})
    private let attach = ActionButton("", symbol: "plus", help: "Attach images", action: {})
    private let heading = ChromeTextField(wrappingLabelWithString: "What would you like to work on?")
    private let welcome = NSStackView()
    private let context = ResponsiveStackView()
    private let leftControls = NSStackView(), rightControls = NSStackView()
    private let footerSpacer = NSView()
    private let modelSpacer = NSView()
    private var footerHeight: NSLayoutConstraint!
    private var rightWidth: NSLayoutConstraint!
    private let choices = ComposerChoicePopover()
    private let modelCatalog: any ProviderModelDiscovering
    private var discoveredModels: ProviderModels?
    private var catalogKey = ""
    private var modelTask: Task<Void, Never>?
    private var selection = AgentModelSelection()
    private var currentWorkspace: Workspace?
    private var currentProject: Project? { projects.first { $0.id == currentWorkspace?.projectID } }
    private let launch = ActionButton("", symbol: "arrow.up", action: {})
    private let card = ChromeStackView()
    private let controls = NSStackView()
    private let promptScroll = NSScrollView()
    private let imageList = NSStackView()
    private var images: [String] = []
    private var imagePreviews: [String: NSImageView] = [:]
    private var importingImage = false
    private var locationReady = true
    let imageDirectory: URL
    private var promptHeight: NSLayoutConstraint!
    private var launchWidth: NSLayoutConstraint!
    private let message = ChromeTextField(wrappingLabelWithString: "")
    private let terminalRow = NSStackView()
    private let terminal = ActionButton("Open Terminal", symbol: "terminal", help: "Open Terminal and keep this session draft", action: {})
    private let locationPopover = NSPopover()
    private let locationPanel = NSStackView()
    private let directory = SpookkyStyle.label( "")
    private let locate = ActionButton("Locate folder…", symbol: "folder", action: {})
    private var projects: [Project] = []
    private var currentTool: SessionTool?
    private var folderTitle = "Home"
    var onDraft: ((SessionTool?, String?) -> Void)?
    var onImages: (([String]) -> Void)?
    var onModel: ((AgentModelSelection) -> Void)?
    var onNoProject: (() -> Void)?
    var onError: ((String) -> Void)?
    var onLaunch: (() -> Void)?
    var onTerminal: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onProject: ((UUID) -> Void)?
    var onAddProject: ((NSView) -> Void)?
    var onLocate: (() -> Void)?
    var onFocus: (() -> Void)?

    init(tabID: UUID, imageDirectory: URL, modelCatalog: any ProviderModelDiscovering = ProviderModelCatalog.shared) {
        self.tabID = tabID; self.imageDirectory = imageDirectory; self.modelCatalog = modelCatalog
        super.init(frame: .zero)
        prompt.font = .systemFont(ofSize: SpookkyStyle.points(14))
        prompt.isRichText = false; prompt.allowsUndo = true; prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        DisplayMetrics.registerRoot(self)
        prompt.textContainerInset = NSSize(width: 12, height: 12)
        prompt.delegate = self; prompt.drawsBackground = false; prompt.textColor = SpookkyPalette.text
        prompt.onFocusChange = { [weak card] in card?.needsDisplay = true }
        prompt.onPasteImage = { [weak self] data in self?.pasteImage(data) }
        prompt.setAccessibilityLabel("Optional prompt for new session")
        promptScroll.documentView = prompt; promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .noBorder; promptScroll.drawsBackground = false
        prompt.isVerticallyResizable = true; prompt.isHorizontallyResizable = false
        prompt.autoresizingMask = [.width]; prompt.textContainer?.widthTracksTextView = true
        promptHeight = promptScroll.heightAnchor.constraint(equalToConstant: 80).displayScaled(); promptHeight.isActive = true
        promptScroll.autohidesScrollers = true
        picker.menuIndicator = true; folder.menuIndicator = true; location.menuIndicator = true; model.menuIndicator = true
        picker.handler = { [weak self] in self?.chooseTool() }
        folder.handler = { [weak self] in self?.chooseProject() }
        location.handler = { [weak self] in self?.chooseLocation() }
        source.handler = { [weak self] in self?.chooseSource() }
        model.handler = { [weak self] in self?.chooseModel() }
        attach.handler = { [weak self] in self?.chooseImages() }
        launch.handler = { [weak self] in guard let self, !importingImage else { return }; onLaunch?() }
        launch.emphasis = .primary
        launchWidth = launch.widthAnchor.constraint(equalToConstant: SpookkyStyle.controlHeight).displayScaled(alreadyScaled: true); launchWidth.isActive = true
        footerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        leftControls.addArrangedSubview(attach); leftControls.addArrangedSubview(picker)
        modelSpacer.setContentHuggingPriority(.init(1), for: .horizontal); modelSpacer.isHidden = true
        rightControls.addArrangedSubview(modelSpacer); rightControls.addArrangedSubview(model); rightControls.addArrangedSubview(launch)
        leftControls.spacing = SpookkyStyle.points(4); rightControls.spacing = SpookkyStyle.points(4)
        rightControls.alignment = .centerY; leftControls.alignment = .centerY
        for view in [leftControls, footerSpacer, rightControls] { controls.addArrangedSubview(view) }
        controls.spacing = SpookkyStyle.points(4); controls.alignment = .centerY
        controls.edgeInsets = NSEdgeInsets(top: 0, left: SpookkyStyle.points(12), bottom: SpookkyStyle.points(8), right: SpookkyStyle.points(12))
        footerHeight = controls.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).displayScaled(alreadyScaled: true)
        footerHeight.isActive = true
        rightWidth = rightControls.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -16).displayScaled()
        model.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        model.lineBreakMode = .byTruncatingMiddle
        model.widthAnchor.constraint(lessThanOrEqualToConstant: 300).displayScaled().isActive = true
        picker.widthAnchor.constraint(greaterThanOrEqualToConstant: SpookkyStyle.controlHeight).displayScaled(alreadyScaled: true).isActive = true
        folder.widthAnchor.constraint(greaterThanOrEqualToConstant: SpookkyStyle.controlHeight).displayScaled(alreadyScaled: true).isActive = true
        folder.widthAnchor.constraint(lessThanOrEqualToConstant: 300).displayScaled().isActive = true
        folder.lineBreakMode = .byTruncatingMiddle
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picker.setContentCompressionResistancePriority(.required, for: .horizontal)
        card.orientation = .vertical; card.alignment = .leading; card.spacing = SpookkyStyle.points(4)
        card.raised = true; card.cornerRadius = SpookkyStyle.composerRadius
        card.setAccessibilityLabel("New chat"); card.setAccessibilityRole(.group)
        imageList.orientation = .horizontal; imageList.alignment = .top; imageList.spacing = SpookkyStyle.points(8)
        imageList.edgeInsets = NSEdgeInsets(top: 0, left: SpookkyStyle.points(12), bottom: 0, right: SpookkyStyle.points(12))
        imageList.isHidden = true
        let imageScroll = NSScrollView()
        imageScroll.drawsBackground = false; imageScroll.hasHorizontalScroller = true; imageScroll.autohidesScrollers = true
        imageScroll.documentView = imageList
        imageList.translatesAutoresizingMaskIntoConstraints = true
        imageScroll.heightAnchor.constraint(equalToConstant: 68).displayScaled().isActive = true
        imageScroll.isHidden = true
        card.addArrangedSubview(imageScroll); card.addArrangedSubview(promptScroll); card.addArrangedSubview(controls)
        imageScroll.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
        promptScroll.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
        controls.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
        terminal.handler = { [weak self] in self?.onTerminal?() }
        terminal.emphasis = .quiet
        let terminalLeading = NSView(), terminalTrailing = NSView()
        terminalLeading.setContentHuggingPriority(.init(1), for: .horizontal)
        terminalTrailing.setContentHuggingPriority(.init(1), for: .horizontal)
        terminalRow.addArrangedSubview(terminalLeading); terminalRow.addArrangedSubview(terminal); terminalRow.addArrangedSubview(terminalTrailing)
        terminalLeading.widthAnchor.constraint(equalTo: terminalTrailing.widthAnchor).isActive = true
        terminalRow.spacing = SpookkyStyle.points(8)
        context.spacing = SpookkyStyle.points(4); context.breakpoint = SpookkyStyle.points(300)
        for view in [folder, location, source] { context.addArrangedSubview(view) }
        for button in [folder, location, source] { button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        heading.font = .systemFont(ofSize: SpookkyStyle.points(28), weight: .regular)
        heading.textColor = SpookkyPalette.text; heading.alignment = .center
        let mark = SpookkyWelcomeMark()
        mark.widthAnchor.constraint(equalToConstant: 38).displayScaled().isActive = true
        mark.heightAnchor.constraint(equalToConstant: 38).displayScaled().isActive = true
        welcome.orientation = .vertical; welcome.alignment = .centerX; welcome.spacing = SpookkyStyle.points(20)
        welcome.addArrangedSubview(mark); welcome.addArrangedSubview(heading)
        message.font = .systemFont(ofSize: SpookkyStyle.points(11)); message.textColor = SpookkyPalette.warning
        message.maximumNumberOfLines = 3
        let stack = NSStackView(views: [welcome, message, card, context, terminalRow])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = SpookkyStyle.points(8)
        stack.setCustomSpacing(SpookkyStyle.points(32), after: welcome)
        stack.setCustomSpacing(SpookkyStyle.points(16), after: context)
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
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor), stack.centerYAnchor.constraint(equalTo: document.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: document.topAnchor, constant: 24).displayScaled(),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: SpookkyStyle.composerWidth).displayScaled(alreadyScaled: true),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 24).displayScaled(),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -24).displayScaled(), preferredWidth,
            card.widthAnchor.constraint(equalTo: stack.widthAnchor), terminalRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            context.widthAnchor.constraint(equalTo: stack.widthAnchor),
            welcome.widthAnchor.constraint(equalTo: stack.widthAnchor), heading.widthAnchor.constraint(equalTo: welcome.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        configureLocationPicker()
    }
    required init?(coder: NSCoder) { fatalError("Use init") }

    private func pasteImage(_ data: Data) {
        importImage { data }
    }
    private func chooseImages() {
        guard let window, prompt.isEditable, !importingImage else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.prompt = "Attach image"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importImage {
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard attributes.isRegularFile == true, let size = attributes.fileSize, size <= 20 * 1024 * 1024 else {
                    throw LaunchError.invalid("Attach an image no larger than 20 MB.")
                }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                return try file.read(upToCount: 20 * 1024 * 1024 + 1) ?? Data()
            }
        }
    }
    private func importImage(_ read: @escaping @Sendable () throws -> Data) {
        guard prompt.isEditable, !importingImage else { NSSound.beep(); return }
        guard images.count < 8 else {
            onError?("Attach up to 8 images, each no larger than 20 MB."); return
        }
        importingImage = true; launch.isEnabled = false
        let directory = imageDirectory
        Task { [self] in
            defer { importingImage = false; attach.isEnabled = prompt.isEditable; configureFooter() }
            do {
                let path = try await Task.detached {
                    let data = try read()
                    guard data.count <= 20 * 1024 * 1024 else { throw LaunchError.invalid("Attach an image no larger than 20 MB.") }
                    return try Self.storeClipboardImage(data, directory: directory)
                }.value
                images.append(path); onImages?(images); renderImages()
            } catch { onError?(error.localizedDescription) }
        }
    }

    nonisolated private static func storeClipboardImage(_ data: Data, directory: URL) throws -> String {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 25_000_000 / height,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw LaunchError.invalid("This image could not be pasted. Use an image under 20 MB and 25 megapixels.")
            }
            let png = CGImageSourceGetType(source) as String? == "public.png" ? data :
                NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            guard let png, png.count <= 20 * 1024 * 1024 else {
                throw LaunchError.invalid("This image could not be pasted. Use an image under 20 MB.")
            }
            try PrivateFiles.directory(directory)
            let file = directory.appendingPathComponent(UUID().uuidString + ".png")
            guard FileManager.default.createFile(atPath: file.path, contents: png, attributes: [.posixPermissions: 0o600]) else {
                throw LaunchError.invalid("The pasted image could not be saved. Try again.")
            }
            return file.path
        }
    }

    private func renderImages() {
        let retained = Set(images)
        imagePreviews = imagePreviews.filter { retained.contains($0.key) }
        for view in imageList.arrangedSubviews { imageList.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, path) in images.enumerated() {
            let row = NSStackView()
            let icon = imagePreview(for: path)
            icon.setAccessibilityLabel("Attached image " + String(index + 1))
            let remove = ActionButton("", symbol: "xmark", help: "Remove image " + String(index + 1)) { [weak self] in
                guard let self else { return }; images.removeAll { $0 == path }; onImages?(images); renderImages(); focus()
            }
            remove.isEnabled = prompt.isEditable
            for view in [icon, remove] { row.addArrangedSubview(view) }
            row.spacing = SpookkyStyle.points(6); row.alignment = .centerY
            imageList.addArrangedSubview(row)
        }
        imageList.isHidden = images.isEmpty || currentTool == .shell
        imageList.enclosingScrollView?.isHidden = imageList.isHidden
        imageList.setFrameSize(imageList.fittingSize)
    }

    private func imagePreview(for path: String) -> NSImageView {
        if let preview = imagePreviews[path] { return preview }
        let preview = NSImageView(image: NSImage(systemSymbolName: "photo", accessibilityDescription: "Attached image")!)
        preview.widthAnchor.constraint(equalToConstant: SpookkyStyle.points(64)).isActive = true
        preview.heightAnchor.constraint(equalToConstant: SpookkyStyle.points(52)).isActive = true
        preview.imageScaling = .scaleProportionallyUpOrDown
        imagePreviews[path] = preview
        Task { [weak preview] in
            let thumbnail = await Task.detached {
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 80,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return Data?.none }
                return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }.value
            if let thumbnail { preview?.image = NSImage(data: thumbnail) }
        }
        return preview
    }

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
        let title = SpookkyStyle.label("Worktree options")
        title.font = .systemFont(ofSize: SpookkyStyle.points(13), weight: .medium); title.textColor = SpookkyPalette.text
        directory.font = .monospacedSystemFont(ofSize: SpookkyStyle.points(11), weight: .regular)
        directory.textColor = SpookkyPalette.metadata; directory.lineBreakMode = .byTruncatingMiddle
        locate.handler = { [weak self] in self?.locationPopover.performClose(nil); self?.onLocate?() }
        for view in [title, directory, locationOptions, locate] { locationPanel.addArrangedSubview(view) }
        for view in [directory, locationOptions] { view.widthAnchor.constraint(equalTo: locationPanel.widthAnchor).isActive = true }
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
        currentTool = tab.draft.tool; projects = state.projects
        currentWorkspace = workspace; selection = tab.draft.modelSelection
        let project = currentProject
        let nextCatalogKey = tab.draft.tool.rawValue + "|" + workspace.directory
        if catalogKey != nextCatalogKey {
            catalogKey = nextCatalogKey; discoveredModels = nil; modelTask?.cancel(); choices.close()
        }
        let enabled = tab.isEditable
        prompt.isEditable = enabled
        if images != tab.draft.images { images = tab.draft.images; renderImages() }
        imageList.isHidden = images.isEmpty || tab.draft.tool == .shell
        imageList.enclosingScrollView?.isHidden = imageList.isHidden
        for row in imageList.arrangedSubviews { (row as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = enabled } }
        let needsLocate = tab.failure?.recovery == .locateFolder
        let canChooseLocation = enabled && workspace.anchor == nil
        locationOptions.update(snapshot: repositorySnapshot, workspace: workspace, project: project,
            operation: state.locations?.operations.first { $0.id == workspace.locationOperationID }, enabled: enabled)
        picker.isEnabled = enabled; folder.isEnabled = canChooseLocation || needsLocate
        attach.isEnabled = enabled && !importingImage; model.isEnabled = enabled
        attach.isHidden = tab.draft.tool == .shell; model.isHidden = tab.draft.tool == .shell
        promptScroll.isHidden = tab.draft.tool == .shell
        let needsBranch = workspace.anchor == nil && workspace.locationDraft?.mode == .worktree && workspace.locationDraft?.branchMode == .existing && workspace.locationDraft?.branch.isEmpty == true
        locationReady = !needsBranch
        let hasPrompt = !tab.draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tab.draft.images.isEmpty
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
        folderTitle = project?.name ?? (path == FileManager.default.homeDirectoryForCurrentUser.path ? "No project" : name)
        heading.stringValue = project.map { "What’s next in " + $0.name + "?" } ?? "What would you like to work on?"
        let isNew = workspace.locationDraft?.mode == .worktree
        let isExisting = project != nil && workspace.selectedLocation.checkoutIdentity != project?.location.checkoutIdentity
        location.title = isNew ? "New worktree" : isExisting ? "Existing worktree" : "Local"
        location.isHidden = !git; source.isHidden = !git; location.isEnabled = canChooseLocation
        let draft = workspace.locationDraft ?? LocationDraft()
        source.title = isNew ? (draft.branchMode == .existing ? (draft.branch.isEmpty ? "Choose branch" : draft.branch) : "From " + draft.source) :
            (workspace.anchor?.branch ?? workspace.selectedLocation.branch ?? "Detached HEAD")
        source.toolTip = source.title; source.menuIndicator = isNew; source.isEnabled = canChooseLocation && isNew
        folder.toolTip = folderTitle + "\n" + path
        folder.setAccessibilityLabel("Choose folder or project · " + folderTitle)
        locate.isHidden = !needsLocate
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
        let tool = currentTool ?? .codex, compact = card.bounds.width > 0 && card.bounds.width < SpookkyStyle.points(420)
        let providerTitle = compact && tool == .claude ? "Claude" : tool.displayName
        if picker.title != providerTitle { picker.title = providerTitle }
        if folder.title != folderTitle { folder.title = folderTitle }
        let modelName = discoveredModels?.models.first { $0.id == selection.model }?.name ?? selection.displayName ?? selection.model ?? "Default model"
        let modelTitle = modelName + (selection.effort.map { " · " + $0.capitalized } ?? "")
        if model.title != modelTitle { model.title = modelTitle }
        model.toolTip = "Choose " + tool.displayName + " model · " + modelTitle
        model.setAccessibilityLabel(model.toolTip)
        let acceptsImages = discoveredModels?.models.first { $0.id == selection.model }?.acceptsImages ?? true
        let modelWarning = "This model does not accept images. Choose another model or remove the images."
        if message.stringValue.isEmpty || message.stringValue == modelWarning {
            message.stringValue = !images.isEmpty && !acceptsImages ? modelWarning : ""
            message.isHidden = message.stringValue.isEmpty
        }
        launch.isEnabled = prompt.isEditable && locationReady && !importingImage && (images.isEmpty || acceptsImages)
        let orientation: NSUserInterfaceLayoutOrientation = compact ? .vertical : .horizontal
        if controls.orientation != orientation {
            rightWidth.isActive = false; controls.orientation = orientation
            controls.alignment = compact ? .leading : .centerY
            footerSpacer.isHidden = compact
            modelSpacer.isHidden = !compact
            rightWidth.isActive = compact
        }
        footerHeight.constant = SpookkyStyle.points(compact ? 76 : 40)
        let launchTitle = tool == .shell && card.bounds.width >= SpookkyStyle.points(380) ? "Open Terminal" : ""
        if launch.title != launchTitle { launch.title = launchTitle }
        let width = launchTitle.isEmpty ? SpookkyStyle.controlHeight : launch.intrinsicContentSize.width
        if abs(launchWidth.constant - width) > 0.5 { launchWidth.constant = width }
        let inset = SpookkyStyle.points(compact ? 8 : 12)
        if controls.edgeInsets.left != inset { controls.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: SpookkyStyle.points(8), right: inset) }
    }
    private func showLocationPicker() {
        choices.close()
        if locationPopover.isShown { locationPopover.performClose(nil); return }
        resizeLocationPicker()
        locationPopover.show(relativeTo: location.bounds, of: location, preferredEdge: .maxY)
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
    private func chooseProject() {
        if currentWorkspace?.anchor != nil { onLocate?(); return }
        locationPopover.performClose(nil)
        var rows = [ComposerChoice("No project", detail: "Start in Home", symbol: "house", selected: currentWorkspace?.projectID == nil) { [weak self] in self?.onNoProject?() }]
        rows += projects.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }.map { project in
            ComposerChoice(project.name, detail: SpookkyStyle.abbreviatedPath(project.location.path), symbol: "folder", selected: project.id == currentWorkspace?.projectID) { [weak self] in self?.onProject?(project.id) }
        }
        rows += [ComposerChoice("Use folder once…", symbol: "folder", alwaysVisible: true) { [weak self] in self?.onChooseFolder?() },
                 ComposerChoice("Add project…", symbol: "plus", alwaysVisible: true) { [weak self] in
                    guard let self else { return }; onAddProject?(folder)
                 }]
        choices.show(from: folder, title: "Choose project", search: "Search projects…", rows: rows)
    }
    private func chooseLocation() {
        guard let workspace = currentWorkspace else { return }
        locationPopover.performClose(nil)
        let local = currentProject?.location ?? workspace.selectedLocation
        let locationDraft = workspace.locationDraft
        let isNew = locationDraft?.mode == .worktree
        var rows = [ComposerChoice("Local", detail: "Use the project's current files and branch.", symbol: "folder", selected: !isNew && local.path == workspace.selectedLocation.path) { [weak self] in
            self?.locationOptions.onCheckout?(local)
        }]
        if let snapshot = repositorySnapshot {
            rows += snapshot.checkouts.filter { $0.path != local.scopePath }.map { checkout in
                ComposerChoice(checkout.branch ?? "Detached HEAD", detail: "Existing worktree · " + URL(fileURLWithPath: checkout.path).lastPathComponent,
                               symbol: "folder", selected: !isNew && checkout.identity == workspace.selectedLocation.checkoutIdentity,
                               action: checkout.available ? { [weak self] in self?.selectCheckout(checkout.path) } : nil)
            }
            rows.append(ComposerChoice("New worktree", detail: snapshot.head == nil ? "Requires a first commit." : "Start with a separate branch and files.",
                symbol: "arrow.triangle.branch", selected: isNew, action: snapshot.head == nil ? nil : { [weak self] in
                    guard let self else { return }
                    var draft = locationDraft ?? LocationDraft(); draft.mode = .worktree
                    if locationDraft == nil { draft.source = currentProject?.preferredSource ?? "HEAD" }
                    locationOptions.onDraft?(draft)
                }))
        } else { rows.append(ComposerChoice("Reading repository…")) }
        rows.append(ComposerChoice("Worktree options…", symbol: "slider.horizontal.3", alwaysVisible: true) { [weak self] in self?.showLocationPicker() })
        choices.show(from: location, title: "Choose location", search: "Search checkouts…", rows: rows)
    }
    private func selectCheckout(_ path: String) {
        guard let id = currentWorkspace?.id else { return }
        let project = currentWorkspace?.projectID
        Task { [weak self] in
            do {
                let result = try await GitRepository().discover(URL(fileURLWithPath: path))
                guard let self, currentWorkspace?.id == id, currentWorkspace?.projectID == project, prompt.isEditable else { return }
                locationOptions.onCheckout?(result)
            } catch { onError?("This checkout is unavailable. Choose another location.") }
        }
    }
    private func chooseSource() {
        guard let workspace = currentWorkspace else { return }
        let locationDraft = workspace.locationDraft
        if locationDraft?.branchMode == .existing { showLocationPicker(); return }
        var refs = [("Current HEAD", "HEAD")]
        refs += repositorySnapshot?.references.map { ($0.name, $0.qualifiedName) } ?? []
        var rows = refs.map { name, ref in
            ComposerChoice(name, symbol: "arrow.triangle.branch", selected: (locationDraft?.source ?? "HEAD") == ref) { [weak self] in
                var draft = locationDraft ?? LocationDraft()
                draft.mode = .worktree; draft.source = ref; draft.useCachedSource = false; draft.cachedCommit = nil
                self?.locationOptions.onDraft?(draft)
            }
        }
        rows.append(ComposerChoice("More worktree options…", symbol: "slider.horizontal.3", alwaysVisible: true) { [weak self] in self?.showLocationPicker() })
        choices.show(from: source, title: "Starting reference", search: "Search branches…", rows: rows)
    }
    private func chooseModel(refresh: Bool = false) {
        guard let tool = currentTool, tool != .shell, let directory = currentWorkspace?.directory else { return }
        locationPopover.performClose(nil)
        choices.show(from: model, title: tool.displayName + " model", search: "Search models…", rows: modelRows(loading: discoveredModels == nil))
        modelTask?.cancel()
        modelTask = Task { [weak self, modelCatalog] in
            let result = await modelCatalog.models(for: tool, directory: directory, refresh: refresh)
            guard !Task.isCancelled, let self,
                  currentTool == tool, currentWorkspace?.directory == directory else { return }
            discoveredModels = result; configureFooter()
            if choices.anchor === model { choices.update(modelRows()) }
        }
    }
    private func modelRows(loading: Bool = false) -> [ComposerChoice] {
        var rows = [ComposerChoice("Default model", detail: "Use your CLI configuration", selected: selection.model == nil, alwaysVisible: true) { [weak self] in self?.onModel?(AgentModelSelection()) }]
        for value in discoveredModels?.models ?? [] {
            let allowed = images.isEmpty || value.acceptsImages
            rows.append(ComposerChoice(value.name, detail: allowed ? nil : "Does not accept images", selected: selection.model == value.id,
                action: allowed ? { [weak self] in self?.onModel?(AgentModelSelection(model: value.id, displayName: value.name)) } : nil))
        }
        rows.append(ComposerChoice("Custom model…", alwaysVisible: true) { [weak self] in self?.customModel() })
        let efforts = currentTool == .codex ? discoveredModels?.models.first { $0.id == selection.model }?.efforts ?? [] : discoveredModels?.efforts ?? []
        if !efforts.isEmpty {
            rows.append(ComposerChoice("Reasoning effort"))
            rows.append(ComposerChoice("Default effort", selected: selection.effort == nil) { [weak self] in
                guard let self else { return }; var next = selection; next.effort = nil; onModel?(next)
            })
            rows += efforts.map { value in
                ComposerChoice(value.capitalized, selected: selection.effort == value) { [weak self] in
                    guard let self else { return }; var next = selection; next.effort = value; onModel?(next)
                }
            }
        }
        if loading { rows.append(ComposerChoice("Loading models…", alwaysVisible: true)) }
        if let issue = discoveredModels?.issue { rows.append(ComposerChoice("Model discovery unavailable", detail: issue, alwaysVisible: true)) }
        rows.append(ComposerChoice("Refresh models", symbol: "arrow.clockwise", alwaysVisible: true) { [weak self] in self?.chooseModel(refresh: true) })
        return rows
    }
    private func customModel() {
        let field = NSTextField(string: selection.model ?? "")
        field.placeholderString = "Model name or ID"; field.setAccessibilityLabel("Model name or ID")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        let alert = NSAlert(); alert.messageText = "Choose a custom model"
        alert.informativeText = "Enter a model supported by " + (currentTool?.displayName ?? "your provider") + "."
        alert.accessoryView = field; alert.addButton(withTitle: "Use model"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let next = AgentModelSelection(model: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard next.isValid else { onError?("Enter a model name without control characters, up to 256 bytes."); return }
        onModel?(next)
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
        !locationPopover.isShown && !choices.isShown &&
            ([prompt, launch, picker, model, attach, folder, location, source] as [NSView]).contains { window?.firstResponder === $0 }
    }
    var isImportingImage: Bool { importingImage }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { locationPopover.performClose(nil); choices.close(); modelTask?.cancel() }
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
