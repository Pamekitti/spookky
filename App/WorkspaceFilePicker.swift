import AppKit
import SpookkyFiles

@MainActor final class WorkspaceFilePicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSPopoverDelegate {
    var onChoose: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    private let service = FileService()
    private let root: String
    private let search = ChromeSearchField()
    private let path = SpookkyStyle.label("")
    private let table = FilePickerTable()
    private let scroll = NSScrollView()
    private let notice = SpookkyStyle.label("")
    private var directory = ""
    private var entries: [FileEntry] = []
    private var task: Task<Void, Never>?
    private(set) var popover = NSPopover()
    init(root: String) { self.root = root; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Use init") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: SpookkyStyle.points(480), height: SpookkyStyle.points(380)))
        DisplayMetrics.registerRoot(view)
        search.placeholderString = "Search workspace files"; search.delegate = self
        search.setAccessibilityLabel("Search workspace files")
        path.font = .systemFont(ofSize: SpookkyStyle.points(11)); path.textColor = SpookkyPalette.secondary
        let back = ActionButton("Up", symbol: "chevron.up") { [weak self] in
            guard let self else { return }; directory = (directory as NSString).deletingLastPathComponent
            search.stringValue = ""; refresh()
        }
        let header = NSStackView(views: [back, path]); header.spacing = SpookkyStyle.points(8)
        table.addTableColumn(NSTableColumn(identifier: .init("file"))); table.headerView = nil
        table.style = .plain; table.rowHeight = SpookkyStyle.points(28); table.intercellSpacing = .zero
        table.backgroundColor = .clear; SpookkyStyle.suppressFocusRing(table)
        table.delegate = self; table.dataSource = self; table.target = self; table.action = #selector(choose)
        table.onReturn = { [weak self] in self?.choose() }
        table.setAccessibilityLabel("Workspace file results")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        notice.font = .systemFont(ofSize: SpookkyStyle.points(11)); notice.textColor = SpookkyPalette.secondary
        for item in [search, header, scroll, notice] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12).displayScaled(), search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12).displayScaled(),
            search.topAnchor.constraint(equalTo: view.topAnchor, constant: 12).displayScaled(), search.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            header.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8).displayScaled(), header.leadingAnchor.constraint(equalTo: search.leadingAnchor), header.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8).displayScaled(), scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            notice.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6).displayScaled(), notice.leadingAnchor.constraint(equalTo: search.leadingAnchor), notice.trailingAnchor.constraint(equalTo: search.trailingAnchor), notice.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8).displayScaled()
        ])
        refresh()
    }
    func show(relativeTo anchor: NSView) {
        popover.behavior = .transient; popover.contentViewController = self; popover.delegate = self
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        view.window?.makeFirstResponder(search)
    }
    func popoverDidClose(_ notification: Notification) { task?.cancel(); popover.contentViewController = nil; onDismiss?() }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    private func refresh() {
        task?.cancel(); let query = search.stringValue, folder = directory
        path.stringValue = folder.isEmpty ? (root as NSString).lastPathComponent : folder
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if !query.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
                let result = try await (query.isEmpty ? service.list(root: root, path: folder) : service.search(root: root, query: query, matchLimit: 100))
                try Task.checkCancellation()
                entries = Array(result.entries.prefix(100)); notice.stringValue = result.incomplete ? "Results limited. Narrow your search." : entries.isEmpty ? "No matching files" : "Return to open · Escape to dismiss"
                table.reloadData(); table.tableColumns.first?.width = scroll.contentSize.width
                if !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            } catch is CancellationError {} catch { entries = []; table.reloadData(); notice.stringValue = error.localizedDescription }
        }
    }
    @objc private func choose() {
        guard entries.indices.contains(table.selectedRow) else { return }
        let entry = entries[table.selectedRow]
        if entry.kind == .directory || entry.kind == .repository { directory = entry.path; search.stringValue = ""; refresh() }
        else if entry.kind == .regular { onChoose?(entry.path); popover.performClose(nil) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = SpookkyStyle.label(entries[row].path)
        field.lineBreakMode = .byTruncatingMiddle; field.toolTip = entries[row].path
        return field
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.insertNewline(_:)) { choose(); return true }
        if command == #selector(NSResponder.moveDown(_:)) { table.selectRowIndexes(IndexSet(integer: min(max(0, entries.count - 1), max(0, table.selectedRow + 1))), byExtendingSelection: false); return true }
        if command == #selector(NSResponder.moveUp(_:)) { table.selectRowIndexes(IndexSet(integer: max(0, table.selectedRow - 1)), byExtendingSelection: false); return true }
        if command == #selector(NSResponder.cancelOperation(_:)) { popover.performClose(nil); return true }
        return false
    }
}

@MainActor private final class FilePickerTable: NSTableView {
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { onReturn?() } else { super.keyDown(with: event) }
    }
}
