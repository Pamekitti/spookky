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
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearance?() }
}

enum SpookkyStyle {
    static let controlHeight: CGFloat = 28
    static let compactHeight: CGFloat = 24
    static let headerHeight: CGFloat = 40
    static let workspaceRowHeight: CGFloat = 46
    static let sidebarWidth: CGFloat = 232
    static let railWidth: CGFloat = 58
    static let fileSidebarWidth: CGFloat = 248
    static let composerWidth: CGFloat = 560
    static let composerRadius: CGFloat = 13
    static let cornerRadius: CGFloat = 8
    static let iconSlot: CGFloat = 16
    static let leadingIconSize: CGFloat = 14
    static let utilityIconSize: CGFloat = 14
    static let iconLabelGap: CGFloat = 6
    static let controlInset: CGFloat = 8
    static func configure(_ control: NSControl, size: CGFloat = 12) {
        control.font = .systemFont(ofSize: size)
        control.controlSize = .small
        if let popup = control as? NSPopUpButton { popup.isBordered = false }
    }
    static func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    static func fieldGroup(_ title: String, control: NSControl) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11); label.textColor = SpookkyPalette.metadata
        let group = NSStackView(views: [label, control])
        group.orientation = .vertical; group.alignment = .leading; group.spacing = 4
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
            let value = NSAttributedString(string: letters.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .semibold), .foregroundColor: SpookkyPalette.secondary])
            let size = value.size(); value.draw(at: NSPoint(x: (16 - size.width) / 2, y: (16 - size.height) / 2)); return true
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

final class ChromeStackView: NSStackView {
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var raised = false
    var cornerRadius: CGFloat = SpookkyStyle.cornerRadius
    var drawsTrailingBorder = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        (raised ? SpookkyPalette.raised : selected ? SpookkyPalette.selected : hovered ? SpookkyPalette.hover : .clear).setFill(); path.fill()
        if raised {
            let focused = (window?.firstResponder as? NSView)?.isDescendant(of: self) == true
            (focused ? NSColor.keyboardFocusIndicatorColor : SpookkyPalette.border).setStroke()
            path.lineWidth = focused ? 2 : 1; path.stroke()
        }
        if drawsTrailingBorder { SpookkyPalette.border.setFill(); NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class InlineRenameEditor: NSObject, NSTextFieldDelegate {
    private let field = NSTextField()
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
            NSAttributedString(string: "Start with a prompt…", attributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: SpookkyPalette.secondary])
                .draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height))
        }
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
}

final class ActionButton: NSButton {
    enum Emphasis { case quiet, secondary, primary, destructive }
    var emphasis: Emphasis = .quiet { didSet { needsDisplay = true } }
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    var drawsInteractionFill = true
    var handler: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    var onNavigate: ((UInt16) -> Void)?
    var contentInset: CGFloat = SpookkyStyle.controlInset
    var menuIndicator = false
    private var hovered = false
    private var tracking: NSTrackingArea?
    init(_ title: String, symbol: String? = nil, help: String? = nil, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title; target = self; self.action = #selector(invoke)
        isBordered = false; focusRingType = .none; font = .systemFont(ofSize: 13)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
        toolTip = help ?? title; setAccessibilityLabel(help ?? title)
        heightAnchor.constraint(greaterThanOrEqualToConstant: SpookkyStyle.controlHeight).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
        let iconWidth = image == nil ? 0 : SpookkyStyle.iconSlot + SpookkyStyle.iconLabelGap
        return NSSize(width: title.isEmpty ? SpookkyStyle.controlHeight :
            text + 2 * SpookkyStyle.controlInset + iconWidth + (menuIndicator ? 16 : 0), height: SpookkyStyle.controlHeight)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: SpookkyStyle.cornerRadius, yRadius: SpookkyStyle.cornerRadius)
        let fill: NSColor = switch emphasis {
        case .primary: SpookkyPalette.text
        case .secondary: SpookkyPalette.raised
        case .destructive: SpookkyPalette.destructive
        case .quiet: pressed || selected ? SpookkyPalette.selected : hovered ? SpookkyPalette.hover : .clear
        }
        if emphasis != .quiet || drawsInteractionFill && (selected || pressed || hovered && isEnabled) {
            fill.withAlphaComponent(fill.alphaComponent * (isEnabled ? 1 : 0.45)).setFill(); shape.fill()
        }
        if emphasis != .quiet, isEnabled, pressed || hovered {
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
                pointSize: utility ? SpookkyStyle.utilityIconSize : SpookkyStyle.leadingIconSize,
                weight: utility ? .medium : .regular).applying(.init(paletteColors: [tint]))
            let symbol = image.withSymbolConfiguration(config) ?? image
            let slot = NSRect(x: utility ? bounds.midX - SpookkyStyle.iconSlot / 2 : content.minX,
                y: bounds.midY - SpookkyStyle.iconSlot / 2, width: SpookkyStyle.iconSlot, height: SpookkyStyle.iconSlot)
            let size = symbol.size
            let scale = min(1, SpookkyStyle.iconSlot / max(size.width, size.height, 1))
            let drawn = NSRect(x: slot.midX - size.width * scale / 2, y: slot.midY - size.height * scale / 2,
                width: size.width * scale, height: size.height * scale)
            symbol.draw(in: drawn)
            if !utility {
                let width = SpookkyStyle.iconSlot + SpookkyStyle.iconLabelGap
                content.origin.x += width; content.size.width = max(0, content.width - width)
            }
        }
        if !title.isEmpty {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = alignment
            let label = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: tint, .paragraphStyle: paragraph])
            let h = label.size().height
            label.draw(in: NSRect(x: content.minX, y: bounds.midY - h / 2, width: content.width, height: h))
        }
        if window?.firstResponder === self, window?.isKeyWindow == true {
            NSColor.keyboardFocusIndicatorColor.setStroke(); shape.lineWidth = 2; shape.stroke()
        }
    }
    @objc private func invoke() { handler?() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
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
        if event.clickCount == 2, let onDoubleClick { onDoubleClick() } else { super.mouseDown(with: event) }
    }
}

final class ContextRow: NSView {
    var selected = false { didSet { if selected != oldValue { needsDisplay = true } } }
    private var hovered = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered {
            (selected ? SpookkyPalette.selected : SpookkyPalette.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: SpookkyStyle.cornerRadius, yRadius: SpookkyStyle.cornerRadius).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func mouseDown(with event: NSEvent) { primary?.handler?() }
    var icon: NSImageView?
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
    private let picker = ActionButton("Terminal", symbol: "terminal", help: "Choose launch tool", action: {})
    private var promptHeight: NSLayoutConstraint!
    private let promptScroll = NSScrollView()
    private let launch: ActionButton
    let locationOptions = WorktreeOptionsView(frame: .zero)
    var repositorySnapshot: RepositorySnapshot?
    private let context = ResponsiveStackView()
    private let card = ChromeStackView()
    private let terminalRow = NSStackView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let directory = NSTextField(labelWithString: "")
    private let recents = NSStackView()
    private let heading = NSTextField(labelWithString: "New workspace")
    private var currentTool: SessionTool?
    private var contextKey = ""
    private weak var projectPickerButton: ActionButton?
    private weak var recentsAddButton: ActionButton?
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
        launch = ActionButton("Open Terminal", symbol: "terminal", action: {})
        super.init(frame: .zero)
        heading.font = .systemFont(ofSize: 22, weight: .medium)
        heading.textColor = SpookkyPalette.text
        prompt.font = .systemFont(ofSize: 14)
        prompt.isRichText = false; prompt.allowsUndo = true; prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.textContainerInset = NSSize(width: 12, height: 12)
        prompt.delegate = self; prompt.drawsBackground = false; prompt.textColor = SpookkyPalette.text
        prompt.onFocusChange = { [weak card] in card?.needsDisplay = true }
        prompt.setAccessibilityLabel("Optional initial agent prompt")
        promptScroll.documentView = prompt; promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .noBorder; promptScroll.drawsBackground = false
        prompt.isVerticallyResizable = true; prompt.isHorizontallyResizable = false
        prompt.autoresizingMask = [.width]; prompt.textContainer?.widthTracksTextView = true
        promptHeight = promptScroll.heightAnchor.constraint(equalToConstant: 80); promptHeight.isActive = true
        promptScroll.autohidesScrollers = true
        picker.menuIndicator = true
        picker.handler = { [weak self] in self?.chooseTool() }
        launch.handler = { [weak self] in self?.onLaunch?() }
        let controls = NSStackView(views: [picker, NSView(), launch]); controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 8, right: 12)
        controls.heightAnchor.constraint(equalToConstant: SpookkyStyle.headerHeight).isActive = true
        launch.heightAnchor.constraint(equalToConstant: SpookkyStyle.controlHeight).isActive = true
        launch.emphasis = .primary
        card.orientation = .vertical; card.alignment = .leading; card.spacing = 4; card.raised = true; card.cornerRadius = SpookkyStyle.composerRadius
        card.addArrangedSubview(promptScroll); card.addArrangedSubview(controls)
        promptScroll.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
        controls.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
        context.orientation = .horizontal; context.spacing = 8; context.breakpoint = 400
        let terminal = ActionButton("Open Terminal  ⌘T", symbol: "terminal", help: "Open Terminal · ⌘T") { [weak self] in self?.onTerminal?() }
        terminal.emphasis = .secondary
        terminalRow.addArrangedSubview(terminal)
        terminalRow.spacing = 8
        directory.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        directory.textColor = SpookkyPalette.metadata; directory.lineBreakMode = .byTruncatingMiddle
        message.font = .systemFont(ofSize: 11); message.textColor = SpookkyPalette.secondary
        recents.orientation = .vertical; recents.alignment = .leading; recents.spacing = 4
        let stack = NSStackView(views: [heading, card, context, locationOptions, directory, message, terminalRow, recents])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        let scroll = NSScrollView(), document = ComposerDocumentView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false; document.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll); stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: document.widthAnchor, multiplier: 0.85)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = document.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: stack.heightAnchor, constant: 48), preferredHeight,
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor), stack.centerYAnchor.constraint(equalTo: document.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: SpookkyStyle.composerWidth),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -24),
            preferredWidth,
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            context.widthAnchor.constraint(equalTo: stack.widthAnchor),
            terminalRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            directory.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor),
            locationOptions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            recents.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    func update(_ tab: WorkspaceTab, workspace: Workspace, state: WorkspaceState) {
        heading.stringValue = workspace.anchor == nil && workspace.tabs.count == 1 ? "New workspace" : "New tab"
        if prompt.string != tab.draft.prompt { prompt.string = tab.draft.prompt }
        currentTool = tab.draft.tool
        picker.title = tab.draft.tool.displayName
        picker.image = NSImage(systemSymbolName: tab.draft.tool == .shell ? "terminal" : "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
        picker.setAccessibilityLabel("Launch tool · " + tab.draft.tool.displayName); picker.toolTip = "Choose launch tool · " + tab.draft.tool.displayName
        promptScroll.isHidden = tab.draft.tool == .shell
        let enabled = tab.isEditable
        locationOptions.update(snapshot: repositorySnapshot, workspace: workspace,
            project: state.projects.first { $0.id == workspace.projectID },
            operation: state.locations?.operations.first { $0.id == workspace.locationOperationID }, enabled: enabled)
        prompt.isEditable = enabled; picker.isEnabled = enabled
        let needsBranch = workspace.anchor == nil && workspace.locationDraft?.mode == .worktree && workspace.locationDraft?.branchMode == .existing && workspace.locationDraft?.branch.isEmpty == true
        launch.isEnabled = enabled && !needsBranch
        let launchTitle = tab.draft.tool == .shell ? "Open Terminal" : tab.draft.prompt.isEmpty ? "Open " + tab.draft.tool.displayName : "Start " + tab.draft.tool.displayName
        launch.title = tab.draft.tool == .shell ? launchTitle + "  ⌘T" : ""
        launch.image = NSImage(systemSymbolName: tab.draft.tool == .shell ? "terminal" : "arrow.up", accessibilityDescription: nil)
        launch.setAccessibilityLabel(launchTitle); launch.toolTip = launchTitle + (tab.draft.tool == .shell ? " · ⌘T" : " · ⌘Return")
        terminalRow.isHidden = tab.draft.tool == .shell
        terminalRow.arrangedSubviews.compactMap { $0 as? NSControl }.forEach { $0.isEnabled = enabled }
        card.needsDisplay = true
        let path = workspace.directory
        directory.stringValue = SpookkyStyle.abbreviatedPath(path)
        directory.toolTip = path
        let reusedCheckout = workspace.anchor == nil && workspace.locationDraft?.mode == .worktree && workspace.locationDraft?.branchMode == .existing &&
            repositorySnapshot?.checkouts.contains(where: { $0.branch == workspace.locationDraft?.branch }) == true
        directory.isHidden = reusedCheckout
        message.stringValue = tab.failure?.message ?? (enabled ? (tab.draft.tool == .shell ? "" : "Prompt optional · ⌘Return to start") : tab.status == .preparing ? "Preparing location…" : "Starting CLI…")
        message.isHidden = message.stringValue.isEmpty
        resizePrompt()
        message.textColor = tab.failure == nil ? SpookkyPalette.secondary : SpookkyPalette.warning
        recents.isHidden = workspace.anchor != nil || workspace.projectID != nil
        let nextContext = String(describing: workspace.projectID) + String(workspace.anchor != nil) + String(describing: tab.failure?.recovery) + String(enabled) +
            tab.draft.tool.rawValue + state.projects.map { $0.id.uuidString + $0.name + String(describing: $0.lastUsed) }.joined()
        guard contextKey != nextContext else { return }
        contextKey = nextContext
        let projects = state.projects
        for view in context.arrangedSubviews { context.removeArrangedSubview(view); view.removeFromSuperview() }
        if workspace.anchor == nil {
            let projectPicker = ActionButton(projects.first { $0.id == workspace.projectID }?.name ?? "Choose project", symbol: "folder") { [weak self] in
                guard let self, let button = self.projectPickerButton else { return }
                self.projectMenu(projects).popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            }
            projectPicker.toolTip = projects.first { $0.id == workspace.projectID }?.location.path ?? "Choose a project"
            projectPicker.menuIndicator = true
            projectPickerButton = projectPicker
            context.addArrangedSubview(projectPicker)
            context.addArrangedSubview(ActionButton("Use folder once…", action: { [weak self] in self?.onChooseFolder?() }))

        } else if tab.failure?.recovery == .locateFolder {
            context.addArrangedSubview(ActionButton("Locate folder…", symbol: "folder", action: { [weak self] in self?.onLocate?() }))
        }
        for control in context.arrangedSubviews.compactMap({ $0 as? NSControl }) {
            control.isEnabled = enabled; control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in recents.arrangedSubviews { recents.removeArrangedSubview(view); view.removeFromSuperview() }
        if workspace.anchor == nil && workspace.projectID == nil {
            let recentProjects = state.projects.filter { $0.lastUsed != nil }.sorted(by: { $0.lastUsed! > $1.lastUsed! }).prefix(5)
            if !recentProjects.isEmpty {
                let label = NSTextField(labelWithString: "Recent projects"); label.font = .systemFont(ofSize: 12, weight: .medium)
                recents.addArrangedSubview(label)
            }
            for project in recentProjects {
                let button = ActionButton(project.name, symbol: "folder", help: project.location.path) { [weak self] in self?.onProject?(project.id) }
                let path = NSTextField(labelWithString: SpookkyStyle.abbreviatedPath(project.location.path))
                path.font = .systemFont(ofSize: 11); path.textColor = SpookkyPalette.metadata; path.lineBreakMode = .byTruncatingMiddle
                path.toolTip = project.location.path
                path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let row = NSStackView(views: [button, NSView(), path]); row.spacing = 8
                recents.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: recents.widthAnchor).isActive = true
            }
            let addProject = ActionButton("Add project…", symbol: "plus") { [weak self] in
                guard let self else { return }; self.onAddProject?(self.recentsAddButton ?? self.recents)
            }
            recentsAddButton = addProject
            recents.addArrangedSubview(addProject)
        }
    }
    func focus() { window?.makeFirstResponder(currentTool == .shell ? launch : prompt) }
    var hasInputFocus: Bool { window?.firstResponder === prompt || window?.firstResponder === launch || window?.firstResponder === picker }
    private func projectMenu(_ projects: [Project]) -> NSMenu {
        let menu = NSMenu()
        for project in projects {
            let item = ClosureMenuItem(project.name + " · " + SpookkyStyle.abbreviatedPath(project.location.path)) { [weak self] in self?.onProject?(project.id) }
            item.toolTip = project.location.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Add project…") { [weak self] in
            guard let self else { return }; self.onAddProject?(self.projectPickerButton ?? self.context)
        })
        return menu
    }
    private func chooseTool() {
        let menu = NSMenu()
        for tool in [SessionTool.shell, .codex, .claude] {
            let item = ClosureMenuItem(tool.displayName) { [weak self] in self?.onDraft?(tool, nil); self?.focus() }
            item.state = currentTool == tool ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: picker.bounds.height), in: picker)
    }
    override func layout() { super.layout(); resizePrompt() }
    private func resizePrompt() {
        guard let manager = prompt.layoutManager, let container = prompt.textContainer, promptScroll.contentSize.width > 0 else { return }
        manager.ensureLayout(for: container)
        let content = manager.usedRect(for: container).height + prompt.textContainerInset.height * 2
        let height = max(80, min(content, 300, max(80, bounds.height / 2)))
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
    override var mouseDownCanMoveWindow: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        SpookkyPalette.background.setFill(); bounds.fill()
        SpookkyPalette.sidebar.setFill(); NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height).fill()
        SpookkyPalette.border.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
final class TabStripScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class WorkspaceNativeWindow: NSWindow {
    var onCommand: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onCommand?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
