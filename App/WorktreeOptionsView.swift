import AppKit
import SpookkyCore
import SpookkyGit
import SpookkyWorkspace

@MainActor final class WorktreeOptionsView: NSStackView, NSTextFieldDelegate {
    private let mode = ChromePopUpButton()
    private let checkout = ChromePopUpButton()
    private let source = ChromePopUpButton()
    private let branchMode = ChromePopUpButton()
    private let existing = ChromePopUpButton()
    private let branch = ChromeTextField()
    private let destination = ChromeTextField()
    private let cached = ChromeButton(checkboxWithTitle: "Use cached reference", target: nil, action: nil)
    private let detail = ChromeTextField(wrappingLabelWithString: "")
    private let top = ResponsiveStackView()
    private let branchRow = ResponsiveStackView()
    private var checkoutGroup: NSStackView!
    private var sourceGroup: NSStackView!
    private var destinationGroup: NSStackView!
    private var branchGroup: NSStackView!
    private var existingGroup: NSStackView!
    private var snapshot: RepositorySnapshot?
    private var draft = LocationDraft()
    private var cachedCommit: String?
    private var key = ""
    var onDraft: ((LocationDraft) -> Void)?
    var onCheckout: ((WorkspaceLocation) -> Void)?
    var compactComposer = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = 8
        top.spacing = SpookkyStyle.points(8); branchRow.spacing = SpookkyStyle.points(8)
        for control in [mode, checkout, source, branchMode, existing] { control.target = self; control.action = #selector(changed); SpookkyStyle.configure(control) }
        mode.menu?.autoenablesItems = false; checkout.menu?.autoenablesItems = false
        mode.addItems(withTitles: ["Local", "New worktree"])
        branchMode.addItems(withTitles: ["Automatic branch", "New branch", "Existing branch"])
        mode.setAccessibilityLabel("Checkout mode"); checkout.setAccessibilityLabel("Existing checkout")
        source.setAccessibilityLabel("Starting reference"); branchMode.setAccessibilityLabel("Working branch mode")
        existing.setAccessibilityLabel("Existing local branch")
        branch.placeholderString = "Branch name"; branch.setAccessibilityLabel("New branch name"); branch.delegate = self
        destination.setAccessibilityLabel("Worktree destination"); destination.delegate = self; destination.font = .systemFont(ofSize: SpookkyStyle.points(11))
        cached.target = self; cached.action = #selector(changed)
        detail.font = .systemFont(ofSize: SpookkyStyle.points(11)); detail.textColor = .secondaryLabelColor
        checkoutGroup = SpookkyStyle.fieldGroup("Checkout", control: checkout)
        sourceGroup = SpookkyStyle.fieldGroup("Starting reference", control: source)
        destinationGroup = SpookkyStyle.fieldGroup("Destination", control: destination)
        top.addArrangedSubview(SpookkyStyle.fieldGroup("Location", control: mode)); top.addArrangedSubview(checkoutGroup); top.addArrangedSubview(sourceGroup)
        branchGroup = SpookkyStyle.fieldGroup("Name", control: branch)
        existingGroup = SpookkyStyle.fieldGroup("Existing branch", control: existing)
        branchRow.addArrangedSubview(SpookkyStyle.fieldGroup("Branch", control: branchMode)); branchRow.addArrangedSubview(branchGroup); branchRow.addArrangedSubview(existingGroup)
        for view in [top, branchRow, destinationGroup!, cached, detail] { addArrangedSubview(view) }
        top.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        branchRow.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        for field in [branch, destination] { SpookkyStyle.configure(field); field.bezelStyle = .roundedBezel }
        destination.font = .monospacedSystemFont(ofSize: SpookkyStyle.points(11), weight: .regular)
        detail.textColor = SpookkyPalette.secondary
        mode.widthAnchor.constraint(equalToConstant: 140).displayScaled().isActive = true
        for control in [checkout, source, existing, branch] { control.widthAnchor.constraint(equalToConstant: 180).displayScaled().isActive = true }
        destinationGroup.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    func update(snapshot: RepositorySnapshot?, workspace: Workspace, project: Project?, operation: LocationOperation?, enabled: Bool) {
        self.snapshot = snapshot
        draft = workspace.locationDraft ?? LocationDraft()
        cachedCommit = operation?.cachedCommit
        isHidden = workspace.anchor != nil || !workspace.selectedLocation.isGit
        guard !isHidden else { return }
        let nextKey = snapshot?.generation.uuidString ?? ""
        if nextKey != key {
            key = nextKey
            source.removeAllItems(); source.addItem(withTitle: "Current HEAD")
            for ref in snapshot?.references ?? [] { source.addItem(withTitle: (ref.remote == nil ? "Local · " : "Remote · ") + ref.name) }
            checkout.removeAllItems(); for item in snapshot?.checkouts ?? [] { checkout.addItem(withTitle: (item.branch ?? "Detached HEAD") + " · " + URL(fileURLWithPath: item.path).lastPathComponent + (item.available ? "" : " · Unavailable")); checkout.lastItem?.isEnabled = item.available }
            existing.removeAllItems(); existing.addItem(withTitle: "Choose branch"); existing.addItems(withTitles: (snapshot?.references ?? []).filter { $0.remote == nil }.map(\.name))
        }
        mode.selectItem(at: draft.mode == .local ? 0 : 1)
        mode.item(at: 1)?.isEnabled = snapshot?.head != nil
        if let index = snapshot?.checkouts.firstIndex(where: { $0.identity == workspace.selectedLocation.checkoutIdentity }) { checkout.selectItem(at: index) }
        checkoutGroup.isHidden = draft.mode != .local || (snapshot?.checkouts.count ?? 0) <= 1
        let worktree = draft.mode == .worktree
        top.isHidden = compactComposer
        sourceGroup.isHidden = !worktree || draft.branchMode == .existing
        branchRow.isHidden = !worktree; destinationGroup.isHidden = !worktree
        branchMode.selectItem(at: [.automatic, .custom, .existing].firstIndex(of: draft.branchMode)!)
        branchGroup.isHidden = draft.branchMode != .custom; existingGroup.isHidden = draft.branchMode != .existing
        if branch.stringValue != draft.branch { branch.stringValue = draft.branch }
        if draft.branch.isEmpty { existing.selectItem(at: 0) } else { existing.selectItem(withTitle: draft.branch) }
        let refIndex = snapshot?.references.firstIndex { $0.qualifiedName == draft.source || $0.name == draft.source }
        source.selectItem(at: refIndex.map { $0 + 1 } ?? 0)
        source.toolTip = draft.source; branch.toolTip = draft.branch; existing.toolTip = draft.branch
        if let snapshot, snapshot.checkouts.indices.contains(checkout.indexOfSelectedItem) { checkout.toolTip = snapshot.checkouts[checkout.indexOfSelectedItem].path }
        let path = draft.destination.isEmpty ? project.map { LocationCoordinator.defaultDestination($0, workspaceID: workspace.id) } ?? "" : draft.destination
        if destination.stringValue != path { destination.stringValue = path }
        destination.toolTip = path
        let reused = draft.branchMode == .existing ? snapshot?.checkouts.first { $0.branch == draft.branch } : nil
        if reused != nil { destinationGroup.isHidden = true }
        let selectedSource = snapshot?.references.first { $0.name == draft.source || $0.qualifiedName == draft.source }?.qualifiedName ?? draft.source
        cached.isHidden = !worktree || draft.branchMode == .existing || operation?.request.source != selectedSource || cachedCommit == nil
        cached.title = cachedCommit.map { "Use cached commit · " + $0.prefix(8) } ?? "Use cached reference"
        cached.state = draft.useCachedSource ? .on : .off
        cached.toolTip = operation?.error
        if let reused, worktree { detail.stringValue = "Uses existing checkout · " + reused.path }
        else if worktree && draft.branchMode == .automatic { detail.stringValue = "Branch · " + LocationCoordinator.defaultBranch(workspaceID: workspace.id) }
        else { detail.stringValue = snapshot == nil ? "Reading repository…" : snapshot?.head == nil ? "Worktrees require a first commit." : "" }
        detail.isHidden = detail.stringValue.isEmpty
        for control in [mode, checkout, source, branchMode, existing, branch, destination, cached] as [NSControl] { control.isEnabled = enabled && snapshot != nil }
    }
    @objc private func changed(_ sender: NSControl) {
        guard let snapshot else { return }
        if sender === checkout, snapshot.checkouts.indices.contains(checkout.indexOfSelectedItem) {
            let item = snapshot.checkouts[checkout.indexOfSelectedItem]
            guard item.available else { return }
            Task { if let location = try? await GitRepository().discover(URL(fileURLWithPath: item.path)) { onCheckout?(location) } }
            return
        }
        draft.mode = mode.indexOfSelectedItem == 0 ? .local : .worktree
        draft.branchMode = [.automatic, .custom, .existing][branchMode.indexOfSelectedItem]
        draft.source = source.indexOfSelectedItem > 0 ? snapshot.references[source.indexOfSelectedItem - 1].qualifiedName : "HEAD"
        if draft.branchMode == .existing { draft.branch = existing.indexOfSelectedItem > 0 ? existing.titleOfSelectedItem ?? "" : "" }
        else if draft.branchMode == .custom { draft.branch = branch.stringValue }
        if sender === source { cached.state = .off; draft.cachedCommit = nil }
        draft.useCachedSource = cached.state == .on
        if sender === cached { draft.cachedCommit = cachedCommit }
        onDraft?(draft)
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === branch { draft.branch = branch.stringValue }
        if notification.object as? NSTextField === destination { draft.destination = destination.stringValue }
        onDraft?(draft)
    }
}
