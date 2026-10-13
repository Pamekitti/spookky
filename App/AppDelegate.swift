import AppKit
import Carbon
import Darwin
import GhosttyKit
import SpookkyCore
import SpookkyRuntime
import SpookkyWorkspace
import SpookkyPersistence

private struct HarnessSession {
    let id: UUID
    let title: String
    let binding: SessionBinding?
    let direct: LaunchSpec?
    var surface: TerminalHostView?

    mutating func releaseView() {
        surface?.removeFromSuperview()
        surface?.releaseSurface()
        surface = nil
    }
}

@main @MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var workspaceController: WorkspaceWindowController?
    private var window: NSWindow!
    private var engine: GhosttyEngine!
    private var runtime: TmuxRuntime!
    private var root: URL!
    private var sessions: [HarnessSession] = []
    private var selectedID: UUID?
    private let tool = NSPopUpButton()
    private let mode = NSPopUpButton()
    private let retention = NSButton(checkboxWithTitle: "Release hidden views", target: nil, action: nil)
    private let directory = NSTextField(string: FileManager.default.homeDirectoryForCurrentUser.path)
    private let prompt = NSTextField(string: "")
    private let status = NSTextField(labelWithString: "Native terminal feasibility harness")
    private let selector = NSPopUpButton()
    private let terminalContainer = NSView()
    private var busy = false
    private var savedClipboard: [[NSPasteboard.PasteboardType: Data]]?
    private var inputFixtureID: UUID?
    private var fixtureInputTrace: FixtureInputTrace?

    private static var startedAt = 0.0

    static func main() {
        startedAt = ProcessInfo.processInfo.systemUptime
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            if Bundle.main.bundleIdentifier == "dev.spookky.app", CommandLine.arguments.contains(where: { $0 == "--terminal-harness" || $0.hasPrefix("--workspace-benchmark") }) {
                throw LaunchError.invalid("Terminal diagnostics require a Spookky development build.")
            }
            if !CommandLine.arguments.contains("--terminal-harness") || CommandLine.arguments.contains("--workspace") {
                let paths = AppPaths(bundleID: Bundle.main.bundleIdentifier, home: FileManager.default.homeDirectoryForCurrentUser, userID: getuid())
                if paths.production && !InstallationLocation.canRun { InstallationLocation.showGuidance(); NSApp.terminate(nil); return }
                let workspaceRoot = paths.runtime
                let metadata = paths.data.path
                Task {
                    do {
                        let database = try await Task.detached {
                            try WorkspaceDatabase(path: URL(fileURLWithPath: metadata).appendingPathComponent("workspace.sqlite").path)
                        }.value
                        let saved = try await database.load()
                        let store = WorkspaceStore(state: saved ?? WorkspaceState(), persistence: database)
                        store.update { $0.restoreInterruptedDrafts() }
                        let args = CommandLine.arguments
                        let benchmarkIndex = args.firstIndex(of: "--workspace-benchmark-count")
                        if let index = benchmarkIndex {
                            guard saved == nil, args.indices.contains(index + 1), let count = Int(args[index + 1]), (0...10).contains(count),
                                  ProcessInfo.processInfo.environment["SPOOKKY_M1_DATA"] != nil,
                                  workspaceRoot.path.hasPrefix("/tmp/spookky-m1-") else { throw LaunchError.invalid("Workspace benchmarks require an isolated fixture root and a count from zero to ten.") }
                            workspaceController = try WorkspaceWindowController(root: workspaceRoot, initialStore: store, resolver: WorkspaceBenchmarkResolver(),
                                backgroundFixture: !args.contains("--workspace-benchmark-front"))
                            try await workspaceController?.benchmark(count: count, root: workspaceRoot, timing: args.contains("--workspace-benchmark-timing"))
                        } else {
                            let backgroundRestore = args.contains("--workspace-benchmark-restoring") && !args.contains("--workspace-benchmark-front") &&
                                workspaceRoot.path.hasPrefix("/tmp/spookky-m1-") && ProcessInfo.processInfo.environment["SPOOKKY_M1_DATA"] != nil
                            workspaceController = try WorkspaceWindowController(root: workspaceRoot, initialStore: store,
                                backgroundFixture: backgroundRestore)
                        }
                        if args.contains("--workspace-benchmark-front") || (benchmarkIndex == nil && !args.contains("--workspace-benchmark-restoring")) {
                            workspaceController?.window.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        else { workspaceController?.window.orderBack(nil) }
                    } catch {
                        if CommandLine.arguments.contains("--workspace-benchmark-count") {
                            workspaceController?.recordBenchmarkFailure(root: workspaceRoot)
                            fputs(error.localizedDescription + "\n", stderr)
                            _exit(1)
                        }
                        let alert = NSAlert()
                        alert.messageText = "Spookky could not restore workspaces"
                        alert.informativeText = error.localizedDescription + "\nYour database and running sessions were preserved.\nDatabase folder: " + metadata
                        alert.addButton(withTitle: "Quit")
                        alert.runModal()
                        NSApp.terminate(nil)
                    }
                }
                return
            }
            let paths = AppPaths(bundleID: Bundle.main.bundleIdentifier, home: FileManager.default.homeDirectoryForCurrentUser, userID: getuid())
            let suffix = paths.developmentID.map { "-" + $0 } ?? ""
            root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SPOOKKY_M0_ROOT"] ?? "/tmp/spookky-m0-\(getuid())\(suffix)")
            try PrivateFiles.directory(root)
            let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("spookky-launch").path
            runtime = try TmuxRuntime(executable: PackagedRuntime.tmux(), helper: helper, root: root)
            engine = try GhosttyEngine(root: root)
            buildWindow()
            NSApp.activate(ignoringOtherApps: true)
            busy = true
            Task { defer { busy = false }; await restore() }
        } catch { show(error) }
    }

    private func buildWindow() {
        let applicationMenu = NSMenu()
        let item = NSMenuItem()
        applicationMenu.addItem(item)
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit Spookky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(TerminalHostView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(TerminalHostView.paste(_:)), keyEquivalent: "v")
        editItem.submenu = edit
        applicationMenu.addItem(editItem)
        if CommandLine.arguments.contains("--interactive-checks") {
            let diagnostics = NSMenuItem(title: "Input checks", action: nil, keyEquivalent: "")
            let menu = NSMenu(title: "Input checks")
            for (title, tag) in [("Load text clipboard fixture", 0), ("Load image clipboard fixture", 1), ("Empty test clipboard", 2), ("Restore original clipboard", 3)] {
                let item = NSMenuItem(title: title, action: #selector(clipboardFixture(_:)), keyEquivalent: "")
                item.target = self
                item.tag = tag
                menu.addItem(item)
            }
            diagnostics.submenu = menu
            applicationMenu.addItem(diagnostics)
        }
        NSApp.mainMenu = applicationMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Spookky · Native Terminal"
        window.minSize = NSSize(width: 700, height: 450)
        window.backgroundColor = NSColor(calibratedRed: 0.082, green: 0.075, blue: 0.071, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        tool.addItems(withTitles: ["Terminal", "Codex", "Claude Code"])
        mode.addItems(withTitles: ["Persistent (tmux)", "Direct"])
        selector.target = self
        selector.action = #selector(selectSession)
        selector.setAccessibilityLabel("Sessions")
        retention.state = .on
        retention.target = self
        retention.action = #selector(retentionChanged)
        directory.placeholderString = "Working directory"
        directory.setAccessibilityLabel("Working directory")
        prompt.placeholderString = "Optional agent prompt"
        prompt.setAccessibilityLabel("Optional agent prompt")
        let launch = NSButton(title: "Open session", target: self, action: #selector(openSession))
        launch.keyEquivalent = "\r"
        launch.keyEquivalentModifierMask = .command
        let controls = NSStackView(views: [tool, mode, launch, retention])
        controls.spacing = 10
        let locationRow = NSStackView(views: [NSTextField(labelWithString: "Folder"), directory])
        locationRow.spacing = 10
        let sessionRow = NSStackView(views: [selector,
                                            NSButton(title: "Detach view", target: self, action: #selector(detach)),
                                            NSButton(title: "Reattach", target: self, action: #selector(reattach)),
                                            NSButton(title: "End session", target: self, action: #selector(endSession)),
                                            NSButton(title: "Inspect", target: self, action: #selector(inspectSession))])
        sessionRow.spacing = 8
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        let rows = NSStackView(views: [controls, locationRow, prompt, sessionRow, status])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rows)
        content.addSubview(terminalContainer)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            locationRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            prompt.widthAnchor.constraint(equalTo: rows.widthAnchor),
            status.widthAnchor.constraint(equalTo: rows.widthAnchor),
            selector.widthAnchor.constraint(equalToConstant: 230),
            terminalContainer.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 10),
            terminalContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func restore() async {
        do {
            for binding in try await runtime.list() {
                let observed = try await runtime.inspect(binding)
                sessions.append(HarnessSession(id: binding.id, title: binding.tool.rawValue + (observed == nil ? " · unavailable" : " · restored"),
                                               binding: binding, direct: nil, surface: nil))
            }
            refreshSelector()
            if let first = sessions.first { try await select(first.id) }
            try await runDiagnostics()
        } catch { show(error) }
    }

    private func runDiagnostics() async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--benchmark-agent-count"), CommandLine.arguments.count > index + 1,
           let count = Int(CommandLine.arguments[index + 1]), (1...10).contains(count) {
            let providerIndex = CommandLine.arguments.firstIndex(of: "--benchmark-provider")
            let provider = providerIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "mixed"
            guard ["codex", "claude", "mixed"].contains(provider) else { throw LaunchError.invalid("Unknown benchmark provider.") }
            directory.stringValue = "/tmp/spookky-m0-agent-fixture"
            mode.selectItem(at: 0)
            prompt.stringValue = ""
            retention.state = .on
            for number in 0..<count {
                let agent: SessionTool = provider == "claude" || (provider == "mixed" && number % 2 == 1) ? .claude : .codex
                try await launch(tool: agent)
            }
            var records: [[String: Any]] = []
            for session in sessions {
                if let binding = session.binding, let observed = try await runtime.inspect(binding) {
                    records.append(["tool": binding.tool.rawValue, "pid": observed.processID,
                                    "dead": observed.dead, "clients": observed.clients])
                }
            }
            let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
            let output = root.appendingPathComponent("agent-benchmark.json")
            try await Task.detached { try data.write(to: output, options: .atomic) }.value
            try PrivateFiles.write(["pid": Int(getpid()), "count": count], to: root.appendingPathComponent("ready.json"))
        }
        if CommandLine.arguments.contains("--benchmark-render") { try await runRenderedInputDiagnostics() }
        if CommandLine.arguments.contains("--claude-smoke") {
            directory.stringValue = "/tmp/spookky-m0-agent-fixture"
            mode.selectItem(at: 0)
            tool.selectItem(at: 2)
            prompt.stringValue = "Reply exactly SPOOKKY_M0_CLAUDE_OK. Do not use tools or change files."
            try await launch(tool: .claude)
            try PrivateFiles.write(["pid": Int(getpid())], to: root.appendingPathComponent("ready.json"))
        }
        if CommandLine.arguments.contains("--input-fixture") {
            mode.selectItem(at: CommandLine.arguments.contains("--direct") ? 1 : 0)
            let script = root.appendingPathComponent("input-check.py")
            guard FileManager.default.fileExists(atPath: script.path) else { throw LaunchError.invalid("Disposable input fixture is missing.") }
            let spec = try LaunchSpec(tool: .shell, executable: "/usr/bin/python3",
                arguments: [script.path, "--output", root.appendingPathComponent("input-bytes.json").path], directory: root.path)
            inputFixtureID = spec.operationID
            fixtureInputTrace = FixtureInputTrace(output: root.appendingPathComponent("input-events.jsonl"))
            try await launch(tool: .shell, specification: spec)
            FileHandle.standardError.write(Data("Input fixture launched\n".utf8))
            guard try await waitForTerminal("INPUT CHECK READY") else { throw LaunchError.invalid("Input fixture failed to start.") }
            FileHandle.standardError.write(Data("Input fixture ready\n".utf8))
            if CommandLine.arguments.contains("--input-replay") { try await replayFixtureInput() }
            try PrivateFiles.write(["pid": Int(getpid())], to: root.appendingPathComponent("ready.json"))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--folder-probe"), CommandLine.arguments.count > index + 1 {
            try await runFolderProbe(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if CommandLine.arguments.contains("--benchmark-timing") {
            try await runTimingDiagnostics()
        }
        if let countIndex = CommandLine.arguments.firstIndex(of: "--benchmark-count"),
           CommandLine.arguments.count > countIndex + 1,
           let count = Int(CommandLine.arguments[countIndex + 1]), (0...10).contains(count) {
            retention.state = CommandLine.arguments.contains("--retain") ? .off : .on
            for _ in 0..<count { try await launch(tool: .shell, fixture: true) }
            try PrivateFiles.write(["pid": Double(getpid()), "count": Double(count),
                                    "main_to_ready_ms": (ProcessInfo.processInfo.systemUptime - Self.startedAt) * 1000],
                                   to: root.appendingPathComponent("ready.json"))
        }
        if CommandLine.arguments.contains("--benchmark-cycles") {
            var checkpoints: [[String: Int]] = []
            for cycle in 1...100 {
                try await launch(tool: .shell, fixture: true)
                try await Task.sleep(for: .milliseconds(150))
                var session = sessions.removeLast()
                if let binding = session.binding { try await runtime.terminate(binding) }
                session.releaseView()
                selectedID = nil
                refreshSelector()
                if cycle % 10 == 0 {
                    var info = mach_task_basic_info()
                    var size = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
                    let result = withUnsafeMutablePointer(to: &info) { pointer in
                        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &size)
                        }
                    }
                    if result == KERN_SUCCESS { checkpoints.append(["cycle": cycle, "rss_bytes": Int(info.resident_size)]) }
                    try PrivateFiles.write(checkpoints, to: root.appendingPathComponent("cycles.json"))
                }
            }
            try PrivateFiles.write(["pid": Int(getpid()), "cycles": 100], to: root.appendingPathComponent("ready.json"))
        }
        if CommandLine.arguments.contains("--self-test") {
            try await launch(tool: .shell, fixture: true)
            try await Task.sleep(for: .seconds(1))
            guard let session = sessions.last, let binding = session.binding else { throw LaunchError.invalid("Missing fixture session.") }
            let id = session.id
            let beforePID = try await runtime.inspect(binding)?.processID
            let before = sessions.last?.surface?.visibleText() ?? ""
            if let surface = sessions.last?.surface?.surface {
                ghostty_surface_mouse_pos(surface, 200, 200, GHOSTTY_MODS_NONE)
                ghostty_surface_mouse_scroll(surface, 0, 10, 0)
            }
            try await Task.sleep(for: .milliseconds(300))
            let scrolled = sessions.last?.surface?.visibleText() ?? ""
            let historyBefore = before != scrolled && scrolled.contains("Spookky fixture")
            sessions[sessions.count - 1].releaseView()
            try await select(id)
            try await Task.sleep(for: .milliseconds(300))
            let after = sessions.last?.surface?.visibleText() ?? ""
            let afterPID = try await runtime.inspect(binding)?.processID
            try PrivateFiles.write([
                "history_scroll_changed_screen": historyBefore,
                "history_screen_survived_reattach": scrolled == after,
                "same_process": beforePID == afterPID,
                "restored_fixture_visible": after.contains("Spookky fixture")
            ], to: root.appendingPathComponent("self-test.json"))
            try PrivateFiles.write(["pid": Int(getpid())], to: root.appendingPathComponent("ready.json"))
        }
    }

    private func runRenderedInputDiagnostics() async throws {
        mode.selectItem(at: CommandLine.arguments.contains("--direct") ? 1 : 0)
        let load = CommandLine.arguments.contains("--output-load") ? 500 : 0
        let script = root.appendingPathComponent("render-input.py")
        let spec = try LaunchSpec(tool: .shell, executable: "/usr/bin/python3",
            arguments: [script.path, "--lines-per-second", String(load)], directory: root.path)
        try await launch(tool: .shell, specification: spec)
        guard let view = sessions.last?.surface else { throw LaunchError.invalid("Missing rendered-input fixture.") }
        func waitForColor(green: Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while ProcessInfo.processInfo.systemUptime < deadline {
                if RenderedFixtureProbe.matches(view, green: green) { return true }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return false
        }
        func sendKey(green: Bool) {
            let character = green ? "g" : "r"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: green ? 5 : 15)!
            view.keyDown(with: event)
        }
        guard try await waitForTerminal("SPOOKKY_RENDER_READY", timeout: 5) else { throw LaunchError.invalid("Rendered input producer failed to start.") }
        try await Task.sleep(for: .milliseconds(200))
        sendKey(green: true)
        guard await waitForColor(green: true) else { throw LaunchError.invalid("Rendered green calibration failed.") }
        sendKey(green: false)
        guard await waitForColor(green: false) else { throw LaunchError.invalid("Rendered red calibration failed.") }
        try await Task.sleep(for: .seconds(1))
        var rows: [[String: Any]] = []
        for index in 0..<110 {
            let green = index % 2 == 0
            let started = ProcessInfo.processInfo.systemUptime
            sendKey(green: green)
            let matched = await waitForColor(green: green)
            if index >= 10 || !matched {
                rows.append(["milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000, "matched": matched])
            }
            if !matched { break }
        }
        let result: [String: Any] = ["samples": rows, "output_lines_per_second": load,
            "boundary": "Native keyDown to matching BGRA pixels in Ghostty's completed IOSurface assigned to its CALayer; 2 ms polling. Excludes physical keyboard and compositor/display scanout."]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        let output = root.appendingPathComponent("rendered-input.json")
        try await Task.detached { try data.write(to: output, options: .atomic) }.value
        try PrivateFiles.write(["pid": Int(getpid())], to: root.appendingPathComponent("ready.json"))
    }

    private func replayFixtureInput() async throws {
        guard let view = sessions.last?.surface, sessions.last?.id == inputFixtureID else { return }
        fixtureInputTrace?.record("replay_started")
        status.stringValue = "Replaying native input into the disposable fixture…"
        try await checkEnabledKeyboardSources()
        if let surface = view.surface {
            var x = 0.0, y = 0.0, width = 0.0, height = 0.0
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            let cursorBottom = window.convertPoint(toScreen: view.convert(NSPoint(x: x, y: y), to: nil))
            let candidate = view.firstRect(forCharacterRange: .init(location: 0, length: 1), actualRange: nil)
            fixtureInputTrace?.record("ime_anchor_geometry", fields: [
                "matches_cursor_bottom": abs(candidate.minY - cursorBottom.y) < 0.01 && abs(candidate.minX - cursorBottom.x) < 0.01,
                "positive_cell_height": candidate.height > 0,
                "empty_selection_range": view.selectedRange() == NSRange(location: 0, length: 0)
            ])
        }
        func event(_ type: NSEvent.EventType, _ keycode: UInt16, _ text: String,
                   _ flags: NSEvent.ModifierFlags = [], repeating: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: repeating, keyCode: keycode)!
        }
        for (code, flag, mask) in [(UInt16(0x38), NSEvent.ModifierFlags.shift, NX_DEVICELSHIFTKEYMASK),
                                   (0x3C, .shift, NX_DEVICERSHIFTKEYMASK),
                                   (0x3B, .control, NX_DEVICELCTLKEYMASK),
                                   (0x3E, .control, NX_DEVICERCTLKEYMASK),
                                   (0x3A, .option, NX_DEVICELALTKEYMASK),
                                   (0x3D, .option, NX_DEVICERALTKEYMASK),
                                   (0x37, .command, NX_DEVICELCMDKEYMASK),
                                   (0x36, .command, NX_DEVICERCMDKEYMASK)] {
            view.flagsChanged(with: event(.flagsChanged, code, "", flag.union(.init(rawValue: UInt(mask)))))
            view.flagsChanged(with: event(.flagsChanged, code, ""))
        }
        view.keyDown(with: event(.keyDown, 12, "q"))
        view.keyDown(with: event(.keyDown, 12, "q", repeating: true))
        view.keyUp(with: event(.keyUp, 12, "q"))
        view.insertText("COMMITTED café ไทย 日本語", replacementRange: .init(location: NSNotFound, length: 0))
        view.keyDown(with: event(.keyDown, 122, "\u{F704}"))
        view.keyDown(with: event(.keyDown, 7, "≈", .option))
        guard try await waitForTerminal("COMMITTED") else { throw LaunchError.invalid("Native input replay did not reach the byte fixture.") }
    }

    private func checkEnabledKeyboardSources() async throws {
        engine.keyboardTrace = fixtureInputTrace
        defer { engine.keyboardTrace = nil }
        guard let original = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            throw LaunchError.invalid("Current keyboard source is unavailable.")
        }
        let originalID = TerminalHostView.keyboardSourceID
        defer { TISSelectInputSource(original) }
        let filter = [kTISPropertyInputSourceIsEnabled!: true,
                      kTISPropertyInputSourceType!: kTISTypeKeyboardLayout!] as CFDictionary
        let sources = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
        for source in sources.prefix(3) {
            let status = TISSelectInputSource(source)
            try await Task.sleep(for: .milliseconds(100))
            fixtureInputTrace?.record("selected_keyboard_source", fields: [
                "status": status, "source_id": TerminalHostView.keyboardSourceID ?? "unknown"
            ])
        }
        let restored = TISSelectInputSource(original)
        try await Task.sleep(for: .milliseconds(100))
        fixtureInputTrace?.record("restored_keyboard_source", fields: [
            "status": restored, "same_source": TerminalHostView.keyboardSourceID == originalID
        ])
        guard restored == noErr, TerminalHostView.keyboardSourceID == originalID else {
            throw LaunchError.invalid("Keyboard source restoration failed. Restore your original input source before continuing.")
        }
    }

    private func runFolderProbe(_ target: URL) async throws {
        let cleanShell = "printf 'SPOOKKY_FOLDER_SHELL_READY\\n'; /bin/pwd; printf 'SPOOKKY_FOLDER_READ_BEGIN\\n'; /bin/cat \"$1\"; result=$?; printf '\\nSPOOKKY_FOLDER_READ_END status=%s\\n' \"$result\"; printf 'SPOOKKY_FOLDER_PYTHON_BEGIN\\n'; /usr/bin/python3 \"$2\"; result=$?; printf '\\nSPOOKKY_FOLDER_PYTHON_END status=%s\\n' \"$result\"; exit \"$result\""
        var results: [[String: Any]] = []
        for (label, folder) in [("temporary", root!), ("documents", target)] {
            for direct in [false, true] {
                mode.selectItem(at: direct ? 1 : 0)
                let spec = try LaunchSpec(tool: .shell, executable: "/bin/zsh",
                    arguments: ["-f", "-c", cleanShell, "spookky-folder-check", folder.appendingPathComponent("known.txt").path, folder.appendingPathComponent("read-check.py").path],
                    directory: folder.path, environment: ["SPOOKKY_M0_FOLDER_PROBE": "1"])
                status.stringValue = "Checking \(label) folder · \(direct ? "direct" : "persistent")…"
                let started = ProcessInfo.processInfo.systemUptime
                var result: [String: Any] = ["location": label, "mode": direct ? "direct" : "persistent", "operation_id": spec.operationID.uuidString]
                do {
                    try await launch(tool: .shell, specification: spec)
                    let completed = try await waitForTerminal("SPOOKKY_FOLDER_PYTHON_END", timeout: 8)
                    result["completed"] = completed
                    let screen = sessions.last?.surface?.visibleText() ?? ""
                    result["screen"] = screen
                    result["passed"] = completed && screen.contains("SPOOKKY_FOLDER_READ_END status=0") && screen.contains("SPOOKKY_FOLDER_PYTHON_END status=0") && screen.contains("SPOOKKY_KNOWN_FOLDER_CONTENT") && screen.contains("SPOOKKY_PYTHON_READ_OK")
                    if let binding = sessions.last?.binding, let observed = try await runtime.inspect(binding) {
                        result["pid"] = observed.processID
                        result["exit_code"] = observed.exitCode
                    } else {
                        let receipt = root.appendingPathComponent("exec-" + spec.operationID.uuidString + ".json")
                        if let data = try? Data(contentsOf: receipt), let observed = try? JSONDecoder().decode(ExecutionReceipt.self, from: data) {
                            result["pid"] = observed.processID
                        }
                    }
                    if !completed, let pid = result["pid"] as? Int32 {
                        let sample = try? await ProcessRunner.asyncRun("/usr/bin/sample", [String(pid), "1", "1", "-file", root.appendingPathComponent("sample-" + spec.operationID.uuidString + ".txt").path])
                        result["sample_status"] = sample?.status
                    }
                    if let last = sessions.last, last.id == spec.operationID {
                        if let binding = last.binding { try await runtime.terminate(binding) }
                        sessions[sessions.count - 1].releaseView()
                        sessions.removeLast()
                        selectedID = nil
                        refreshSelector()
                    }
                } catch { result["error"] = error.localizedDescription }
                result["elapsed_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
                results.append(result)
                let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                let output = root.appendingPathComponent("folder-probe.json")
                try await Task.detached { try data.write(to: output, options: .atomic) }.value
            }
        }
        status.stringValue = "Folder checks finished. Results are in the private fixture folder."
        try PrivateFiles.write(["pid": Int(getpid())], to: root.appendingPathComponent("ready.json"))
    }

    private func waitForTerminal(_ text: String, timeout: Double = 3) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if sessions.last?.surface?.visibleText().contains(text) == true { return true }
            try await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    private func runTimingDiagnostics() async throws {
        try await launch(tool: .shell, fixture: true)
        guard let binding = sessions.last?.binding,
              try await waitForTerminal("Spookky fixture 04999") else {
            throw LaunchError.invalid("Timing fixture failed to become ready.")
        }
        let originalPID = try await runtime.inspect(binding)?.processID
        let draft = "SPOOKKY_UNSENT_TIMING_DRAFT"
        sessions.last?.surface?.insertText(draft, replacementRange: NSRange(location: NSNotFound, length: 0))
        guard try await waitForTerminal(draft) else { throw LaunchError.invalid("Draft did not echo.") }
        var attachments: [[String: Double]] = []
        for _ in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            sessions[sessions.count - 1].releaseView()
            try await select(binding.id)
            let restored = try await waitForTerminal(draft)
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let observation = try await runtime.inspect(binding)
            attachments.append(["milliseconds": elapsed,
                                "draft_preserved": restored ? 1 : 0,
                                "same_process": originalPID != nil && observation?.processID == originalPID ? 1 : 0,
                                "one_client": observation?.clients == 1 ? 1 : 0])
        }
        var echoes: [[String: Double]] = []
        for index in 0..<100 {
            let marker = String(format: " E%03d", index)
            let start = ProcessInfo.processInfo.systemUptime
            sessions.last?.surface?.insertText(marker, replacementRange: NSRange(location: NSNotFound, length: 0))
            let echoed = try await waitForTerminal(marker)
            echoes.append(["milliseconds": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                           "echoed": echoed ? 1 : 0])
        }
        try PrivateFiles.write(["reattachment": attachments, "terminal_state_echo": echoes],
                               to: root.appendingPathComponent("timing.json"))
        try PrivateFiles.write(["pid": Int(getpid())], to: root.appendingPathComponent("ready.json"))
    }

    private func runSessionOperation(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await operation() } catch { show(error) }
        }
    }

    @objc private func openSession() {
        guard !busy else { return }
        let selected: SessionTool = tool.indexOfSelectedItem == 1 ? .codex : tool.indexOfSelectedItem == 2 ? .claude : .shell
        status.stringValue = "Starting session…"
        runSessionOperation { try await self.launch(tool: selected) }
    }

    private func launch(tool: SessionTool, fixture: Bool = false, specification: LaunchSpec? = nil) async throws {
        let spec: LaunchSpec
        if let specification { spec = specification }
        else if fixture {
            spec = try LaunchSpec(tool: tool, executable: "/bin/sh",
                arguments: ["-c", "i=0; while [ $i -lt 5000 ]; do printf 'Spookky fixture %05d: predictable terminal output\\n' $i; i=$((i+1)); done; exec /bin/cat"],
                directory: "/tmp", environment: ["PATH": "/bin:/opt/homebrew/bin:/usr/bin:/usr/sbin:/sbin:" + (ProcessInfo.processInfo.environment["PATH"] ?? "")])
        } else {
            spec = try await CLIResolver().resolve(tool,
                directory: URL(fileURLWithPath: directory.stringValue).standardized.path,
                prompt: prompt.stringValue.isEmpty ? nil : prompt.stringValue)
        }
        let binding: SessionBinding? = mode.indexOfSelectedItem == 0 ? try await runtime.create(spec) : nil
        sessions.append(HarnessSession(id: spec.operationID, title: "\(tool.rawValue) · \(binding == nil ? "direct" : "persistent") · \(spec.operationID.uuidString.prefix(4))",
                                       binding: binding, direct: binding == nil ? spec : nil, surface: nil))
        refreshSelector()
        try await select(spec.operationID)
        status.stringValue = "Session opened. Provider permissions and history stay inside the CLI."
    }

    private func refreshSelector() {
        selector.removeAllItems()
        for session in sessions { selector.addItem(withTitle: session.title) }
        if let selectedID, let index = sessions.firstIndex(where: { $0.id == selectedID }) { selector.selectItem(at: index) }
    }

    private func select(_ id: UUID) async throws {
        if let previous = sessions.firstIndex(where: { $0.id == selectedID }), sessions[previous].id != id {
            if retention.state == .on && sessions[previous].binding != nil {
                sessions[previous].releaseView()
            } else {
                sessions[previous].surface?.removeFromSuperview()
                if let surface = sessions[previous].surface?.surface {
                    ghostty_surface_set_occlusion(surface, false)
                    ghostty_surface_set_focus(surface, false)
                }
            }
        }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].surface == nil {
            let command: String
            if let binding = sessions[index].binding {
                let arguments = try await runtime.attachmentArguments(binding)
                let executable = await runtime.executable
                command = ShellCommand.render([executable] + arguments)
            } else if let spec = sessions[index].direct {
                let request = root.appendingPathComponent("direct-" + id.uuidString + ".json")
                let receipt = root.appendingPathComponent("exec-" + id.uuidString + ".json")
                guard !FileManager.default.fileExists(atPath: receipt.path) else { throw LaunchError.uncertainLaunch }
                let helperRequest = HelperRequest(spec: spec, resultPath: receipt.path)
                try await Task.detached {
                    try PrivateFiles.write(helperRequest, to: request)
                }.value
                let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("spookky-launch").path
                command = ShellCommand.render([helper, "--request", request.path])
            } else { return }
            let view = try TerminalHostView(engine: engine, command: command, directory: root.path)
            if let binding = sessions[index].binding, let runtime {
                view.applicationCapturesMouse = { try await runtime.applicationCapturesMouse(binding) }
            }
            if id == inputFixtureID {
                view.inputTrace = fixtureInputTrace
            }
            view.onExit = { [weak self] _ in self?.status.stringValue = "Terminal frontend exited. Inspect the runtime before restarting." }
            sessions[index].surface = view
        }
        selectedID = id
        selector.selectItem(at: index)
        terminalContainer.subviews.forEach { $0.removeFromSuperview() }
        let view = sessions[index].surface!
        view.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor)
        ])
        if let surface = view.surface { ghostty_surface_set_occlusion(surface, true) }
        window.makeFirstResponder(view)
    }

    @objc private func selectSession() {
        guard !busy, sessions.indices.contains(selector.indexOfSelectedItem) else { return }
        let id = sessions[selector.indexOfSelectedItem].id
        runSessionOperation { try await self.select(id) }
    }
    @objc private func retentionChanged() {
        if retention.state == .on {
            for index in sessions.indices where sessions[index].id != selectedID && sessions[index].binding != nil {
                sessions[index].releaseView()
            }
        }
    }
    @objc private func detach() {
        guard !busy, let index = sessions.firstIndex(where: { $0.id == selectedID }) else { return }
        guard sessions[index].binding != nil else { status.stringValue = "Direct sessions cannot release their view while preserving the process."; return }
        sessions[index].releaseView()
        status.stringValue = "View released. Persistent session continues running."
    }
    @objc private func reattach() {
        guard !busy, let selectedID else { return }
        runSessionOperation {
            try await self.select(selectedID)
            self.status.stringValue = "View reattached to the existing session."
        }
    }
    @objc private func inspectSession() {
        guard let session = sessions.first(where: { $0.id == selectedID }) else { return }
        Task {
            do {
                if let binding = session.binding, let observed = try await runtime.inspect(binding) {
                    status.stringValue = "PID \(observed.processID) · \(observed.dead ? "ended, exit \(observed.exitCode ?? -1)" : "process present, activity unknown") · \(observed.clients) attached view(s)"
                } else { status.stringValue = session.binding == nil ? "Direct terminal; view owns the process." : "Runtime unavailable. No process was restarted." }
            } catch { show(error) }
        }
    }
    @objc private func endSession() {
        guard !busy, let index = sessions.firstIndex(where: { $0.id == selectedID }) else { return }
        let alert = NSAlert()
        alert.messageText = "End this session?"
        alert.informativeText = "Its terminal process will stop. Provider history and files remain."
        alert.addButton(withTitle: "End session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var session = sessions[index]
        runSessionOperation {
            if let binding = session.binding { try await self.runtime.terminate(binding) }
            session.releaseView()
            self.sessions.removeAll { $0.id == session.id }
            self.selectedID = nil
            self.refreshSelector()
            if let first = self.sessions.first { try await self.select(first.id) }
            self.status.stringValue = "Session ended."
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let workspaceController { return workspaceController.prepareToQuit() }
        guard !busy else {
            status.stringValue = "Finish the current session operation before quitting."
            return .terminateCancel
        }
        guard !sessions.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Spookky?"
        alert.informativeText = "Persistent sessions can continue in the background. Direct sessions end when the app exits."
        alert.addButton(withTitle: "Continue in background")
        alert.addButton(withTitle: "End sessions and quit")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .terminateNow
        case .alertSecondButtonReturn:
            Task {
                do {
                    for session in sessions { if let binding = session.binding { try await runtime.terminate(binding) } }
                    NSApp.reply(toApplicationShouldTerminate: true)
                } catch { show(error); NSApp.reply(toApplicationShouldTerminate: false) }
            }
            return .terminateLater
        default: return .terminateCancel
        }
    }

    @objc private func clipboardFixture(_ sender: NSMenuItem) {
        if sender.tag == 3 {
            restoreClipboard()
            status.stringValue = "Original clipboard restored."
            return
        }
        let pasteboard = NSPasteboard.general
        if savedClipboard == nil {
            savedClipboard = (pasteboard.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        }
        if sender.tag == 1 {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 96, bitsPerPixel: 24),
                let bytes = bitmap.bitmapData else { return }
            for pixel in 0..<1024 {
                bytes[pixel * 3] = 40
                bytes[pixel * 3 + 1] = 120
                bytes[pixel * 3 + 2] = 200
            }
            guard let png = bitmap.representation(using: .png, properties: [:]),
                  let tiff = bitmap.representation(using: .tiff, properties: [:]) else { return }
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            pasteboard.setData(tiff, forType: .tiff)
            status.stringValue = "Image-only clipboard fixture ready (32 × 32 PNG/TIFF)."
        } else {
            pasteboard.clearContents()
            if sender.tag == 0 {
                pasteboard.setString("SPOOKKY_COPY_CHECK café ไทย 日本語\nsecond line", forType: .string)
                status.stringValue = "Text clipboard fixture ready."
            } else {
                status.stringValue = "Test clipboard has no formats."
            }
        }
    }

    private func restoreClipboard() {
        guard let savedClipboard else { return }
        let items = savedClipboard.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        NSPasteboard.general.clearContents()
        if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
        self.savedClipboard = nil
    }

    func applicationWillTerminate(_ notification: Notification) { restoreClipboard() }

    func applicationDidBecomeActive(_ notification: Notification) { workspaceController?.setFocus(true); if let app = engine?.app { ghostty_app_set_focus(app, true) } }
    func applicationDidResignActive(_ notification: Notification) { workspaceController?.setFocus(false); if let app = engine?.app { ghostty_app_set_focus(app, false) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let workspaceController { workspaceController.reopen(); return true }
        window?.makeKeyAndOrderFront(nil)
        if !busy, let id = selectedID, sessions.first(where: { $0.id == id })?.surface == nil {
            runSessionOperation { try await self.select(id) }
        }
        return true
    }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let surface = sessions.first(where: { $0.id == selectedID })?.surface?.surface else { return }
        ghostty_surface_set_occlusion(surface, window.isVisible && window.occlusionState.contains(.visible))
    }
    func windowWillClose(_ notification: Notification) {
        guard let index = sessions.firstIndex(where: { $0.id == selectedID }) else { return }
        if let surface = sessions[index].surface?.surface { ghostty_surface_set_occlusion(surface, false) }
        if !busy, retention.state == .on, sessions[index].binding != nil {
            sessions[index].releaseView()
        }
    }
    private func show(_ error: Error) {
        status.stringValue = error.localizedDescription
        let alert = NSAlert()
        alert.messageText = "Spookky"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
