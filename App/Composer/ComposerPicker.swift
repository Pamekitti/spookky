import AppKit
import ImageIO
import SpookkyCore
import SpookkyGit
import SpookkySyntax
import SpookkyWorkspace
import UniformTypeIdentifiers

final class ComposerDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class ComposerPopoverBackground: NSView {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { SpookkyPalette.raised.setFill(); bounds.fill() }
}

@MainActor final class SpookkyWelcomeMark: NSView {
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

@MainActor struct ComposerChoice {
    let title: String
    let detail: String?
    let symbol: String?
    let selected: Bool
    let alwaysVisible: Bool
    let closesPopover: Bool
    let action: (() -> Void)?
    init(_ title: String, detail: String? = nil, symbol: String? = nil, selected: Bool = false,
         alwaysVisible: Bool = false, closesPopover: Bool = true, action: (() -> Void)? = nil) {
        self.title = title; self.detail = detail; self.symbol = symbol; self.selected = selected
        self.alwaysVisible = alwaysVisible; self.closesPopover = closesPopover; self.action = action
    }
}

@MainActor final class ComposerChoicePopover: NSObject, NSSearchFieldDelegate, NSPopoverDelegate {
    private let popover = NSPopover()
    private let controller = NSViewController()
    private let search = NSSearchField()
    private let rows = NSStackView()
    private let scroll = NSScrollView()
    let accessory = NSStackView()
    var onDismiss: (() -> Void)?
    private var values: [ComposerChoice] = []
    private var buttons: [ActionButton] = []
    private var edge: NSRectEdge = .maxY
    private(set) weak var anchor: NSView?
    var isShown: Bool { popover.isShown }

    override init() {
        super.init()
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        controller.view = ComposerPopoverBackground(frame: NSRect(x: 0, y: 0, width: 320, height: 260))
        (controller.view as? ComposerPopoverBackground)?.onCancel = { [weak self] in self?.close() }
        popover.contentViewController = controller
        search.delegate = self; search.sendsSearchStringImmediately = true
        SpookkyStyle.configure(search)
        let document = ComposerDocumentView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = SpookkyStyle.points(2)
        rows.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(rows)
        accessory.orientation = .vertical; accessory.alignment = .leading; accessory.spacing = SpookkyStyle.points(4)
        accessory.isHidden = true
        let stack = NSStackView(views: [search, scroll, accessory])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = SpookkyStyle.points(6)
        stack.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 8).displayScaled(),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -8).displayScaled(),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 8).displayScaled(),
            stack.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -8).displayScaled(),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            accessory.widthAnchor.constraint(equalTo: stack.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor), rows.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor), rows.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        DisplayMetrics.registerRoot(controller.view)
    }
    func show(from anchor: NSView, title: String, search placeholder: String, rows: [ComposerChoice],
              searchable: Bool = true, preferredEdge: NSRectEdge = .maxY) {
        close(); self.anchor = anchor; search.stringValue = ""; search.placeholderString = placeholder
        edge = preferredEdge
        search.isHidden = !searchable
        popover.behavior = searchable ? .transient : .semitransient
        search.setAccessibilityLabel(placeholder); controller.view.setAccessibilityLabel(title)
        values = rows; render()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
        if searchable { controller.view.window?.makeFirstResponder(search) }
        else if let first = buttons.first { controller.view.window?.makeFirstResponder(first) }
    }
    func close() {
        let previous = anchor
        if popover.isShown { popover.performClose(nil) }
        anchor = nil
        if onDismiss == nil { previous?.window?.makeFirstResponder(previous) }
    }
    func setSearchable(_ enabled: Bool) {
        guard search.isHidden == enabled else { return }
        search.isHidden = !enabled
        if !enabled { search.stringValue = "" }
        render()
    }
    func update(_ values: [ComposerChoice]) { self.values = values; render() }
    private func render() {
        let focused = (controller.view.window?.firstResponder as? NSButton)?.title
        let scrollOrigin = scroll.contentView.bounds.origin
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        buttons = []
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = values.filter { $0.alwaysVisible || query.isEmpty || ($0.title + " " + ($0.detail ?? "")).localizedCaseInsensitiveContains(query) }
        var height: CGFloat = 0
        for value in matches {
            let button = ActionButton(value.title, symbol: value.selected ? "checkmark" : value.symbol,
                                      height: SpookkyStyle.points(value.detail == nil ? 32 : 52), action: {})
            button.detail = value.detail
            button.isEnabled = value.action != nil; button.selected = value.selected
            button.lineBreakMode = .byTruncatingMiddle; button.alignment = .left
            button.setAccessibilityLabel(value.title + (value.detail.map { " · " + $0 } ?? ""))
            button.toolTip = value.title + (value.detail.map { "\n" + $0 } ?? "")
            button.handler = { [weak self] in
                if value.closesPopover { self?.close() }
                value.action?()
            }
            button.onCancel = { [weak self] in self?.close() }
            button.onNavigate = { [weak self, weak button] key in
                guard let self, let button, let index = buttons.firstIndex(of: button) else { return }
                let next = max(0, min(buttons.count - 1, index + (key == 126 ? -1 : 1)))
                controller.view.window?.makeFirstResponder(buttons[next]); buttons[next].scrollToVisible(buttons[next].bounds)
            }
            let row = NSStackView(views: [button]); row.orientation = .vertical; row.alignment = .leading
            row.spacing = 0; rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            button.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            if value.action != nil { buttons.append(button) }
            height += SpookkyStyle.points(value.detail == nil ? 32 : 52)
        }
        if matches.isEmpty {
            let empty = SpookkyStyle.label("No matches"); rows.addArrangedSubview(empty); height = SpookkyStyle.points(32)
        }
        let content = anchor?.window?.contentView
        let available = content?.bounds.size ?? NSSize(width: 400, height: 600)
        let heightLimit: CGFloat
        if edge == .minY, let anchor, let window = anchor.window {
            let control = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            heightLimit = max(SpookkyStyle.points(120), window.frame.maxY - control.maxY - SpookkyStyle.points(56))
        } else { heightLimit = max(SpookkyStyle.points(140), available.height - SpookkyStyle.points(80)) }
        let chrome = search.isHidden ? SpookkyStyle.points(16) : SpookkyStyle.points(52)
        popover.contentSize = NSSize(width: min(SpookkyStyle.points(320), max(240, available.width - 24)),
            height: min(heightLimit, SpookkyStyle.points(400), max(SpookkyStyle.points(110), height + chrome + (accessory.isHidden ? 0 : accessory.fittingSize.height + SpookkyStyle.points(6)))))
        controller.view.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(scrollOrigin.y, max(0, scroll.documentView!.bounds.height - scroll.contentSize.height))))
        if let focused, let button = buttons.first(where: { $0.title == focused }) { controller.view.window?.makeFirstResponder(button) }
    }
    func controlTextDidChange(_ notification: Notification) { render() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        if command == #selector(NSResponder.moveDown(_:)), let first = buttons.first { controller.view.window?.makeFirstResponder(first); return true }
        if command == #selector(NSResponder.insertNewline(_:)), let first = buttons.first { first.performClick(nil); return true }
        return false
    }
    func popoverDidClose(_ notification: Notification) {
        if let onDismiss { onDismiss() }
        else if let anchor { anchor.window?.makeFirstResponder(anchor) }
    }
}
