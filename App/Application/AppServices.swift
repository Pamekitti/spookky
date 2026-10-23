import AppKit
import Sparkle
import SpookkyCore

@MainActor enum InstallationLocation {
    static var canRun: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
        return (path.hasPrefix("/Applications/") || path.hasPrefix(userApps)) && FileManager.default.isWritableFile(atPath: path)
    }

    static func showGuidance() {
        let alert = ChromeAlert()
        alert.messageText = "Move Spookky to Applications"
        alert.informativeText = "Drag Spookky into Applications, then open it there. This lets Spookky save your work and install updates."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    }
}

@MainActor final class AppServices: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private var settings: NSWindow?
    private var updateChecks: NSButton?
    private var updateDownloads: NSButton?
    private var previewUpdates: NSButton?
    private var licenses: NSWindow?
    private var pendingInstall: (() -> Void)?
    private var pendingInstallID: UUID?
    private var preparing = false
    private(set) var installingUpdate = false
    var prepareForUpdate: (() async throws -> Void)?
    var displayPreferences = DisplayPreferences()
    var displayPreferencesDidChange: ((DisplayPreferences) -> Void)?
    var terminalAppearanceMessage = "Following Ghostty appearance" { didSet { appearanceStatus?.stringValue = terminalAppearanceMessage } }
    private weak var appearanceStatus: NSTextField?
    var persistsDisplayPreferences = true
    private var displaySave: Task<Void, Never>?
    func changeDisplay(_ edit: (inout DisplayPreferences) -> Void) {
        let old = displayPreferences
        edit(&displayPreferences); displayPreferences.normalize()
        guard old != displayPreferences else { return }
        displayPreferencesDidChange?(displayPreferences)
        guard persistsDisplayPreferences else { return }
        displaySave?.cancel()
        displaySave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            if let data = try? JSONEncoder().encode(displayPreferences) { UserDefaults.standard.set(data, forKey: "displayPreferences") }
        }
    }
    func flushDisplayPreferences() {
        guard persistsDisplayPreferences else { return }
        displaySave?.cancel(); displaySave = nil
        if let data = try? JSONEncoder().encode(displayPreferences) { UserDefaults.standard.set(data, forKey: "displayPreferences") }
    }
    var agentPreferences = AgentNotificationPreferences()
    var activityPreferencesDidChange: ((AgentNotificationPreferences) -> Void)?
    var testAgentNotification: (() async -> String)?
    private var activityChecks: [ObjectIdentifier: (Bool) -> Void] = [:]

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "agentNotifications"), let saved = try? JSONDecoder().decode(AgentNotificationPreferences.self, from: data) { agentPreferences = saved }
        if let data = UserDefaults.standard.data(forKey: "displayPreferences"), let saved = try? JSONDecoder().decode(DisplayPreferences.self, from: data) {
            displayPreferences = saved; displayPreferences.normalize()
        }
        let preview = Bundle.main.object(forInfoDictionaryKey: "SpookkyReleaseChannel") as? String == "preview"
        UserDefaults.standard.register(defaults: ["receivePreviewUpdates": preview])
        if Bundle.main.bundleIdentifier == "dev.spookky.app",
           let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        }
    }

    func populate(_ menu: NSMenu) {
        let about = menu.addItem(withTitle: "About Spookky", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        let notices = menu.addItem(withTitle: "Licenses…", action: #selector(showLicenses), keyEquivalent: "")
        notices.target = self
        menu.addItem(.separator())
        let preferences = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        let updates = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(.separator())
    }

    @objc(allowedSystemProfileKeysForUpdater:)
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    @objc(allowedChannelsForUpdater:)
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: "receivePreviewUpdates") ? ["preview"] : []
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { installingUpdate = true }

    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        pendingInstall = installHandler
        pendingInstallID = UUID()
        resumeInstallation()
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installingUpdate = true
        return false
    }

    @objc(updater:didAbortWithError:)
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        pendingInstall = nil
        pendingInstallID = nil
        installingUpdate = false
    }

    private func resumeInstallation() {
        guard !preparing, let install = pendingInstall, let installID = pendingInstallID else { return }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                guard let prepareForUpdate else { throw LaunchError.invalid("Workspaces are still opening. Try the update again shortly.") }
                try await prepareForUpdate()
                guard pendingInstallID == installID else { return }
                installingUpdate = true
                pendingInstall = nil
                pendingInstallID = nil
                install()
            } catch {
                guard pendingInstallID == installID else { return }
                let alert = ChromeAlert()
                alert.messageText = "The update is waiting"
                alert.informativeText = error.localizedDescription + "\nYour sessions will keep running when Spookky restarts."
                alert.addButton(withTitle: "Later")
                alert.addButton(withTitle: "Retry")
                let result = alert.runModal()
                if result == .alertSecondButtonReturn { Task { self.resumeInstallation() } }
            }
        }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        if pendingInstall != nil { resumeInstallation() }
        else if let controller { controller.checkForUpdates(sender) }
        else {
            let alert = ChromeAlert()
            alert.messageText = "Updates are unavailable in this build"
            alert.informativeText = "Install a signed public release to receive updates."
            alert.runModal()
        }
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Spookky",
            .credits: NSAttributedString(string: "A native Mac workspace for terminals and coding agents.\nMIT license · Built on Ghostty.\nhttps://pamekitti.github.io/spookky/")
        ])
    }

    @objc private func showSettings() {
        if let settings { refreshSettings(); settings.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Spookky Settings"; window.isReleasedWhenClosed = false
        let checks = ChromeButton(checkboxWithTitle: "Check for updates automatically", target: self, action: #selector(changeChecks(_:)))
        checks.state = controller?.updater.automaticallyChecksForUpdates == true ? .on : .off
        checks.isEnabled = controller != nil
        let downloads = ChromeButton(checkboxWithTitle: "Download updates automatically", target: self, action: #selector(changeDownloads(_:)))
        downloads.state = controller?.updater.automaticallyDownloadsUpdates == true ? .on : .off
        downloads.isEnabled = controller != nil
        let previews = ChromeButton(checkboxWithTitle: "Include Preview releases", target: self, action: #selector(changePreviews(_:)))
        previews.state = UserDefaults.standard.bool(forKey: "receivePreviewUpdates") ? .on : .off
        previews.isEnabled = controller != nil
        updateChecks = checks; updateDownloads = downloads; previewUpdates = previews
        let detail = ChromeTextField(wrappingLabelWithString: controller == nil ? "Update settings are available in signed public releases." : "Updates check once a day while Spookky runs. Restarting keeps your terminal sessions running.")
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [checks, downloads, previews, detail, displaySettings(), activitySettings()]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = SpookkyStyle.points(12)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(scroll)
        let document = SettingsDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document; stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: window.contentView!.topAnchor), scroll.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24).displayScaled(),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24).displayScaled(),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24).displayScaled(),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24).displayScaled()
        ])
        DisplayMetrics.registerRoot(window.contentView!)
        settings = window; window.center(); window.makeKeyAndOrderFront(nil)
    }
    private func displaySettings() -> NSView {
        let label = ChromeTextField(wrappingLabelWithString: terminalAppearanceMessage)
        label.font = .systemFont(ofSize: SpookkyStyle.points(11)); appearanceStatus = label
        let size = ChromePopUpButton()
        for value in -8...20 { size.addItem(withTitle: "\(value > 0 ? "+" : "")\(value) pt") }
        size.selectItem(at: Int(displayPreferences.terminalFontAdjustment) + 8)
        size.target = self; size.action = #selector(changeTerminalSize(_:)); size.setAccessibilityLabel("Terminal font adjustment")
        let reset = ActionButton("Reset interface size") { [weak self] in self?.changeDisplay { $0.zoom = 1 } }
        let row = NSStackView(views: [SpookkyStyle.label( "Terminal font adjustment"), size, reset])
        row.orientation = .vertical; row.alignment = .leading
        let stack = NSStackView(views: [label, row]); stack.orientation = .vertical; stack.alignment = .leading
        return stack
    }
    @objc private func changeTerminalSize(_ sender: NSPopUpButton) {
        changeDisplay { $0.terminalFontAdjustment = Double(sender.indexOfSelectedItem - 8) }
    }
    private func activitySettings() -> NSView {
        activityChecks.removeAll()
        func check(_ title: String, _ key: WritableKeyPath<AgentNotificationPreferences, Bool>) -> NSButton {
            let button = ChromeButton(checkboxWithTitle: title, target: self, action: #selector(changeActivity(_:)))
            button.state = agentPreferences[keyPath: key] ? .on : .off
            activityChecks[ObjectIdentifier(button)] = { [weak self] value in self?.agentPreferences[keyPath: key] = value }
            return button
        }
        let title = SpookkyStyle.label( "Activity and notifications"); title.font = .systemFont(ofSize: SpookkyStyle.points(13), weight: .medium)
        let providers = NSStackView(views: [check("Codex", \.codex), check("Claude Code", \.claude)]); providers.spacing = SpookkyStyle.points(20)
        let grid = NSGridView(views: [
            [SpookkyStyle.label( "Notify me"), SpookkyStyle.label( "Banner"), SpookkyStyle.label( "App sound")],
            [SpookkyStyle.label( "Needs input"), check("", \.inputBanner), check("", \.inputSound)],
            [SpookkyStyle.label( "Turn finished"), check("", \.finishedBanner), check("", \.finishedSound)],
            [SpookkyStyle.label( "Failed"), check("", \.failedBanner), check("", \.failedSound)]
        ])
        grid.columnSpacing = 22; grid.rowSpacing = 8
        for row in 1...3 {
            for column in 1...2 {
                grid.cell(atColumnIndex: column, rowIndex: row).contentView?.setAccessibilityLabel(["Needs input", "Turn finished", "Failed"][row - 1] + (column == 1 ? " banner" : " app sound"))
            }
        }
        let sounds = ChromePopUpButton(); sounds.addItems(withTitles: ["Glass", "Tink", "Ping", "Pop", "Submarine"])
        sounds.selectItem(withTitle: agentPreferences.sound); sounds.target = self; sounds.action = #selector(changeActivitySound(_:)); sounds.setAccessibilityLabel("Notification sound")
        let volume = NSSlider(value: Double(agentPreferences.volume), minValue: 0, maxValue: 1, target: self, action: #selector(changeActivityVolume(_:)))
        SpookkyStyle.suppressFocusRing(volume)
        volume.setAccessibilityLabel("Notification volume"); volume.widthAnchor.constraint(equalToConstant: 150).displayScaled().isActive = true
        let soundRow = NSStackView(views: [sounds, volume]); soundRow.spacing = SpookkyStyle.points(12)
        let note = ChromeTextField(wrappingLabelWithString: "Monitoring begins on the next agent launch. Codex keeps its normal hook trust review. Existing CLI sound hooks stay active.")
        note.font = .systemFont(ofSize: SpookkyStyle.points(11)); note.textColor = .secondaryLabelColor
        let testResult = ChromeTextField(wrappingLabelWithString: ""); testResult.font = .systemFont(ofSize: SpookkyStyle.points(11)); testResult.textColor = .secondaryLabelColor
        let test = ActionButton("Test notification") { [weak self, weak testResult] in
            Task { testResult?.stringValue = await self?.testAgentNotification?() ?? "Notifications are unavailable." }
        }
        let stack = NSStackView(views: [title, providers, grid, soundRow,
            check("Show message previews", \.previews), check("Show Dock attention count", \.dockBadge),
            check("Stay quiet while viewing the terminal", \.suppressVisible), note, test, testResult])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = SpookkyStyle.points(10)
        note.widthAnchor.constraint(equalToConstant: 392).displayScaled().isActive = true
        return stack
    }
    private func saveActivityPreferences() {
        if let data = try? JSONEncoder().encode(agentPreferences) { UserDefaults.standard.set(data, forKey: "agentNotifications") }
        activityPreferencesDidChange?(agentPreferences)
    }
    @objc private func changeActivity(_ sender: NSButton) { activityChecks[ObjectIdentifier(sender)]?(sender.state == .on); saveActivityPreferences() }
    @objc private func changeActivitySound(_ sender: NSPopUpButton) { agentPreferences.sound = sender.titleOfSelectedItem ?? "Glass"; saveActivityPreferences() }
    @objc private func changeActivityVolume(_ sender: NSSlider) { agentPreferences.volume = sender.floatValue; saveActivityPreferences() }
    private func refreshSettings() {
        updateChecks?.state = controller?.updater.automaticallyChecksForUpdates == true ? .on : .off
        updateDownloads?.state = controller?.updater.automaticallyDownloadsUpdates == true ? .on : .off
        previewUpdates?.state = UserDefaults.standard.bool(forKey: "receivePreviewUpdates") ? .on : .off
    }
    @objc private func changeChecks(_ sender: NSButton) { controller?.updater.automaticallyChecksForUpdates = sender.state == .on }
    @objc private func changeDownloads(_ sender: NSButton) { controller?.updater.automaticallyDownloadsUpdates = sender.state == .on }
    @objc private func changePreviews(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "receivePreviewUpdates")
        controller?.updater.resetUpdateCycle()
    }

    @objc private func showLicenses() {
        if let licenses { licenses.makeKeyAndOrderFront(nil); return }
        let directory = Bundle.main.resourceURL!.appendingPathComponent("licenses")
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let text = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url -> String? in
            guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return url.lastPathComponent + "\n\n" + value
        }.joined(separator: "\n\n________________________________\n\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Spookky Licenses"; window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        let view = NSTextView(frame: scroll.bounds); view.isEditable = false; view.string = text; view.font = .systemFont(ofSize: SpookkyStyle.points(12))
        view.textContainerInset = NSSize(width: 20, height: 20); view.autoresizingMask = [.width]; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true; scroll.documentView = view; window.contentView!.addSubview(scroll)
        DisplayMetrics.registerRoot(window.contentView!); licenses = window; window.center(); window.makeKeyAndOrderFront(nil)
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
