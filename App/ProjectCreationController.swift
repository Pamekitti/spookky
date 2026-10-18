import AppKit
import SpookkyCore
import SpookkyWorkspace

@MainActor final class ProjectCreationController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    let panel: NSWindow
    private let alert = ChromeAlert()
    private let name = ChromeTextField()
    private let url = ChromeTextField()
    private let git = ChromeButton(checkboxWithTitle: "Initialize Git repository", target: nil, action: nil)
    private let destination = ActionButton("Destination", symbol: "folder", action: {})
    private let path = ChromeTextField(wrappingLabelWithString: "")
    private let status = ChromeTextField(wrappingLabelWithString: "")
    private let fieldError = ChromeTextField(wrappingLabelWithString: "")
    private let submit: NSButton
    private let cancel: NSButton
    private var draft: ProjectCreationDraft
    private var task: Task<Void, Never>?
    var isWorking: Bool { task != nil }
    private var operationID: UUID?
    private weak var parentWindow: NSWindow?
    private let startingWorkspaceID: UUID?
    private let store: WorkspaceStore
    private let coordinator: LocationCoordinator
    var onSuccess: ((WorkspaceLocation) -> Void)?
    var onClose: (() -> Void)?

    init(draft: ProjectCreationDraft, store: WorkspaceStore, coordinator: LocationCoordinator) {
        self.draft = draft; self.store = store; self.coordinator = coordinator; startingWorkspaceID = store.state.selectedWorkspaceID
        panel = alert.window
        submit = alert.addButton(withTitle: draft.mode == .clone ? "Clone repository" : "Create project")
        cancel = alert.addButton(withTitle: "Cancel")
        super.init()
        panel.title = draft.mode == .clone ? "Clone repository" : "Create project"
        alert.messageText = panel.title
        panel.isReleasedWhenClosed = false; panel.delegate = self
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = SpookkyStyle.points(12)
        stack.frame = NSRect(x: 0, y: 0, width: 400, height: draft.mode == .clone ? 250 : 200)
        stack.widthAnchor.constraint(equalToConstant: 400).displayScaled().isActive = true
        alert.accessoryView = stack
        if draft.mode == .clone {
            stack.addArrangedSubview(SpookkyStyle.fieldGroup("Repository URL", control: url))
            url.placeholderString = "https://github.com/owner/repository.git"; url.stringValue = draft.repositoryURL
            url.setAccessibilityLabel("Repository URL")
        }
        stack.addArrangedSubview(SpookkyStyle.fieldGroup("Folder name", control: name))
        fieldError.font = .systemFont(ofSize: SpookkyStyle.points(11)); fieldError.textColor = SpookkyPalette.warning; fieldError.isHidden = true
        stack.addArrangedSubview(fieldError)
        name.stringValue = draft.name; name.placeholderString = "Project name"; name.setAccessibilityLabel("Project folder name")
        stack.addArrangedSubview(destination); stack.addArrangedSubview(path)
        if draft.mode == .create { stack.addArrangedSubview(git) }
        git.state = draft.initializeGit ? .on : .off; git.target = self; git.action = #selector(changed)
        status.textColor = SpookkyPalette.warning; status.font = .systemFont(ofSize: SpookkyStyle.points(12)); stack.addArrangedSubview(status)
        for field in [name] + (draft.mode == .clone ? [url] : []) {
            field.delegate = self; SpookkyStyle.configure(field, size: 13); field.bezelStyle = .roundedBezel
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        destination.alignment = .left; destination.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        destination.emphasis = .secondary
        git.font = .systemFont(ofSize: SpookkyStyle.points(12))
        path.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        fieldError.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        status.isHidden = true
        destination.handler = { [weak self] in self?.chooseDestination() }
        refreshPath()
    }
    func show(relativeTo window: NSWindow) {
        parentWindow = window; panel.appearance = window.appearance
        if let stack = alert.accessoryView as? NSStackView {
            stack.layoutSubtreeIfNeeded(); stack.setFrameSize(NSSize(width: 400, height: stack.fittingSize.height))
        }
        alert.layout()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { start() }
            else { panel.close() }
        }
        panel.makeFirstResponder(draft.mode == .clone ? url : name)
    }
    private func refreshPath() {
        destination.title = "Destination · " + SpookkyStyle.abbreviatedPath(draft.parentPath)
        destination.toolTip = draft.parentPath; destination.setAccessibilityLabel("Choose destination · " + draft.parentPath)
        path.stringValue = URL(fileURLWithPath: draft.parentPath).appendingPathComponent(draft.name).path
        path.textColor = SpookkyPalette.secondary; path.font = .monospacedSystemFont(ofSize: SpookkyStyle.points(11), weight: .regular)
        path.toolTip = path.stringValue
    }
    @objc private func changed() {
        let previousURL = draft.repositoryURL
        let previousName = Self.inferredName(previousURL)
        if draft.mode == .clone && previousURL != url.stringValue && (name.stringValue.isEmpty || name.stringValue == previousName) {
            name.stringValue = Self.inferredName(url.stringValue)
        }
        draft.name = name.stringValue; draft.repositoryURL = url.stringValue; draft.initializeGit = git.state == .on
        fieldError.isHidden = true
        store.update(debounced: true) { $0.projectDraft = draft }; refreshPath()
    }
    func controlTextDidChange(_ obj: Notification) { changed() }
    static func inferredName(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var name = value.split(separator: "/").last.map(String.init) ?? ""
        name = name.split(separator: ":").last.map(String.init) ?? name
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name
    }
    private func chooseDestination() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.directoryURL = URL(fileURLWithPath: draft.parentPath); picker.prompt = "Choose destination"
        picker.beginSheetModal(for: panel) { [weak self] result in
            guard result == .OK, let self, let selected = picker.url else { return }
            draft.parentPath = selected.path; changed()
        }
    }
    private func setBusy(_ value: Bool) {
        for control in [name, url, git, destination, submit] as [NSControl] { control.isEnabled = !value }
        cancel.title = value ? "Cancel operation" : "Cancel"
    }
    private func start() {
        guard task == nil else { return }
        changed()
        do {
            let request = try LocationCoordinator.projectRequest(draft)
            operationID = request.id; setBusy(true)
            status.isHidden = false; status.textColor = SpookkyPalette.secondary
            status.stringValue = "Preparing " + request.destination
            panel.orderOut(nil)
            task = Task { [weak self] in
                guard let self else { return }
                defer { task = nil; operationID = nil; setBusy(false) }
                do {
                    if let location = try await coordinator.start(request) {
                        store.update { $0.projectDraft = ProjectCreationDraft(parentPath: self.draft.parentPath) }
                        onSuccess?(location); panel.close()
                    }
                } catch {
                    setBusy(false)
                    status.stringValue = error is CancellationError ? "Cancelled. Your values and any partial files are retained." : error.localizedDescription
                    status.textColor = error is CancellationError ? SpookkyPalette.secondary : SpookkyPalette.warning
                    if let parentWindow, parentWindow.isVisible, parentWindow.attachedSheet == nil, store.state.selectedWorkspaceID == startingWorkspaceID { show(relativeTo: parentWindow) }
                    else { onClose?() }
                }
            }
        } catch {
            if let stack = alert.accessoryView as? NSStackView {
                let folder = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let validName = !folder.isEmpty && folder != "." && folder != ".." && !folder.contains("/") && !folder.contains("\0")
                let target: NSControl
                if case LaunchError.folderUnavailable = error { target = destination }
                else if !draft.parentPath.hasPrefix("/") || draft.parentPath.contains("\0") { target = destination }
                else { target = draft.mode == .clone && validName ? url : name }
                let anchor = stack.arrangedSubviews.first { view in view === target || target.isDescendant(of: view) }
                stack.removeArrangedSubview(fieldError); fieldError.removeFromSuperview()
                stack.insertArrangedSubview(fieldError, at: anchor.flatMap { stack.arrangedSubviews.firstIndex(of: $0) }.map { $0 + 1 } ?? stack.arrangedSubviews.count)
            }
            fieldError.stringValue = error.localizedDescription; fieldError.isHidden = false
            fieldError.setAccessibilityLabel(error.localizedDescription)
            if let parentWindow { DispatchQueue.main.async { self.show(relativeTo: parentWindow) } }
        }
    }
    func windowWillClose(_ notification: Notification) {
        if let operationID { coordinator.cancel(operationID) }
        parentWindow?.endSheet(panel); onClose?()
    }
}
