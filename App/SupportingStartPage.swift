import AppKit
import SpookkyCore

enum SupportingTool: CaseIterable {
    case changes, terminal, files, artifact
    var title: String { switch self { case .changes: "Changes"; case .terminal: "Terminal"; case .files: "Files"; case .artifact: "Open artifact" } }
    @MainActor var image: NSImage? {
        switch self {
        case .changes: SpookkyStyle.changesImage
        case .terminal: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        case .files: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        case .artifact: NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        }
    }
}

@MainActor final class SupportingStartPage: NSView {
    var onAddress: ((String) -> Void)?
    var onTool: ((SupportingTool) -> Void)?
    var onRecent: ((SupportingTarget, String) -> Void)?
    private let address = ChromeTextField()
    private let scroll = NSScrollView()
    private let canvas = StartPageCanvas()
    private let stack = NSStackView()
    private let retainedSection = NSStackView()
    private var retainedKeys: [String] = []
    private var toolRows: [NSStackView] = []
    private var singleColumnWidths: [NSLayoutConstraint] = []
    private var singleColumn = false
    init(recent: [SupportingTab], retainedTerminals: [WorkspaceTab] = []) {
        super.init(frame: .zero)
        DisplayMetrics.registerRoot(self)
        address.placeholderString = "Search or enter a URL"; address.setAccessibilityLabel("Search or enter a URL")
        SpookkyStyle.configure(address, size: 13)
        address.target = self; address.action = #selector(submit)
        let heading = SpookkyStyle.label("Tools"); heading.textColor = SpookkyPalette.secondary
        let tools = NSStackView(); tools.orientation = .vertical; tools.spacing = SpookkyStyle.points(8)
        for pair: [SupportingTool] in [[.changes, .terminal], [.files, .artifact]] {
            let row = NSStackView(); row.distribution = .fillEqually; row.spacing = SpookkyStyle.points(8)
            for tool in pair {
                let button = ActionButton(tool.title) { [weak self] in self?.onTool?(tool) }
                button.image = tool.image; button.imagePosition = .imageLeading
                button.alignment = .left; button.emphasis = .secondary
                button.heightAnchor.constraint(equalToConstant: 36).displayScaled().isActive = true
                row.addArrangedSubview(button)
                singleColumnWidths.append(button.widthAnchor.constraint(equalTo: row.widthAnchor))
            }
            tools.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: tools.widthAnchor).isActive = true
            toolRows.append(row)
        }
        [address, heading, tools].forEach { stack.addArrangedSubview($0) }; stack.orientation = .vertical; stack.alignment = .leading
        stack.spacing = SpookkyStyle.points(20); stack.translatesAutoresizingMaskIntoConstraints = false
        for tab in recent.reversed().prefix(5) where tab.target != .startPage {
            let button = ActionButton(tab.displayTitle) { [weak self] in self?.onRecent?(tab.target, tab.displayTitle) }
            button.image = SpookkyStyle.supportingImage(tab.target); button.imagePosition = .imageLeading
            button.alignment = .left; stack.addArrangedSubview(button)
        }
        retainedSection.orientation = .vertical; retainedSection.alignment = .leading
        retainedSection.spacing = SpookkyStyle.points(12); stack.addArrangedSubview(retainedSection)
        updateRetainedTerminals(retainedTerminals)
        scroll.documentView = canvas; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false; scroll.horizontalScrollElasticity = .none
        addSubview(scroll); canvas.addSubview(stack)
        let flexibleWidth = stack.widthAnchor.constraint(equalTo: canvas.widthAnchor, constant: -48).displayScaled()
        flexibleWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: canvas.centerXAnchor), stack.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 40).displayScaled(),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 720).displayScaled(),
            flexibleWidth,
            address.widthAnchor.constraint(equalTo: stack.widthAnchor), address.heightAnchor.constraint(equalToConstant: 32).displayScaled(),
            tools.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    func updateRetainedTerminals(_ terminals: [WorkspaceTab]) {
        let keys = terminals.map { $0.id.uuidString + $0.title + $0.status.rawValue }
        guard keys != retainedKeys else { return }; retainedKeys = keys
        retainedSection.arrangedSubviews.forEach { retainedSection.removeArrangedSubview($0); $0.removeFromSuperview() }
        retainedSection.isHidden = terminals.isEmpty
        guard !terminals.isEmpty else { return }
        let heading = SpookkyStyle.label("Reopen terminal"); heading.textColor = SpookkyPalette.secondary
        retainedSection.addArrangedSubview(heading)
        for terminal in terminals {
            let label = terminal.title + (terminal.status == .ended ? " · Ended" : "")
            let target = SupportingTarget.terminal(tabID: terminal.id), title = terminal.title
            let button = ActionButton(label, symbol: "terminal") { [weak self] in self?.onRecent?(target, title) }
            button.identifier = .init("reopen-terminal:" + terminal.id.uuidString)
            button.toolTip = "Reattach this terminal view · " + (terminal.startDirectory ?? terminal.binding?.directory ?? "")
            button.alignment = .left; retainedSection.addArrangedSubview(button)
        }
        needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    override func layout() {
        super.layout(); scroll.frame = bounds
        let narrow = scroll.contentSize.width < SpookkyStyle.points(420)
        if narrow != singleColumn {
            singleColumn = narrow
            for row in toolRows { row.orientation = narrow ? .vertical : .horizontal }
            for constraint in singleColumnWidths { constraint.isActive = narrow }
        }
        canvas.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(bounds.height, canvas.frame.height)))
        canvas.layoutSubtreeIfNeeded()
        canvas.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(bounds.height, stack.fittingSize.height + SpookkyStyle.points(80))))
    }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(address) == true }
    @objc private func submit() { onAddress?(address.stringValue) }
}

@MainActor private final class StartPageCanvas: NSView { override var isFlipped: Bool { true } }
