import AppKit
import Carbon
import GhosttyKit
import SpookkyCore

final class TerminalHostView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    let engine: GhosttyEngine
    var onTitle: ((String) -> Void)?
    var onExit: ((Bool) -> Void)?
    var onFocus: (() -> Void)?
    var onOpenURL: ((URL) -> Bool)?
    var onResize: ((@escaping () -> Void, @escaping () -> Void) -> Void)?
    var onViewportInteraction: (() -> Void)?
    var onViewportChanged: (() -> Void)?
    private(set) var terminalViewportAtBottom: Bool?
    private(set) var viewportRevision: UInt64 = 0
    private var scrollbarMetrics: (total: UInt64, offset: UInt64, length: UInt64)?
    func noteViewportChange() { viewportRevision &+= 1 }
    func receiveScrollbar(total: UInt64, offset: UInt64, length: UInt64) {
        if let previous = scrollbarMetrics, previous == (total, offset, length) { return }
        scrollbarMetrics = (total, offset, length)
        noteViewportChange()
        terminalViewportAtBottom = TerminalViewportPosition.atBottom(total: total, offset: offset, length: length)
        onViewportChanged?()
    }
    var applicationCapturesMouse: (() async throws -> Bool)?
    private struct PendingMouseGesture {
        let id = UUID()
        let down: NSEvent
        var drag: NSEvent?
        var up: NSEvent?
    }
    private var pendingMouseGesture: PendingMouseGesture?
    private var mouseQueryInFlight = false
    private var nativeMouseSelection = false
    private var pendingMouseAction: String?
    private var geometryPending = false
    private var windowObservers: [NSObjectProtocol] = []
    private var lastFocused: Bool?
    private var lastVisible: Bool?
    private var lastGeometry: (width: UInt32, height: UInt32, scale: Double)?
    private var marked = NSAttributedString(string: "")
    private var accumulated: [String]?
    private var tracking: NSTrackingArea?
    private var lastPerformKeyEvent: TimeInterval?
    var inputTrace: (any TerminalInputTracing)?

    init(engine: GhosttyEngine, command: String, directory: String, initialSize: NSSize? = nil) throws {
        self.engine = engine
        super.init(frame: NSRect(origin: .zero, size: initialSize ?? NSSize(width: 900, height: 600)))
        var configuration = ghostty_surface_config_new()
        configuration.platform_tag = GHOSTTY_PLATFORM_MACOS
        configuration.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        configuration.userdata = Unmanaged.passUnretained(self).toOpaque()
        configuration.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        configuration.wait_after_command = true
        surface = command.withCString { executable in
            directory.withCString { path in
                configuration.command = executable
                configuration.working_directory = path
                return ghostty_surface_new(engine.app, &configuration)
            }
        }
        guard surface != nil else { throw LaunchError.invalid("Terminal surface creation failed.") }
        ghostty_surface_set_focus(surface, false)
        lastFocused = false
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("CLI terminal")
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("Use init(engine:command:directory:)") }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func releaseSurface() {
        pendingMouseGesture = nil
        pendingMouseAction = nil
        if let surface { ghostty_surface_free(surface); self.surface = nil }
        lastGeometry = nil
        lastFocused = nil; lastVisible = nil
    }
    func updateConfiguration(_ config: ghostty_config_t) {
        guard let surface else { return }
        ghostty_surface_update_config(surface, config)
        if nativeMouseSelection { perform("toggle_mouse_reporting") }
    }
    func updateVisibility() {
        guard let surface else { return }
        let visible = window?.occlusionState.contains(.visible) == true
        guard visible != lastVisible else { return }
        lastVisible = visible; ghostty_surface_set_occlusion(surface, visible)
    }
    func updateFocus() {
        setFocused(NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === self)
    }
    private func setFocused(_ focused: Bool) {
        guard let surface, focused != lastFocused else { return }
        lastFocused = focused; ghostty_surface_set_focus(surface, focused)
    }

    deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        if let surface { ghostty_surface_free(surface) }
    }

    override func layout() {
        super.layout()
        resizeSurface()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeSurface()
    }
    private func resizeSurface(allowCapture: Bool = true) {
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        let width = UInt32(max(1, (bounds.width * scale).rounded())), height = UInt32(max(1, (bounds.height * scale).rounded()))
        if let last = lastGeometry, last.width == width, last.height == height, last.scale == scale { return }
        if allowCapture, lastGeometry != nil, let onResize {
            guard !geometryPending else { return }
            geometryPending = true
            onResize({ [weak self] in self?.resizeSurface(allowCapture: false) }, { [weak self] in
                guard let self else { return }
                self.geometryPending = false; self.resizeSurface()
            })
            return
        }
        lastGeometry = (width, height, Double(scale))
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, width, height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        if let window {
            for (name, object) in [(NSWindow.didChangeOcclusionStateNotification, window as AnyObject),
                (NSWindow.didBecomeKeyNotification, window), (NSWindow.didResignKeyNotification, window),
                (NSApplication.didBecomeActiveNotification, NSApp!), (NSApplication.didResignActiveNotification, NSApp!)] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    self?.updateVisibility(); self?.updateFocus()
                })
            }
        }
        updateVisibility(); updateFocus(); needsLayout = true; resizeSurface()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true; resizeSurface() }
    override func becomeFirstResponder() -> Bool {
        setFocused(NSApp.isActive && window?.isKeyWindow == true)
        onFocus?()
        return true
    }
    override func resignFirstResponder() -> Bool {
        setFocused(false)
        return true
    }

    private func modifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var value: UInt32 = 0
        if flags.contains(.shift) { value |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { value |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { value |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { value |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { value |= GHOSTTY_MODS_CAPS.rawValue }
        for (mask, mod) in [(NX_DEVICERSHIFTKEYMASK, GHOSTTY_MODS_SHIFT_RIGHT),
                            (NX_DEVICERCTLKEYMASK, GHOSTTY_MODS_CTRL_RIGHT),
                            (NX_DEVICERALTKEYMASK, GHOSTTY_MODS_ALT_RIGHT),
                            (NX_DEVICERCMDKEYMASK, GHOSTTY_MODS_SUPER_RIGHT)] {
            if flags.rawValue & UInt(mask) != 0 { value |= mod.rawValue }
        }
        return ghostty_input_mods_e(rawValue: value)
    }

    private func key(_ event: NSEvent, action: ghostty_input_action_e, translation: NSEvent? = nil,
                     text: String? = nil, composing: Bool = false) {
        guard let surface else { return }
        var input = ghostty_input_key_s()
        input.action = action
        input.keycode = UInt32(event.keyCode)
        input.mods = modifiers(event.modifierFlags)
        input.consumed_mods = modifiers((translation ?? event).modifierFlags.subtracting([.control, .command]))
        if event.type == .keyDown || event.type == .keyUp {
            input.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        }
        input.composing = composing
        inputTrace?.record("encoded_key", event: event, text: text, fields: [
            "action": action.rawValue, "mods": input.mods.rawValue,
            "consumed_mods": input.consumed_mods.rawValue, "composing": composing
        ])
        if let text, let first = text.utf8.first, first >= 0x20 {
            text.withCString { input.text = $0; _ = ghostty_surface_key(surface, input) }
        } else {
            _ = ghostty_surface_key(surface, input)
        }
    }

    override func keyDown(with event: NSEvent) {
        flushPendingMouseGesture()
        onViewportInteraction?()
        guard let surface else { interpretKeyEvents([event]); return }
        inputTrace?.record("key_down", event: event, text: event.characters)
        let translated = ghostty_surface_key_translation_mods(surface, modifiers(event.modifierFlags))
        var flags = event.modifierFlags
        for (flag, mod) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT),
                            (.control, GHOSTTY_MODS_CTRL), (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER)] {
            if translated.rawValue & mod.rawValue != 0 { flags.insert(flag) } else { flags.remove(flag) }
        }
        let translation: NSEvent
        if flags == event.modifierFlags {
            translation = event
        } else {
            translation = NSEvent.keyEvent(with: event.type, location: event.locationInWindow,
                modifierFlags: flags, timestamp: event.timestamp, windowNumber: event.windowNumber,
                context: nil, characters: event.characters(byApplyingModifiers: flags) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }
        let previouslyMarked = hasMarkedText()
        let sourceBefore = previouslyMarked ? nil : Self.keyboardSourceID
        accumulated = []
        defer { accumulated = nil }
        lastPerformKeyEvent = nil
        interpretKeyEvents([translation])
        if !previouslyMarked && sourceBefore != Self.keyboardSourceID {
            inputTrace?.record("source_changed", event: event)
            return
        }
        let pieces = accumulated ?? []
        syncMarked()
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        if !pieces.isEmpty {
            for piece in pieces { key(event, action: action, translation: translation, text: piece) }
        } else {
            key(event, action: action, translation: translation,
                text: translation.terminalCharacters, composing: previouslyMarked || hasMarkedText())
        }
    }

    override func keyUp(with event: NSEvent) { key(event, action: GHOSTTY_ACTION_RELEASE) }
    override func flagsChanged(with event: NSEvent) {
        guard !hasMarkedText() else { return }
        let flag: NSEvent.ModifierFlags
        let side: Int32
        switch event.keyCode {
        case 0x39: flag = .capsLock; side = 0
        case 0x38: flag = .shift; side = NX_DEVICELSHIFTKEYMASK
        case 0x3C: flag = .shift; side = NX_DEVICERSHIFTKEYMASK
        case 0x3B: flag = .control; side = NX_DEVICELCTLKEYMASK
        case 0x3E: flag = .control; side = NX_DEVICERCTLKEYMASK
        case 0x3A: flag = .option; side = NX_DEVICELALTKEYMASK
        case 0x3D: flag = .option; side = NX_DEVICERALTKEYMASK
        case 0x37: flag = .command; side = NX_DEVICELCMDKEYMASK
        case 0x36: flag = .command; side = NX_DEVICERCMDKEYMASK
        default: return
        }
        let pressed = event.modifierFlags.contains(flag) && (side == 0 || event.modifierFlags.rawValue & UInt(side) != 0)
        key(event, action: pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": return perform("copy_to_clipboard")
            case "v": return perform("paste_from_clipboard")
            default: break
            }
        }
        if event.charactersIgnoringModifiers == "\r", event.modifierFlags.contains(.control) {
            keyDown(with: event)
            return true
        }
        if event.charactersIgnoringModifiers == "/", event.modifierFlags.contains(.control),
           event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
            let mapped = NSEvent.keyEvent(with: event.type, location: event.locationInWindow,
                modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber,
                context: nil, characters: "_", charactersIgnoringModifiers: "_", isARepeat: event.isARepeat, keyCode: event.keyCode)
            keyDown(with: mapped ?? event)
            return true
        }
        guard event.timestamp != 0, !event.modifierFlags.isDisjoint(with: [.command, .control]) else {
            lastPerformKeyEvent = nil
            return false
        }
        if lastPerformKeyEvent == event.timestamp {
            lastPerformKeyEvent = nil
            keyDown(with: event)
            return true
        }
        lastPerformKeyEvent = event.timestamp
        return false
    }

    @objc func copy(_ sender: Any?) { perform("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { perform("paste_from_clipboard") }
    @discardableResult func perform(_ action: String) -> Bool {
        guard let surface else { return false }
        if pendingMouseGesture != nil, action == "copy_to_clipboard" || action == "paste_from_clipboard" {
            pendingMouseAction = action
            return true
        }
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(next)
        tracking = next
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let position = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, position.x, position.y, modifiers(event.modifierFlags))
    }
    override func mouseDragged(with event: NSEvent) {
        if pendingMouseGesture != nil { pendingMouseGesture?.drag = event }
        else { mouseMoved(with: event) }
    }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    private func mouse(_ event: NSEvent, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e) {
        guard let surface else { return }
        mouseMoved(with: event)
        _ = ghostty_surface_mouse_button(surface, state, button, modifiers(event.modifierFlags))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        flushPendingMouseGesture()
        guard let surface, ghostty_surface_mouse_captured(surface), let applicationCapturesMouse,
              !mouseQueryInFlight else {
            mouse(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
            return
        }
        let gesture = PendingMouseGesture(down: event)
        pendingMouseGesture = gesture
        let id = gesture.id
        mouseQueryInFlight = true
        Task { @MainActor [weak self] in
            let captured = (try? await applicationCapturesMouse()) ?? true
            guard let self else { return }
            self.mouseQueryInFlight = false
            guard self.surface != nil, self.pendingMouseGesture?.id == id else { return }
            if !captured { self.nativeMouseSelection = self.perform("toggle_mouse_reporting") }
            self.flushPendingMouseGesture()
        }
    }
    private func flushPendingMouseGesture() {
        guard let gesture = pendingMouseGesture else { return }
        pendingMouseGesture = nil
        mouse(gesture.down, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
        if let drag = gesture.drag { mouseMoved(with: drag) }
        if let up = gesture.up { finishMouseGesture(up) }
        if let action = pendingMouseAction {
            pendingMouseAction = nil
            perform(action)
        }
    }
    private func finishMouseGesture(_ event: NSEvent) {
        mouse(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        if nativeMouseSelection {
            perform("toggle_mouse_reporting")
            nativeMouseSelection = false
        }
    }
    override func mouseUp(with event: NSEvent) {
        if pendingMouseGesture != nil { pendingMouseGesture?.up = event }
        else { finishMouseGesture(event) }
    }
    override func rightMouseDown(with event: NSEvent) { mouse(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT) }
    override func rightMouseUp(with event: NSEvent) { mouse(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT) }
    override func scrollWheel(with event: NSEvent) {
        onViewportInteraction?()
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas ? 1 : 0)
    }

    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { NSRange(location: marked.length > 0 ? 0 : NSNotFound, length: marked.length) }
    func selectedRange() -> NSRange {
        guard let surface else { return NSRange(location: 0, length: 0) }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange(location: 0, length: 0) }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        return window.convertToScreen(convert(NSRect(x: x, y: y - height, width: width, height: height), to: nil))
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        inputTrace?.record("marked_text", text: marked.string)
        syncMarked()
    }
    func unmarkText() { marked = NSAttributedString(string: ""); syncMarked() }
    private func syncMarked() {
        guard let surface else { return }
        marked.string.withCString { ghostty_surface_preedit(surface, $0, UInt(marked.string.utf8.count)) }
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        inputTrace?.record("committed_text", text: text)
        unmarkText()
        if accumulated != nil { accumulated?.append(text) }
        else if let surface { text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) } }
    }
    override func doCommand(by selector: Selector) {
        if let lastPerformKeyEvent, let current = NSApp.currentEvent, lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    static var keyboardSourceID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return unsafeBitCast(pointer, to: CFString.self) as String
    }

    func visibleText() -> String {
        guard let surface else { return "" }
        var selection = ghostty_selection_s()
        selection.top_left.tag = GHOSTTY_POINT_VIEWPORT
        selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        selection.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
        selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return "" }
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(text.text_len))
        return String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
    }
    override func accessibilityValue() -> Any? { visibleText() }
}

private extension NSEvent {
    var terminalCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }
}
