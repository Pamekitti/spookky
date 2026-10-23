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
    static let changesImage: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 3, y: 1.5, width: 10, height: 13), xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.25; outline.stroke()
            let signs = NSBezierPath(); signs.lineWidth = 1.25; signs.lineCapStyle = .round
            signs.move(to: NSPoint(x: 6, y: 10)); signs.line(to: NSPoint(x: 10, y: 10))
            signs.move(to: NSPoint(x: 8, y: 8)); signs.line(to: NSPoint(x: 8, y: 12))
            signs.move(to: NSPoint(x: 6, y: 5)); signs.line(to: NSPoint(x: 10, y: 5))
            signs.stroke(); return true
        }
        image.isTemplate = true; image.accessibilityDescription = "Changes"
        return image
    }()
    static func supportingImage(_ target: SupportingTarget) -> NSImage? {
        if case .changes = target { return changesImage }
        return NSImage(systemSymbolName: supportingSymbol(target), accessibilityDescription: nil)
    }
    private static func supportingSymbol(_ target: SupportingTarget) -> String {
        switch target {
        case .startPage: "globe"
        case .changes: "doc.text"
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
