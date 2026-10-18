import AppKit
import GhosttyKit
import SpookkyCore
import SpookkyRuntime

@MainActor enum WorkspaceCloseFixture {
    static func run(window: NSWindow, state: () -> WorkspaceState, runtime: any SessionRuntime,
                    view: (UUID) -> TerminalHostView?, command: (NSEvent) -> Bool, reopen: () -> Void,
                    openTerminal: () -> Void, supportingView: () -> NSView?, selectWorkspace: (UUID) -> Void,
                    openSupportingTerminal: () -> Void, reopenSupportingTerminal: (UUID) -> Void,
                    prepareStop: () -> Void, stop: () -> Void, setAppearance: (WorkspaceAppearance) -> Void,
                    support: (UUID?, SupportingLayout?) -> Void, host: SupportingContentFixtureHost,
                    settled: () -> Bool, root: URL) async throws {
        var checks: [String: Bool] = [:]
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<250 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
            throw LaunchError.invalid(message)
        }
        func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { throw LaunchError.invalid("Fixture key unavailable") }
            return event
        }
        func send(_ text: String, code: UInt16) async throws {
            try await wait("Pending operation did not settle") { settled() }
            guard command(try key(text, code: code)) else { throw LaunchError.invalid("Shortcut not handled") }
        }
        func capture(_ name: String, width: CGFloat, height: CGFloat, appearance: NSAppearance.Name) async throws {
            setAppearance(appearance == .darkAqua ? .dark : .light)
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: width, height: height)); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw LaunchError.invalid("Capture unavailable") }
            content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
            guard let pixels = bitmap.cgImage,
                  let context = CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw LaunchError.invalid("Opaque capture unavailable") }
            let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                context.setFillColor((window.backgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor).cgColor)
            }
            context.fill(bounds); context.draw(pixels, in: bounds)
            guard let composed = context.makeImage(), let data = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]) else { throw LaunchError.invalid("PNG unavailable") }
            try data.write(to: root.appendingPathComponent(name + ".png"))
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait("Fixture did not activate") { NSApp.isActive && window.isKeyWindow }
        let initial = state(), landingID = initial.selectedWorkspaceID!, landingTerminal = initial.primaryTerminalID!
        checks["blank_home_draft"] = initial.selected?.isLanding == true && initial.selected?.anchor == nil && initial.selectedTab?.isEditable == true
        openTerminal()
        try await wait("Immediate shell failed") { state().selectedTab?.status == .running && state().selectedTab.flatMap { view($0.id) } != nil }
        let workspaceID = state().selectedWorkspaceID!, primaryID = state().primaryTerminalID!
        checks["shell_from_landing_preserves_draft"] = workspaceID != landingID && state().tab(landingTerminal)?.draft == initial.tab(landingTerminal)?.draft && state().tab(landingTerminal)?.binding == nil
        guard let binding = state().tab(primaryID)?.binding, let terminal = view(primaryID) else { throw LaunchError.invalid("Shell unavailable") }
        let before = try await runtime.inspect(binding)
        try await wait("Shell prompt unavailable") { terminal.visibleText().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%") }
        checks["primary_terminal_focus"] = window.firstResponder === terminal
        terminal.insertText("printf 'SPOOKKY_FOUNDATION_INPUT\\n'", replacementRange: NSRange(location: NSNotFound, length: 0))
        terminal.keyDown(with: try key("\r", code: 36, modifiers: []))
        try await wait("Shell did not accept input") { terminal.visibleText().split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "SPOOKKY_FOUNDATION_INPUT" } }
        checks["native_terminal_input"] = true
        terminal.insertText("SPOOKKY_FOUNDATION_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await send("t", code: 17)
        try await wait("Browser target missing") { state().selected?.support?.tabs.count == 1 }
        let firstBrowser = state().selected!.support!.selectedTabID!
        guard let form = host.fields[firstBrowser] else { throw LaunchError.invalid("Content host not installed") }
        checks["new_browser_focuses_support_content"] = form.currentEditor() != nil
        form.stringValue = "Unsent supporting form"
        form.currentEditor()?.string = "Unsent supporting form"
        window.makeFirstResponder(form)
        checks["cmd_t_browser_without_cli"] = state().selected?.tabs.count == 1 && state().primaryTerminalID == primaryID && state().selected?.support?.selected?.target == .browser(url: "about:blank")
        try await send("t", code: 17)
        guard command(try key("]", code: 30, modifiers: [.command, .shift])) else { throw LaunchError.invalid("Supporting tab shortcut unhandled") }
        checks["support_tab_shortcut_cycles_targets"] = state().selected?.support?.selectedTabID == firstBrowser
        support(firstBrowser, nil)
        checks["support_host_retains_form_on_switch"] = host.fields[firstBrowser] === form && form.stringValue == "Unsent supporting form"
        try await send("l", code: 37); try await send("l", code: 37)
        checks["panel_toggle_restores_selected_form"] = state().selected?.support?.selectedTabID == firstBrowser && host.fields[firstBrowser] === form && form.stringValue == "Unsent supporting form"
        support(nil, .collapsed); support(firstBrowser, .fullWidth)
        window.contentView?.layoutSubtreeIfNeeded()
        checks["full_width_and_collapse_preserve_form"] = state().selected?.support?.layout == .fullWidth && host.fields[firstBrowser] === form && form.stringValue == "Unsent supporting form"
        support(firstBrowser, .split)
        checks["two_browser_targets_distinct"] = state().selected?.support?.tabs.count == 2 && Set(state().selected!.support!.tabs.map(\.id)).count == 2
        try await capture("foundation-dark-wide", width: 1120, height: 760, appearance: .darkAqua)
        try await capture("foundation-light-narrow", width: 680, height: 480, appearance: .aqua)
        window.makeFirstResponder(form)
        checks["support_form_field_focused"] = form.currentEditor() != nil

        try await send("w", code: 13)
        try await wait("Supporting close failed") { state().selected?.support?.tabs.count == 1 }
        let afterSupport = try await runtime.inspect(binding)
        checks["support_close_keeps_primary_process"] = afterSupport?.processID == before?.processID && state().primaryTerminalID == primaryID
        checks["support_close_keeps_unsent_input"] = view(primaryID)?.visibleText().contains("SPOOKKY_FOUNDATION_UNSENT") == true
        if let primary = view(primaryID) { window.makeFirstResponder(primary) }
        try await send("w", code: 13)
        try await wait("Primary close did not return to landing") { window.isVisible && state().selectedWorkspaceID == landingID && state().selected?.isLanding == true }
        let afterHide = try await runtime.inspect(binding)
        checks["primary_close_retains_process_and_records"] = afterHide?.processID == before?.processID && state().workspaces.first { $0.id == workspaceID }?.viewClosed == true && state().tab(primaryID)?.binding == binding
        checks["last_view_close_shows_landing"] = state().selected?.isLanding == true && state().selectedTab?.isEditable == true
        try await send("w", code: 13)
        try await wait("Landing Cmd+W did not close the window") { !window.isVisible }
        checks["landing_cmd_w_closes_window"] = state().selectedWorkspaceID == landingID && state().tab(primaryID)?.binding == binding
        selectWorkspace(workspaceID); reopen()
        try await wait("Primary did not reattach") { view(primaryID) != nil && window.isVisible }
        let afterReopen = try await runtime.inspect(binding)
        checks["reopen_same_process_without_prompt"] = afterReopen?.processID == before?.processID && state().tab(primaryID)?.promptDelivery == PromptDelivery.none
        try await wait("Unsent input lost on reopen") { view(primaryID)?.visibleText().contains("SPOOKKY_FOUNDATION_UNSENT") == true }
        checks["reopen_retains_support_and_input"] = state().selected?.support?.tabs.count == 1
        window.performClose(nil)
        try await wait("Window failed to close") { !window.isVisible }
        let afterWindow = try await runtime.inspect(binding)
        checks["window_close_retains_restore_records"] = afterWindow?.processID == before?.processID && state().tab(primaryID)?.binding == binding && state().selectedWorkspaceID == workspaceID
        reopen()
        try await wait("Window did not reopen") { window.isVisible && view(primaryID) != nil }
        openSupportingTerminal()
        try await wait("Supporting shell failed") { state().selectedTab?.id != primaryID && state().selectedTab?.status == .running && state().selectedTab.flatMap { view($0.id) } != nil }
        let supportingID = state().selectedTab!.id
        guard let supportBinding = state().tab(supportingID)?.binding, let supportTerminal = view(supportingID) else { throw LaunchError.invalid("Supporting shell missing") }
        let supportBefore = try await runtime.inspect(supportBinding)
        supportTerminal.insertText("SPOOKKY_SUPPORT_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.makeFirstResponder(supportTerminal)
        try await send("w", code: 13)
        checks["closed_shell_is_discoverable"] = state().selected?.retainedSupportingTerminals.contains { $0.id == supportingID && $0.binding == supportBinding } == true
        reopenSupportingTerminal(supportingID)
        try await wait("Retained shell view did not reconnect") { view(supportingID) != nil && state().selected?.support?.selected?.target == .terminal(tabID: supportingID) }
        let supportAfter = try await runtime.inspect(supportBinding)
        try await wait("Supporting shell input lost") { view(supportingID)?.visibleText().contains("SPOOKKY_SUPPORT_UNSENT") == true }
        checks["reopen_support_shell_reuses_binding_and_input"] = supportAfter?.processID == supportBefore?.processID && state().tab(supportingID)?.binding == supportBinding
        if let terminal = view(supportingID) { window.makeFirstResponder(terminal) }
        try await send("w", code: 13)
        if let primary = view(primaryID) { window.makeFirstResponder(primary) }
        prepareStop(); stop()
        try await wait("Stop confirmation unavailable") { window.attachedSheet != nil }
        func button(_ title: String, in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            for child in view.subviews { if let result = button(title, in: child) { return result } }
            return nil
        }
        guard let cancel = window.attachedSheet?.contentView.flatMap({ button("Cancel", in: $0) }) else { throw LaunchError.invalid("Stop Cancel unavailable") }
        cancel.performClick(nil)
        try await wait("Stop Cancel failed") { window.attachedSheet == nil }
        let afterCancel = try await runtime.inspect(binding)
        checks["stop_cancel_preserves_owned_process"] = afterCancel?.processID == before?.processID && state().tab(primaryID)?.binding == binding
        try await wait("Stop Cancel did not settle") { settled() }
        stop()
        try await wait("Stop confirmation did not return") { window.attachedSheet != nil }
        guard let confirm = window.attachedSheet?.contentView.flatMap({ button("Stop", in: $0) }) else { throw LaunchError.invalid("Stop action unavailable") }
        confirm.performClick(nil)
        try await wait("Explicit Stop failed") { state().tab(primaryID)?.status == .ended && state().tab(primaryID)?.binding == nil }
        let stopped = try await runtime.inspect(binding)
        let supportingAfterStop = try await runtime.inspect(supportBinding)
        let retained = state().workspaces.first { $0.id == workspaceID }
        checks["explicit_stop_ends_only_owned_primary"] = supportingAfterStop?.processID == supportBefore?.processID && stopped == nil && retained?.primaryTerminalID == primaryID && retained?.support?.tabs.count == 1
        try await send("n", code: 45)
        checks["cmd_n_restores_landing_draft"] = state().workspaces.count == 2 && state().selectedWorkspaceID == landingID && state().selected?.isLanding == true && state().selectedTab?.binding == nil
        try state().validate()
        checks["metadata_valid"] = true
        try PrivateFiles.write(checks, to: root.appendingPathComponent("close-checks.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Conversation fixture failed: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", ")) }
    }
}

@MainActor final class SupportingContentFixtureHost: SupportingContentHost {
    var fields: [UUID: NSTextField] = [:]
    func view(for tab: SupportingTab, workspace: Workspace, update: @escaping (SupportingTarget, String?) -> Void) -> NSView? {
        if let field = fields[tab.id] { return field }
        let field = ChromeTextField(string: "")
        field.placeholderString = "Disposable content-host form fixture"
        fields[tab.id] = field
        return field
    }
    func retainTabs(_ ids: Set<UUID>) { fields = fields.filter { ids.contains($0.key) } }
}
