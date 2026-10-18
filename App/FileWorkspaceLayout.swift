import AppKit

final class FileWorkspaceLayout: NSView {
    let terminal: NSView
    let sidebar: NSView
    let preview: NSView
    let divider = FileDivider()
    var supportingOnly = false
    var showSidebar = false
    var showPreview = false
    var maximized = false
    var fraction = 0.5
    var onResize: ((Double) -> Void)?
    var onPreviewWidth: ((CGFloat) -> Void)?
    init(terminal: NSView, sidebar: NSView, preview: NSView) {
        self.terminal = terminal; self.sidebar = sidebar; self.preview = preview
        super.init(frame: .zero)
        DisplayMetrics.registerRoot(self)
        [terminal, preview, divider, sidebar].forEach { addSubview($0) }
        divider.onMove = { [weak self] x in
            guard let self else { return }
            fraction = min(0.8, max(0.2, x / max(1, bounds.width - (showSidebar ? SpookkyStyle.fileSidebarWidth : 0))))
            needsLayout = true; onResize?(fraction)
        }
        divider.onKey = { [weak self] delta in
            guard let self else { return }; fraction = min(0.8, max(0.2, fraction + delta)); needsLayout = true; onResize?(fraction)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        if supportingOnly {
            terminal.isHidden = true; divider.isHidden = true
            sidebar.isHidden = !showSidebar; preview.isHidden = !showPreview
            let side: CGFloat = showSidebar ? (showPreview ? min(SpookkyStyle.fileSidebarWidth, bounds.width * 0.38) : bounds.width) : 0
            sidebar.frame = NSRect(x: bounds.width - side, y: 0, width: side, height: bounds.height)
            preview.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - side), height: bounds.height)
            onPreviewWidth?(preview.bounds.width)
            return
        }
        let narrow = (window?.frame.width ?? bounds.width) < 800
        let sidebarWidth: CGFloat = showSidebar && !narrow ? SpookkyStyle.fileSidebarWidth : 0
        let available = bounds.width - sidebarWidth
        let fills = maximized || available < 620
        terminal.isHidden = showPreview && fills
        preview.isHidden = !showPreview; sidebar.isHidden = !showSidebar
        divider.isHidden = !showPreview || fills
        let left = showPreview && !fills ? max(1, available * fraction) : available
        terminal.frame = NSRect(x: 0, y: 0, width: left, height: bounds.height)
        preview.frame = NSRect(x: fills ? 0 : left + 5, y: 0, width: fills ? available : max(1, available - left - 5), height: bounds.height)
        divider.frame = NSRect(x: left, y: 0, width: 5, height: bounds.height)
        sidebar.frame = NSRect(x: max(0, bounds.width - SpookkyStyle.fileSidebarWidth), y: 0, width: min(SpookkyStyle.fileSidebarWidth, bounds.width), height: bounds.height)
        onPreviewWidth?(preview.bounds.width)
    }
}
final class FileDivider: NSView {
    var onMove: ((CGFloat) -> Void)?
    var onKey: ((Double) -> Void)?
    var onReset: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.splitter); setAccessibilityLabel("Resize file preview") }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { onReset?() }; window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) { onMove?(superview?.convert(event.locationInWindow, from: nil).x ?? 0) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 { onKey?(-0.05) } else if event.keyCode == 124 { onKey?(0.05) } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self && window?.isKeyWindow == true
        (focused ? SpookkyPalette.secondary : SpookkyPalette.border).setFill()
        NSRect(x: 2, y: 0, width: 1, height: bounds.height).fill()
    }
}
final class FileTable: NSTableView {
    override init(frame: NSRect = .zero) { super.init(frame: frame); SpookkyStyle.suppressFocusRing(self) }
    required init?(coder: NSCoder) { super.init(coder: coder); SpookkyStyle.suppressFocusRing(self) }
    var onKey: ((NSEvent) -> Bool)?
    var copyText: (() -> String)?
    var onMenu: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0 { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        return onMenu?(index)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 109, event.modifierFlags.contains(.shift), let menu = onMenu?(selectedRow) {
            menu.popUp(positioning: nil, at: NSPoint(x: 8, y: rect(ofRow: selectedRow).maxY), in: self)
            window?.makeFirstResponder(self); return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { copySelection(to: .general); return }
        if onKey?(event) == true { return }; super.keyDown(with: event)
    }
    @discardableResult func copySelection(to pasteboard: NSPasteboard) -> Bool {
        guard let text = copyText?(), !text.isEmpty else { return false }
        pasteboard.clearContents(); return pasteboard.setString(text, forType: .string)
    }
    @objc func copy(_ sender: Any?) { copySelection(to: .general) }
}

final class FileListCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = SpookkyStyle.label( "")
    private let parent = SpookkyStyle.label( "")
    private let status = SpookkyStyle.label( "")
    private var indent: NSLayoutConstraint!
    private var nameLeading: NSLayoutConstraint!
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [icon, name, parent, status] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        icon.contentTintColor = SpookkyPalette.secondary; icon.setAccessibilityElement(false)
        name.lineBreakMode = .byTruncatingMiddle
        parent.font = .systemFont(ofSize: SpookkyStyle.points(11)); parent.textColor = SpookkyPalette.secondary; parent.lineBreakMode = .byTruncatingMiddle
        status.font = .monospacedSystemFont(ofSize: SpookkyStyle.points(10), weight: .medium); status.textColor = SpookkyPalette.secondary
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        parent.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(751), for: .horizontal)
        indent = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).displayScaled()
        nameLeading = name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28).displayScaled()
        NSLayoutConstraint.activate([indent, icon.widthAnchor.constraint(equalToConstant: 14).displayScaled(), icon.heightAnchor.constraint(equalToConstant: 14).displayScaled(),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor), nameLeading,
            name.centerYAnchor.constraint(equalTo: centerYAnchor), parent.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6).displayScaled(),
            parent.centerYAnchor.constraint(equalTo: centerYAnchor), parent.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -8).displayScaled(),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).displayScaled(), status.centerYAnchor.constraint(equalTo: centerYAnchor)])
        textField = name
    }
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set { super.backgroundStyle = .normal }
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    func configure(path: String, symbol: String, status: String, depth: Int, group: Bool, showParent: Bool, help: String) {
        name.stringValue = group ? path : (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        parent.stringValue = showParent && directory != "." ? directory : ""
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); icon.isHidden = group
        icon.contentTintColor = symbol == "chevron.left.forwardslash.chevron.right" ? SpookkyPalette.syntax(.function) : SpookkyPalette.secondary
        let offset = CGFloat(min(depth, 30)) * 12
        DisplayMetrics.registerBase(8 + offset, for: indent); DisplayMetrics.registerBase((group ? 8 : 28) + offset, for: nameLeading)
        name.font = .systemFont(ofSize: SpookkyStyle.points(group ? 11 : 12), weight: group ? .medium : .regular)
        name.textColor = group ? SpookkyPalette.secondary : SpookkyPalette.text
        self.status.stringValue = status == "Added" ? "A" : status == "Deleted" ? "D" : status
        let statusName: String
        switch self.status.stringValue.first {
        case "A", "?": statusName = "Added"; self.status.textColor = SpookkyPalette.success
        case "D": statusName = "Deleted"; self.status.textColor = SpookkyPalette.destructive
        case "R": statusName = "Renamed"; self.status.textColor = SpookkyPalette.syntax(.function)
        case "U": statusName = "Conflict"; self.status.textColor = SpookkyPalette.warning
        case "M": statusName = "Modified"; self.status.textColor = SpookkyPalette.warning
        case "T": statusName = "Type changed"; self.status.textColor = SpookkyPalette.warning
        default: statusName = status; self.status.textColor = SpookkyPalette.secondary
        }
        self.status.toolTip = statusName; self.status.setAccessibilityLabel(statusName)
        toolTip = help; setAccessibilityLabel(path + (statusName.isEmpty ? "" : " · " + statusName))
    }
}

final class DiffCell: NSTableCellView {
    private struct Typography {
        let size: CGFloat
        let code: NSFont
        let comment: NSFont
        let paragraph: NSParagraphStyle
        init(size: CGFloat) {
            self.size = size
            code = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            comment = NSFont(descriptor: code.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? code
            let paragraph = NSMutableParagraphStyle(); paragraph.tabStops = []
            paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: code]).width * 4
            self.paragraph = paragraph
        }
    }
    private static var cachedTypography = Typography(size: SpookkyStyle.points(12))
    private static var typography: Typography {
        let size = SpookkyStyle.points(12)
        if cachedTypography.size != size { cachedTypography = Typography(size: size) }
        return cachedTypography
    }
    static var codeFont: NSFont { typography.code }
    static var commentFont: NSFont { typography.comment }
    static var codeParagraph: NSParagraphStyle { typography.paragraph }
    let label = SpookkyStyle.label( "")
    private let number: Bool
    private let sign: Bool
    init(identifier: NSUserInterfaceItemIdentifier, number: Bool, sign: Bool) {
        self.number = number; self.sign = sign
        super.init(frame: .zero); self.identifier = identifier
        addSubview(label); textField = label
        label.font = Self.codeFont
        label.lineBreakMode = .byClipping; label.alignment = number ? .right : sign ? .center : .left
    }
    override func layout() {
        super.layout()
        let leading: CGFloat = number || sign ? 0 : 8
        let trailing: CGFloat = number ? 6 : 0
        let height: CGFloat = 16
        label.frame = label.frame(forAlignmentRect: NSRect(x: leading, y: (bounds.height - height) / 2,
            width: max(0, bounds.width - leading - trailing), height: height))
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    required init?(coder: NSCoder) { fatalError("Use init") }
}

final class WorkspaceTableRow: NSTableRowView {
    var leftFill: NSColor?
    var rightFill: NSColor?
    var splitX: CGFloat?
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if let leftFill { leftFill.setFill(); NSRect(x: 0, y: 0, width: splitX ?? bounds.width, height: bounds.height).fill() }
        if let rightFill, let splitX { rightFill.setFill(); NSRect(x: splitX, y: 0, width: max(0, bounds.width - splitX), height: bounds.height).fill() }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4)
        SpookkyPalette.selected.setFill(); path.fill()
    }
}
