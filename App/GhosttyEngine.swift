import AppKit
import GhosttyKit
import SpookkyCore

final class GhosttyEngine {
    private(set) var app: ghostty_app_t!
    private var config: ghostty_config_t!
    private let wakeLock = NSLock()
    private var wakePending = false
    private var keyboardObserver: NSObjectProtocol?
    var keyboardTrace: FixtureInputTrace?
    private let themeRoot: URL
    private var themeGeneration = 0
    let clipboard: NSPasteboard

    init(root: URL, clipboard: NSPasteboard = .general) throws {
        self.clipboard = clipboard
        themeRoot = root
        let resources = Bundle.main.resourceURL!.appendingPathComponent("ghostty").path
        setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
        setenv("TERMINFO_DIRS", Bundle.main.resourceURL!.appendingPathComponent("terminfo").path + ":/usr/share/terminfo", 1)
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            throw LaunchError.invalid("Ghostty initialization failed.")
        }
        let configURL = root.appendingPathComponent("terminal.conf")
        try Self.runtimeConfiguration.write(to: configURL, atomically: true, encoding: .utf8)
        config = ghostty_config_new()
        configURL.path.withCString { ghostty_config_load_file(config, $0) }
        ghostty_config_finalize(config)
        guard ghostty_config_diagnostics_count(config) == 0 else {
            throw LaunchError.invalid("Terminal configuration failed validation.")
        }
        var callbacks = ghostty_runtime_config_s()
        callbacks.userdata = Unmanaged.passUnretained(self).toOpaque()
        callbacks.supports_selection_clipboard = false
        callbacks.wakeup_cb = { pointer in
            guard let pointer else { return }
            let engine = Unmanaged<GhosttyEngine>.fromOpaque(pointer).takeUnretainedValue()
            engine.scheduleTick()
        }
        callbacks.action_cb = { _, target, action in
            guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
                  let userdata = ghostty_surface_userdata(surface) else { return false }
            let view = Unmanaged<TerminalHostView>.fromOpaque(userdata).takeUnretainedValue()
            switch action.tag {
            case GHOSTTY_ACTION_SET_TITLE:
                if view.onTitle != nil, let title = action.action.set_title.title {
                    let text = String(cString: title)
                    DispatchQueue.main.async { [weak view] in view?.onTitle?(text) }
                }
                return true
            case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
                DispatchQueue.main.async { [weak view] in view?.onExit?(false) }
                return true
            case GHOSTTY_ACTION_OPEN_URL:
                if let pointer = action.action.open_url.url,
                   let url = URL(string: String(cString: pointer)), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
                    DispatchQueue.main.async { [weak view] in
                        guard let view else { return }
                        if view.onOpenURL?(url) != true { NSWorkspace.shared.open(url) }
                    }
                }
                return true
            default: return false
            }
        }
        callbacks.read_clipboard_cb = { pointer, _, state in
            guard let pointer else { return false }
            let view = Unmanaged<TerminalHostView>.fromOpaque(pointer).takeUnretainedValue()
            guard let surface = view.surface else { return false }
            guard let text = view.engine.clipboard.string(forType: .string) else { return false }
            text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
            return true
        }
        callbacks.confirm_read_clipboard_cb = { pointer, text, state, _ in
            guard let pointer, let text else { return }
            let view = Unmanaged<TerminalHostView>.fromOpaque(pointer).takeUnretainedValue()
            guard let surface = view.surface else { return }
            let alert = ChromeAlert()
            alert.messageText = "Allow terminal clipboard access?"
            alert.informativeText = "The terminal requested a clipboard operation."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                ghostty_surface_complete_clipboard_request(surface, text, state, true)
            } else {
                "".withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
            }
        }
        callbacks.write_clipboard_cb = { pointer, _, contents, count, confirmation in
            guard let pointer, let contents else { return }
            let clipboard = Unmanaged<TerminalHostView>.fromOpaque(pointer).takeUnretainedValue().engine.clipboard
            if confirmation {
                let alert = ChromeAlert()
                alert.messageText = "Allow terminal to write the clipboard?"
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            for index in 0..<count {
                if let mime = contents[index].mime, String(cString: mime) == "text/plain", let text = contents[index].data {
                    clipboard.clearContents()
                    clipboard.setString(String(cString: text), forType: .string)
                    break
                }
            }
        }
        callbacks.close_surface_cb = { pointer, alive in
            guard let pointer else { return }
            let view = Unmanaged<TerminalHostView>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { [weak view] in view?.onExit?(alive) }
        }
        guard let created = ghostty_app_new(&callbacks, config) else { throw LaunchError.invalid("Ghostty app creation failed.") }
        app = created
        ghostty_app_set_focus(app, NSApp.isActive)
        ghostty_app_set_color_scheme(app, GHOSTTY_COLOR_SCHEME_DARK)
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_keyboard_changed(app)
            self?.keyboardTrace?.record("keyboard_source_notification", fields: ["source_id": TerminalHostView.keyboardSourceID ?? "unknown"])
        }
    }

    private func scheduleTick() {
        wakeLock.lock()
        if wakePending { wakeLock.unlock(); return }
        wakePending = true
        wakeLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            wakeLock.lock()
            wakePending = false
            wakeLock.unlock()
            if let app { ghostty_app_tick(app) }
        }
    }
    private static let runtimeConfiguration = """
    macos-option-as-alt = true
    confirm-close-surface = false
    scrollback-limit = 10485760
    """
    @MainActor func setTheme(dark: Bool, views: [TerminalHostView]) async throws {
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        for view in views { if let surface = view.surface { ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT) } }
    }
    @MainActor func applyAppearance(_ candidate: GhosttyAppearance, preferences: DisplayPreferences, views: @MainActor () -> [TerminalHostView]) async throws {
        themeGeneration += 1; let generation = themeGeneration
        let url = themeRoot.appendingPathComponent("appearance-\(generation).conf")
        let content = candidate.configuration(preferences: preferences) + Self.runtimeConfiguration
        let prepared = try await Task.detached(priority: .utility) {
            try content.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let result = PreparedGhosttyConfiguration()
            url.path.withCString { ghostty_config_load_file(result.value, $0) }
            ghostty_config_finalize(result.value)
            guard ghostty_config_diagnostics_count(result.value) == 0 else {
                throw LaunchError.invalid("This Ghostty appearance is not supported by Spookky's terminal renderer. The last valid appearance is retained.")
            }
            return result
        }.value
        guard generation == themeGeneration else { return }
        ghostty_app_update_config(app, prepared.value)
        for view in views() { view.updateConfiguration(prepared.value) }
        ghostty_config_free(config); config = ghostty_config_clone(prepared.value)
    }

    deinit {
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver) }
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }
}

private final class PreparedGhosttyConfiguration: @unchecked Sendable {
    let value = ghostty_config_new()!
    deinit { ghostty_config_free(value) }
}
