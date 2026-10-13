import AppKit
import GhosttyKit
import SpookkyCore
import SpookkyRuntime

@MainActor enum WorkspaceCloseFixture {
    static func run(window: NSWindow, state: () -> WorkspaceState, runtime: any SessionRuntime,
                    view: (UUID) -> TerminalHostView?, command: (NSEvent) -> Bool, reopen: () -> Void,
                    settled: () -> Bool, root: URL) async throws {
        var checks: [String: Bool] = [:]
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<150 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw LaunchError.invalid(message)
        }
        func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = .command, in target: NSWindow) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else {
                throw LaunchError.invalid("Close fixture key is unavailable.")
            }
            return event
        }
        func send(_ text: String, code: UInt16) async throws {
            try await wait("Pending tab operation did not settle.") { settled() }
            if window.isVisible { window.makeKeyAndOrderFront(nil) }
            NSApp.activate(ignoringOtherApps: true)
            try await wait("Close fixture lost activation.") { NSApp.isActive }
            guard command(try key(text, code: code, in: window)) else { throw LaunchError.invalid("Close fixture shortcut was not handled.") }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait("Close fixture did not become active.") { NSApp.isActive && window.isKeyWindow }
        let initial = state()
        checks["first_launch_blank_home"] = window.isVisible && initial.workspaces.count == 1 && initial.selected?.anchor == nil &&
            initial.selected?.selectedLocation.path == FileManager.default.homeDirectoryForCurrentUser.path &&
            initial.selectedTab?.isEditable == true && initial.selectedTab?.draft.tool == .shell
        try await send("w", code: 13)
        try await wait("Final blank tab did not close its window.") { !window.isVisible && state().workspaces.isEmpty }
        checks["final_blank_closes_window"] = state().selectedTab == nil
        try await send("t", code: 17)
        try await wait("Cmd+T did not reopen a Home terminal.") {
            window.isVisible && state().selectedTab?.status == .running && state().selectedTab.flatMap { view($0.id) } != nil
        }
        guard let tab = state().selectedTab, let binding = tab.binding, let terminal = view(tab.id) else {
            throw LaunchError.invalid("Close fixture terminal is unavailable.")
        }
        let before = try await runtime.inspect(binding)
        checks["cmd_t_reopens_one_terminal"] = state().workspaces.count == 1 && state().selected?.tabs.count == 1 && binding.tool == .shell
        do { try await wait("Reopened terminal prompt did not appear.") { terminal.visibleText().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%") } }
        catch {
            let observation = try await runtime.inspect(binding)
            let size = terminal.surface.map { ghostty_surface_size($0) }
            var ownerText = "unavailable"
            if let owner = runtime as? TmuxRuntime {
                let executable = await owner.executable, socket = await owner.socket
                ownerText = try await ProcessRunner.asyncRun(executable, ["-S", socket, "capture-pane", "-p", "-J", "-t", "=" + binding.name + ":0.0"], outputLimit: 512).output
            }
            throw LaunchError.invalid("Reopened terminal was not ready. Clients: \(observation?.clients ?? -1), dead: \(observation?.dead ?? true), cells: \(size?.columns ?? 0)x\(size?.rows ?? 0), current text: \(String((view(tab.id)?.visibleText() ?? "missing").prefix(200))), owner text: \(ownerText)")
        }
        terminal.insertText("printf 'SPOOKKY_CLOSE_INPUT\\n'", replacementRange: NSRange(location: NSNotFound, length: 0))
        terminal.keyDown(with: try key("\r", code: 36, modifiers: [], in: window))
        try await wait("Reopened terminal did not accept input.") {
            terminal.visibleText().split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "SPOOKKY_CLOSE_INPUT" }
        }
        checks["native_shell_input"] = true
        try await send("t", code: 17)
        try await wait("Cmd+T did not create a blank tab.") { state().selected?.tabs.count == 2 && state().selectedTab?.isEditable == true }
        checks["cmd_t_running_adds_blank"] = state().selectedTab?.id != tab.id
        try await send("w", code: 13)
        try await wait("Blank-tab close did not restore the original terminal.") { state().selected?.tabs.count == 1 && state().selectedTab?.id == tab.id }
        let afterBlank = try await runtime.inspect(binding)
        checks["close_blank_retains_shell"] = window.isVisible && afterBlank?.processID == before?.processID
        try await send("w", code: 13)
        try await wait("Running-tab close did not show focused confirmation.") { window.attachedSheet?.isKeyWindow == true }
        guard let cancelSheet = window.attachedSheet else { throw LaunchError.invalid("Cancel sheet disappeared.") }
        NSApp.sendEvent(try key("\u{1b}", code: 53, modifiers: [], in: cancelSheet))
        try await wait("Cancel did not finish dismissing the close confirmation.") { window.attachedSheet == nil && settled() }
        let afterCancel = try await runtime.inspect(binding)
        checks["escape_keeps_shell_and_focus"] = window.isVisible && state().selectedTab?.id == tab.id &&
            window.firstResponder === terminal && afterCancel?.processID == before?.processID
        try await send("w", code: 13)
        try await wait("Running-tab close confirmation did not regain focus.") { window.attachedSheet?.isKeyWindow == true }
        guard let closeSheet = window.attachedSheet else { throw LaunchError.invalid("Close sheet disappeared.") }
        NSApp.sendEvent(try key("\r", code: 36, modifiers: [], in: closeSheet))
        do { try await wait("Return did not close the final tab and window.") { !window.isVisible && state().workspaces.isEmpty } }
        catch { throw LaunchError.invalid("Final close did not finish. Visible: \(window.isVisible), workspaces: \(state().workspaces.count), sheet: \(window.attachedSheet != nil)") }
        let afterClose = try await runtime.inspect(binding)
        checks["enter_closes_final_without_replacement"] = state().selectedTab == nil && afterClose == nil
        reopen()
        try await wait("Reopen did not show the Home start screen.") { window.isVisible && state().workspaces.count == 1 && state().selectedTab?.isEditable == true }
        checks["reopen_shows_home_landing"] = state().selected?.anchor == nil && state().selectedTab?.binding == nil
        try await send("w", code: 13)
        try await wait("Reopened landing tab did not close its window.") { !window.isVisible && state().workspaces.isEmpty }
        try await send("n", code: 45)
        try await wait("Cmd+N did not reopen a blank workspace.") { window.isVisible && state().workspaces.count == 1 && state().selectedTab?.isEditable == true }
        checks["cmd_n_reopens_blank"] = state().selectedTab?.binding == nil && state().selected?.anchor == nil
        try await send("w", code: 13)
        try await wait("Final reopened blank tab did not close.") { !window.isVisible && state().workspaces.isEmpty }
        try state().validate()
        checks["empty_state_valid"] = state().selectedWorkspaceID == nil
        try PrivateFiles.write(checks, to: root.appendingPathComponent("close-checks.json"))
        guard checks.values.allSatisfy({ $0 }) else {
            throw LaunchError.invalid("Native close lifecycle regression failed: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", "))
        }
    }
}
