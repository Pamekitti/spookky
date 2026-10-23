import AppKit
import ImageIO
import SpookkyCore
import SpookkyGit
import SpookkySyntax
import SpookkyWorkspace
import UniformTypeIdentifiers

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
    private let attach = ActionButton("", symbol: "plus", help: "Attach images", height: SpookkyStyle.points(32), action: {})
    private let newWorktree = NSSwitch()
    private let worktreeLabel = SpookkyStyle.label("New worktree")
    private let worktreeHelp = SpookkyStyle.label("")
    private let worktreeToggle = NSStackView()
    private let options = ActionButton("Options…", help: "Worktree options", action: {})
    private let heading = ChromeTextField(wrappingLabelWithString: "What would you like to work on?")
    private let welcome = NSStackView()
    private let context = ResponsiveStackView()
    private let leftControls = NSStackView(), rightControls = NSStackView()
    private let footerSpacer = NSView()
    private let modelSpacer = NSView()
    private var footerHeight: NSLayoutConstraint!
    private var rightWidth: NSLayoutConstraint!
    private let choices = ComposerChoicePopover()
    private let modelChoices = ComposerChoicePopover()
    private lazy var modelMenu: ComposerModelMenu = {
        let menu = ComposerModelMenu(footer: modelChoices.accessory)
        menu.onEffort = { [weak self] value in
            guard let self else { return }
            var next = selection; next.effort = value; onModel?(next)
        }
        menu.onFullAccess = { [weak self] in self?.onFullAccess?($0) }
        menu.onCancel = { [weak self] in self?.modelChoices.close() }
        return menu
    }()
    private let modelCatalog: any ProviderModelDiscovering
    private var discoveredModels: ProviderModels?
    private var catalogKey = ""
    private var modelTask: Task<Void, Never>?
    private var selection = AgentModelSelection()
    private var fullAccess = false
    private var currentWorkspace: Workspace?
    private var currentProject: Project? { projects.first { $0.id == currentWorkspace?.projectID } }
    private let launch = ActionButton("", symbol: "arrow.up", height: SpookkyStyle.points(32), action: {})
    private let card = ChromeStackView()
    private let suggestions = ChromeStackView()
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
    private let errorNotice = AppErrorNoticeView(frame: .zero)
    private let terminalRow = NSStackView()
    private let terminal = ActionButton("Open Terminal", symbol: "terminal", help: "Open Terminal and keep this session draft", action: {})
    private let locationPopover = NSPopover()
    private let locationPanel = NSStackView()
    private let directory = SpookkyStyle.label( "")
    private let locate = ActionButton("Locate folder…", symbol: "folder", action: {})
    private var projects: [Project] = []
    private var currentTool: SessionTool?
    private var skillLocation = ""
    private var skills: [SkillSuggestion] = []
    private var matches: [SkillSuggestion] = []
    private var completionToken: SkillCompletionToken?
    private var selectedSuggestion = 0
    private var folderTitle = "Home"
    var onDraft: ((SessionTool?, String?) -> Void)?
    var onImages: (([String]) -> Void)?
    var onModel: ((AgentModelSelection) -> Void)?
    var onFullAccess: ((Bool) -> Void)?
    var onRecallModel: ((String) -> AgentModelSelection?)?
    var onNoProject: (() -> Void)?
    var onError: ((String) -> Void)?
    var onLaunch: (() -> Void)?
    var onTerminal: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onProject: ((UUID) -> Void)?
    var onAddProject: ((NSView) -> Void)?
    var onLocate: (() -> Void)?
    var onFocus: (() -> Void)?
    var onRetryError: (() -> Void)?
    var onUseLocal: (() -> Void)?
    var onDismissError: (() -> Void)?

    init(tabID: UUID, imageDirectory: URL, modelCatalog: any ProviderModelDiscovering = ProviderModelCatalog.shared) {
        self.tabID = tabID; self.imageDirectory = imageDirectory; self.modelCatalog = modelCatalog
        super.init(frame: .zero)
        prompt.font = .systemFont(ofSize: SpookkyStyle.points(14))
        prompt.isRichText = false; prompt.allowsUndo = true; prompt.isAutomaticQuoteSubstitutionEnabled = false
        prompt.isAutomaticDashSubstitutionEnabled = false
        DisplayMetrics.registerRoot(self)
        prompt.textContainerInset = NSSize(width: 16, height: 16)
        prompt.textContainer?.lineFragmentPadding = 0
        prompt.delegate = self; prompt.drawsBackground = false; prompt.textColor = SpookkyPalette.text
        prompt.onFocusChange = { [weak self] in
            guard let self else { return }; card.needsDisplay = true
        }
        prompt.onCompletionKey = { [weak self] event in self?.handleCompletionKey(event) ?? false }
        prompt.onPasteImage = { [weak self] data in self?.pasteImage(data) }
        prompt.setAccessibilityLabel("Optional prompt for new session")
        promptScroll.documentView = prompt; promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .noBorder; promptScroll.drawsBackground = false
        prompt.isVerticallyResizable = true; prompt.isHorizontallyResizable = false
        prompt.autoresizingMask = [.width]; prompt.textContainer?.widthTracksTextView = true
        promptHeight = promptScroll.heightAnchor.constraint(equalToConstant: 64).displayScaled(); promptHeight.isActive = true
        promptScroll.autohidesScrollers = true
        picker.menuIndicator = true; folder.menuIndicator = true; location.menuIndicator = true; model.menuIndicator = true
        picker.handler = { [weak self] in self?.chooseTool() }
        folder.handler = { [weak self] in self?.chooseProject() }
        location.handler = { [weak self] in self?.chooseLocation() }
        source.handler = { [weak self] in self?.chooseSource() }
        model.handler = { [weak self] in self?.chooseModel() }
        attach.handler = { [weak self] in self?.chooseImages() }
        launch.handler = { [weak self] in
            guard let self, launch.isEnabled else { return }; onLaunch?()
        }
        prompt.onSubmit = { [weak self] in self?.submit() }
        modelChoices.onDismiss = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, window?.isKeyWindow == true,
                      !choices.isShown, !locationPopover.isShown, !modelChoices.isShown else { return }; focus()
            }
        }
        launch.emphasis = .primary
        launch.circular = true; attach.circular = true
        launchWidth = launch.widthAnchor.constraint(equalToConstant: 32).displayScaled(); launchWidth.isActive = true
        attach.widthAnchor.constraint(equalToConstant: 32).displayScaled().isActive = true
        footerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        leftControls.addArrangedSubview(attach); leftControls.addArrangedSubview(picker)
        modelSpacer.setContentHuggingPriority(.init(1), for: .horizontal); modelSpacer.isHidden = true
        rightControls.addArrangedSubview(modelSpacer); rightControls.addArrangedSubview(model); rightControls.addArrangedSubview(launch)
        leftControls.spacing = SpookkyStyle.points(4); rightControls.spacing = SpookkyStyle.points(4)
        rightControls.alignment = .centerY; leftControls.alignment = .centerY
        for view in [leftControls, footerSpacer, rightControls] { controls.addArrangedSubview(view) }
        controls.spacing = SpookkyStyle.points(4); controls.alignment = .centerY
        controls.edgeInsets = NSEdgeInsets(top: 0, left: SpookkyStyle.points(12), bottom: SpookkyStyle.points(12), right: SpookkyStyle.points(12))
        footerHeight = controls.heightAnchor.constraint(equalToConstant: 44).displayScaled()
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
        suggestions.orientation = .vertical; suggestions.alignment = .leading
        suggestions.spacing = SpookkyStyle.points(2)
        suggestions.edgeInsets = NSEdgeInsets(top: SpookkyStyle.points(6), left: SpookkyStyle.points(6),
                                             bottom: SpookkyStyle.points(6), right: SpookkyStyle.points(6))
        suggestions.raised = true; suggestions.cornerRadius = SpookkyStyle.composerRadius
        suggestions.isHidden = true
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
        newWorktree.target = self; newWorktree.action = #selector(toggleWorktree)
        newWorktree.setAccessibilityLabel("New worktree")
        SpookkyStyle.suppressFocusRing(newWorktree)
        worktreeLabel.font = .systemFont(ofSize: SpookkyStyle.points(12))
        worktreeLabel.textColor = SpookkyPalette.secondary
        worktreeToggle.spacing = SpookkyStyle.points(6); worktreeToggle.alignment = .centerY
        worktreeToggle.addArrangedSubview(worktreeLabel); worktreeToggle.addArrangedSubview(newWorktree)
        let toggleSpacer = NSView(); toggleSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        worktreeToggle.insertArrangedSubview(toggleSpacer, at: 1)
        context.spacing = SpookkyStyle.points(4); context.breakpoint = SpookkyStyle.points(300)
        for view in [folder, location, source] { context.addArrangedSubview(view) }
        folder.contentTintColor = SpookkyPalette.secondary; location.contentTintColor = SpookkyPalette.secondary
        options.handler = { [weak self] in self?.showLocationPicker() }
        worktreeHelp.font = .systemFont(ofSize: SpookkyStyle.points(11)); worktreeHelp.textColor = SpookkyPalette.secondary
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
        let stack = NSStackView(views: [welcome, message, errorNotice, card, suggestions, context, terminalRow])
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
            suggestions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            context.widthAnchor.constraint(equalTo: stack.widthAnchor),
            welcome.widthAnchor.constraint(equalTo: stack.widthAnchor), heading.widthAnchor.constraint(equalTo: welcome.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        errorNotice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        configureLocationPicker()
        locationOptions.compactComposer = true
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
        let promptChanged = prompt.string != tab.draft.prompt
        if promptChanged { prompt.string = tab.draft.prompt }
        currentTool = tab.draft.tool; projects = state.projects
        currentWorkspace = workspace; selection = tab.draft.modelSelection; fullAccess = tab.draft.fullAccess
        loadSkillsIfNeeded(tool: tab.draft.tool, directory: workspace.directory)
        if promptChanged { refreshSuggestions() }
        let project = currentProject
        let nextCatalogKey = tab.draft.tool.rawValue + "|" + workspace.directory
        if catalogKey != nextCatalogKey {
            catalogKey = nextCatalogKey; discoveredModels = nil; modelTask?.cancel(); choices.close(); modelChoices.close()
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
        launch.setAccessibilityLabel(launchTitle); launch.toolTip = launchTitle + " · Return or ⌘Return"
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
        worktreeToggle.isHidden = !git
        newWorktree.state = isNew ? .on : .off
        newWorktree.isEnabled = canChooseLocation && repositorySnapshot?.head != nil
        worktreeHelp.stringValue = !git ? "" : repositorySnapshot == nil ? "Reading repository…" : repositorySnapshot?.head == nil ? "Worktrees require a first commit." : ""
        worktreeHelp.isHidden = worktreeHelp.stringValue.isEmpty
        newWorktree.toolTip = worktreeHelp.isHidden ? "Start in a separate branch and files" : worktreeHelp.stringValue
        options.isHidden = !isNew; options.isEnabled = canChooseLocation
        let draft = workspace.locationDraft ?? LocationDraft()
        source.title = isNew ? (draft.branchMode == .existing ? (draft.branch.isEmpty ? "Choose branch" : draft.branch) : "From " + draft.source.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/remotes/", with: "")) :
            (workspace.anchor?.branch ?? workspace.selectedLocation.branch ?? "Detached HEAD")
        source.toolTip = source.title; source.menuIndicator = isNew; source.isEnabled = canChooseLocation && isNew
        folder.toolTip = folderTitle + "\n" + path
        folder.setAccessibilityLabel("Choose folder or project · " + folderTitle)
        locate.isHidden = !needsLocate
        let operation = workspace.locationOperationID.flatMap { id in state.locations?.operations.first { $0.id == id } }
        let worktreeFailure = operation.flatMap { op -> LocationOperation? in
            workspace.locationDraft?.mode == .worktree && op.request.kind == .worktree &&
                [.failed, .uncertain, .cancelled].contains(op.status) ? op : nil
        }
        let failure = tab.failure?.noticeDismissed == true || worktreeFailure?.noticeDismissed == true ? nil : tab.failure
        if let worktreeFailure, worktreeFailure.noticeDismissed != true, failure != nil {
            let detail = worktreeFailure.error ?? failure?.message ?? "Worktree creation failed."
            let missingLFS = detail.contains("git-lfs: command not found")
            let title = missingLFS ? "Couldn’t create worktree. Git LFS is unavailable." : "Couldn’t create worktree."
            errorNotice.update(id: worktreeFailure.id.uuidString, title: title, detail: detail,
                canRetry: worktreeFailure.status == .failed, canUseLocal: true,
                retry: onRetryError, useLocal: onUseLocal, dismiss: onDismissError)
        } else if let failure {
            errorNotice.update(id: tab.id.uuidString + failure.message, title: "Couldn’t start session.",
                detail: failure.message, canRetry: tab.isEditable,
                retry: onRetryError, dismiss: onDismissError)
        } else { errorNotice.update(id: nil) }
        if needsBranch { message.stringValue = "Choose an existing branch before starting." }
        else {
            switch tab.status {
            case .preparing: message.stringValue = "Preparing location…"
            case .launching: message.stringValue = "Starting " + tab.draft.tool.displayName + "…"
            case .uncertain: message.stringValue = "Session status needs checking."
            case .unavailable: message.stringValue = "Session unavailable."
            case .failed: message.stringValue = ""
            default: message.stringValue = ""
            }
        }
        message.isHidden = message.stringValue.isEmpty; message.toolTip = message.stringValue
        message.setAccessibilityLabel(message.stringValue)
        message.textColor = needsBranch || [.failed, .uncertain, .unavailable].contains(tab.status) ? SpookkyPalette.warning : SpookkyPalette.secondary
        configureFooter(); resizePrompt(); card.needsDisplay = true
        if modelChoices.isShown { updateModelChoices() }
        if choices.isShown && choices.anchor === location { choices.update(checkoutRows()) }
        if locationPopover.isShown { resizeLocationPicker() }
    }

    private func configureFooter() {
        let tool = currentTool ?? .codex, compact = card.bounds.width > 0 && card.bounds.width < SpookkyStyle.points(420)
        let providerTitle = compact && tool == .claude ? "Claude" : tool.displayName
        if picker.title != providerTitle { picker.title = providerTitle }
        if folder.title != folderTitle { folder.title = folderTitle }
        let modelName = discoveredModels?.models.first { $0.id == selection.model }?.name ?? selection.displayName ?? selection.model ?? "Default model"
        let modelTitle = modelName + (selection.effort.map { " · " + $0.capitalized } ?? "") + (fullAccess ? " · Full access" : "")
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
        footerHeight.constant = SpookkyStyle.points(compact ? 80 : 44)
        let launchTitle = tool == .shell && card.bounds.width >= SpookkyStyle.points(380) ? "Open Terminal" : ""
        if launch.title != launchTitle { launch.title = launchTitle }
        launch.circular = launchTitle.isEmpty
        let width = launchTitle.isEmpty ? SpookkyStyle.points(32) : launch.intrinsicContentSize.width
        if abs(launchWidth.constant - width) > 0.5 { launchWidth.constant = width }
        prompt.textContainerInset = NSSize(width: SpookkyStyle.points(16), height: SpookkyStyle.points(16))
    }
    private func showLocationPicker() {
        choices.close(); modelChoices.close()
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
        clearCheckoutAccessory()
        modelChoices.close()
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
    private func clearCheckoutAccessory() {
        for view in choices.accessory.arrangedSubviews { choices.accessory.removeArrangedSubview(view); view.removeFromSuperview() }
        choices.accessory.isHidden = true
    }
    private func chooseLocation() {
        modelChoices.close(); locationPopover.performClose(nil)
        clearCheckoutAccessory()
        let footer = choices.accessory
        footer.isHidden = false
        let separator = NSBox(); separator.boxType = .separator
        for view in [separator, worktreeToggle, worktreeHelp, options] { footer.addArrangedSubview(view) }
        separator.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        worktreeToggle.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        choices.show(from: location, title: "Choose location", search: "Search checkouts…", rows: checkoutRows())
    }
    private func checkoutRows() -> [ComposerChoice] {
        guard let workspace = currentWorkspace else { return [] }
        let local = currentProject?.location ?? workspace.selectedLocation
        let locationDraft = workspace.locationDraft
        let isNew = locationDraft?.mode == .worktree
        var rows = [ComposerChoice("Local", detail: "Use the project's current files and branch.", symbol: "folder", selected: !isNew && local.path == workspace.selectedLocation.path) { [weak self] in
            self?.locationOptions.onCheckout?(local)
        }]
        if let snapshot = repositorySnapshot {
            rows += snapshot.checkouts.filter { $0.path != local.scopePath }.map { checkout in
                ComposerChoice(checkout.branch ?? URL(fileURLWithPath: checkout.path).lastPathComponent,
                               detail: checkout.branch == nil ? "Detached HEAD · " + SpookkyStyle.abbreviatedPath(checkout.path) : SpookkyStyle.abbreviatedPath(checkout.path),
                               symbol: "folder", selected: !isNew && checkout.identity == workspace.selectedLocation.checkoutIdentity,
                               action: checkout.available ? { [weak self] in self?.selectCheckout(checkout.path) } : nil)
            }
        } else { rows.append(ComposerChoice("Reading repository…")) }
        return rows
    }
    private func selectCheckout(_ path: String) {
        guard let id = currentWorkspace?.id else { return }
        let project = currentWorkspace?.projectID
        Task { [weak self] in
            do {
                let result = try await GitRepository().discover(URL(fileURLWithPath: path))
                guard let self, currentWorkspace?.id == id, currentWorkspace?.projectID == project, prompt.isEditable else { return }
                locationOptions.onCheckout?(result)
            } catch { self?.onError?("This checkout is unavailable. Choose another location.") }
        }
    }
    private func chooseSource() {
        clearCheckoutAccessory()
        modelChoices.close()
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
        locationPopover.performClose(nil); choices.close()
        updateEffortChoices()
        if !modelChoices.isShown {
            modelChoices.show(from: model, title: tool.displayName + " model, effort and access", search: "Search models…",
                              rows: modelRows(loading: discoveredModels == nil), searchable: (discoveredModels?.models.count ?? 0) > 8,
                              preferredEdge: .minY)
        }
        modelTask?.cancel()
        modelTask = Task { [weak self, modelCatalog] in
            let result = await modelCatalog.models(for: tool, directory: directory, refresh: refresh)
            guard !Task.isCancelled, let self,
                  currentTool == tool, currentWorkspace?.directory == directory else { return }
            discoveredModels = result; configureFooter()
            if modelChoices.isShown { updateModelChoices() }
        }
    }
    private func modelRows(loading: Bool = false) -> [ComposerChoice] {
        var rows = [ComposerChoice("Default model", detail: "Use your CLI configuration", selected: selection.model == nil, alwaysVisible: true, closesPopover: false) { [weak self] in self?.onModel?(AgentModelSelection()) }]
        for value in discoveredModels?.models ?? [] {
            let allowed = images.isEmpty || value.acceptsImages
            rows.append(ComposerChoice(value.name, detail: allowed ? nil : "Does not accept images", selected: selection.model == value.id,
                closesPopover: false, action: allowed ? { [weak self] in self?.selectModel(value) } : nil))
        }
        rows.append(ComposerChoice("Custom model…", alwaysVisible: true) { [weak self] in self?.customModel() })
        if loading { rows.append(ComposerChoice("Loading models…", alwaysVisible: true)) }
        if let issue = discoveredModels?.issue { rows.append(ComposerChoice("Model discovery unavailable", detail: issue, alwaysVisible: true)) }
        rows.append(ComposerChoice("Refresh models", symbol: "arrow.clockwise", alwaysVisible: true, closesPopover: false) { [weak self] in self?.chooseModel(refresh: true) })
        return rows
    }
    private func selectModel(_ value: ProviderModel) {
        let efforts = currentTool == .codex ? value.efforts : discoveredModels?.efforts ?? []
        let recalled = selection.model == value.id ? selection : onRecallModel?(value.id)
        let effort = recalled?.effort.flatMap { efforts.contains($0) ? $0 : nil }
        onModel?(AgentModelSelection(model: value.id, effort: effort, displayName: value.name))
    }
    private func updateModelChoices() {
        updateEffortChoices()
        modelChoices.setSearchable((discoveredModels?.models.count ?? 0) > 8)
        modelChoices.update(modelRows())
    }
    private func updateEffortChoices() {
        let efforts = currentTool == .codex ? discoveredModels?.models.first { $0.id == selection.model }?.efforts ?? [] : discoveredModels?.efforts ?? []
        modelMenu.update(tool: currentTool, selection: selection, efforts: efforts, fullAccess: fullAccess)
    }
    @objc private func toggleWorktree() {
        guard newWorktree.isEnabled, let workspace = currentWorkspace else { return }
        modelChoices.close()
        var draft = workspace.locationDraft ?? LocationDraft()
        draft.mode = newWorktree.state == .on ? .worktree : .local
        if workspace.locationDraft == nil { draft.source = currentProject?.preferredSource ?? repositorySnapshot?.defaultSource ?? "HEAD" }
        locationOptions.onDraft?(draft)
    }
    private func customModel() {
        defer { chooseModel() }
        let field = NSTextField(string: selection.model ?? "")
        field.placeholderString = "Model name or ID"; field.setAccessibilityLabel("Model name or ID")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        let alert = NSAlert(); alert.messageText = "Choose a custom model"
        alert.informativeText = "Enter a model supported by " + (currentTool?.displayName ?? "your provider") + "."
        alert.accessoryView = field; alert.addButton(withTitle: "Use model"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var next = AgentModelSelection(model: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard next.isValid else { onError?("Enter a model name without control characters, up to 256 bytes."); return }
        if let id = next.model, currentTool == .claude, let recalled = onRecallModel?(id),
           let effort = recalled.effort, discoveredModels?.efforts.contains(effort) == true { next.effort = effort }
        onModel?(next)
    }
    private func chooseTool() {
        choices.close(); modelChoices.close(); locationPopover.performClose(nil)
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
        !locationPopover.isShown && !choices.isShown && !modelChoices.isShown &&
            ([prompt, launch, picker, model, attach, folder, location, source, newWorktree, options] as [NSView]).contains { window?.firstResponder === $0 }
    }
    func submit() {
        guard hasInputFocus, !prompt.hasMarkedText(), launch.isEnabled else { return }
        launch.performClick(nil)
    }
    var isImportingImage: Bool { importingImage }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { locationPopover.performClose(nil); choices.close(); modelChoices.close(); modelTask?.cancel() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func layout() { super.layout(); configureFooter(); resizePrompt() }
    private func resizePrompt() {
        guard let manager = prompt.layoutManager, let container = prompt.textContainer, promptScroll.contentSize.width > 0 else { return }
        manager.ensureLayout(for: container)
        let content = manager.usedRect(for: container).height + prompt.textContainerInset.height * 2
        let height = max(SpookkyStyle.points(64), min(content, SpookkyStyle.points(300), max(SpookkyStyle.points(64), bounds.height / 2)))
        if abs(promptHeight.constant - height) > 0.5 { promptHeight.constant = height }
    }
    func textDidChange(_ notification: Notification) { resizePrompt(); onDraft?(nil, prompt.string); refreshSuggestions() }
    func textViewDidChangeSelection(_ notification: Notification) { refreshSuggestions() }
    func textDidBeginEditing(_ notification: Notification) { onFocus?() }

    private func loadSkillsIfNeeded(tool: SessionTool, directory: String) {
        let key = tool.rawValue + "\0" + directory
        guard key != skillLocation else { return }
        skillLocation = key
        skills = []; hideSuggestions()
        guard tool != .shell else { return }
        Task.detached(priority: .utility) { [weak self] in
            let loaded = SkillSuggestions.load(tool: tool, directory: directory)
            await self?.acceptSkills(loaded, for: key)
        }
    }

    private func acceptSkills(_ loaded: [SkillSuggestion], for key: String) {
        guard skillLocation == key else { return }
        skills = loaded
        refreshSuggestions()
    }

    private func refreshSuggestions() {
        guard currentTool != .shell, !skills.isEmpty,
              let token = SkillCompletionToken.atCaret(in: prompt.string, selection: prompt.selectedRange()) else {
            hideSuggestions(); return
        }
        let next = SkillSuggestions.matches(skills, query: token.query)
        guard !next.isEmpty else { hideSuggestions(); return }
        completionToken = token
        selectedSuggestion = min(selectedSuggestion, next.count - 1)
        guard next != matches else { suggestions.isHidden = false; return }
        matches = next
        for view in suggestions.arrangedSubviews { suggestions.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, skill) in next.enumerated() {
            let prefix = currentTool == .codex ? "$" : "/"
            let detail = skill.description.isEmpty ? skill.source : skill.description
            let button = ActionButton(prefix + skill.name + "  ·  " + detail, action: { [weak self] in self?.insertSuggestion(index) })
            button.selected = index == selectedSuggestion
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            button.setAccessibilityLabel(prefix + skill.name + ", skill, " + detail)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            suggestions.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: suggestions.widthAnchor, constant: -SpookkyStyle.points(12))
                .displayScaled(alreadyScaled: true).isActive = true
        }
        suggestions.isHidden = false
    }

    private func hideSuggestions() {
        completionToken = nil; matches = []; selectedSuggestion = 0
        suggestions.isHidden = true
    }

    private func updateSuggestionSelection() {
        for (index, button) in suggestions.arrangedSubviews.compactMap({ $0 as? ActionButton }).enumerated() {
            button.selected = index == selectedSuggestion
        }
    }

    private func handleCompletionKey(_ event: NSEvent) -> Bool {
        guard !suggestions.isHidden, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 125: selectedSuggestion = (selectedSuggestion + 1) % matches.count; updateSuggestionSelection(); return true
        case 126: selectedSuggestion = (selectedSuggestion + matches.count - 1) % matches.count; updateSuggestionSelection(); return true
        case 36, 76: insertSuggestion(selectedSuggestion); return true
        case 53: hideSuggestions(); return true
        default: return false
        }
    }

    private func insertSuggestion(_ index: Int) {
        guard matches.indices.contains(index), let token = completionToken else { return }
        let prefix = currentTool == .codex ? "$" : "/"
        let replacement = prefix + matches[index].name
        window?.makeFirstResponder(prompt)
        prompt.insertText(replacement, replacementRange: token.range)
        prompt.setSelectedRange(NSRange(location: token.range.location + (replacement as NSString).length, length: 0))
        hideSuggestions()
    }
}
