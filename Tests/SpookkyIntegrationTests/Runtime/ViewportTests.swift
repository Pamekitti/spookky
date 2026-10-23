import SpookkyTestSupport
import XCTest
import SpookkyCore
import SpookkyRuntime

final class ViewportTests: XCTestCase {
    func testWrappedAnchorDuringOutputAndReturnToLivePrompt() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-m1-stream-" + UUID().uuidString.prefix(8))
        let runtime = try TmuxRuntime(executable: PackagedRuntime.tmux(),
            helper: TestExecutables.launchHelper(bundle: Bundle(for: Self.self)), root: root)
        let socket = await runtime.socket
        defer { _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"]); try? FileManager.default.removeItem(at: root) }
        let gate = root.appendingPathComponent("start-output")
        let command = "for i in {1..150}; do printf 'LINE_%03d %090d\\n' $i 0; done; (for tick in {1..500}; do [[ -e \"$1\" ]] && break; sleep 0.01; done; [[ -e \"$1\" ]] || exit 0; for i in {151..200}; do printf 'LINE_%03d %090d\\n' $i 0; sleep 0.02; done) & exec /bin/cat"
        let binding = try await runtime.create(LaunchSpec(tool: .shell, executable: "/bin/zsh", arguments: ["-f", "-c", command, "spookky-fixture", gate.path], directory: root.path))
        for _ in 0..<100 {
            let info = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "list-panes", "-t", "=" + binding.name, "-F", "#{history_size}|#{pane_current_command}"])
            let fields = info.output.trimmingCharacters(in: .newlines).split(separator: "|")
            if fields.count == 2, (Int(fields[0]) ?? 0) > 100, fields[1] == "cat" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let entered = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "copy-mode", "-t", "=" + binding.name + ":0.0"])
        XCTAssertEqual(entered.status, 0, entered.error)
        let scrolled = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "send-keys", "-t", "=" + binding.name + ":0.0", "-X", "-N", "30", "scroll-up"])
        XCTAssertEqual(scrolled.status, 0, scrolled.error)
        let observed = try await runtime.viewport(binding)
        let saved = try XCTUnwrap(observed)
        XCTAssertNotNil(saved.anchor)
        try Data().write(to: gate)
        var streamed = false
        for _ in 0..<300 {
            let screen = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "capture-pane", "-p", "-J", "-t", "=" + binding.name + ":0.0"])
            if screen.output.contains("LINE_160") { streamed = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(streamed, "The producer must advance after copy mode freezes its history.")
        let duringOutput = try await runtime.viewport(binding)
        XCTAssertEqual(duringOutput?.anchor?.digest, saved.anchor?.digest)
        let before = try await runtime.inspect(binding)
        _ = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "resize-window", "-t", "=" + binding.name, "-x", "60", "-y", "40"])
        try await runtime.restoreViewport(saved, binding: binding, columns: 60, rows: 40)
        let restored = try await runtime.viewport(binding)
        XCTAssertEqual(restored?.anchor?.digest, saved.anchor?.digest)
        let after = try await runtime.inspect(binding)
        XCTAssertEqual(before?.processID, after?.processID)
        _ = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "send-keys", "-t", "=" + binding.name + ":0.0", "-X", "cancel"])
        let live = try await runtime.viewport(binding)
        XCTAssertNil(live)
    }
    func testOwnerViewportRestoresWithoutNewProcess() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-m1-viewport-" + UUID().uuidString.prefix(8))
        let runtime = try TmuxRuntime(executable: PackagedRuntime.tmux(),
            helper: TestExecutables.launchHelper(bundle: Bundle(for: Self.self)), root: root)
        let socket = await runtime.socket
        defer {
            _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: root)
        }
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/zsh", arguments: ["-f", "-c", "for i in {1..150}; do echo HISTORY_$i; done; exec /bin/cat"], directory: root.path)
        let binding = try await runtime.create(spec)
        for _ in 0..<100 {
            let info = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "list-panes", "-t", "=" + binding.name, "-F", "#{history_size}"])
            if (Int(info.output.trimmingCharacters(in: .newlines)) ?? 0) > 100 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let before = try await runtime.inspect(binding)
        for args in [["copy-mode", "-t", "=" + binding.name + ":0.0"],
                     ["send-keys", "-t", "=" + binding.name + ":0.0", "-X", "-N", "30", "scroll-up"]] {
            _ = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket] + args)
        }
        let captured = try await runtime.viewport(binding)
        let viewport = try XCTUnwrap(captured)
        XCTAssertEqual(viewport.scrollOffset, 30)
        _ = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "send-keys", "-t", "=" + binding.name + ":0.0", "-X", "history-bottom"])
        try await runtime.restoreViewport(viewport, binding: binding, columns: 120, rows: 35)
        let restored = try await runtime.viewport(binding)
        let after = try await runtime.inspect(binding)
        XCTAssertEqual(restored, viewport)
        XCTAssertEqual(before?.processID, after?.processID)
        _ = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "resize-window", "-t", "=" + binding.name, "-x", "120", "-y", "50"])
        try await runtime.restoreViewport(viewport, binding: binding, columns: 120, rows: 50)
        let resizedViewport = try await runtime.viewport(binding)
        let resized = try XCTUnwrap(resizedViewport)
        XCTAssertEqual(resized.historySize - resized.scrollOffset, viewport.historySize - viewport.scrollOffset)
        _ = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "resize-window", "-t", "=" + binding.name, "-x", "8", "-y", "40"])
        try await runtime.restoreViewport(viewport, binding: binding, columns: 8, rows: 40)
        let narrow = try await runtime.viewport(binding)
        XCTAssertEqual(narrow?.anchor?.digest, viewport.anchor?.digest)
        XCTAssertNotNil(narrow?.anchor)
    }
    func testOwnedRuntimeExitNotifications() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-m1-events-" + UUID().uuidString.prefix(8))
        let file = root.appendingPathComponent("runtime-event")
        try PrivateFiles.directory(root)
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let runtime = try TmuxRuntime(executable: PackagedRuntime.tmux(),
            helper: TestExecutables.launchHelper(bundle: Bundle(for: Self.self)),
            root: root, eventFile: file)
        let socket = await runtime.socket
        defer { _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"]); try? FileManager.default.removeItem(at: root) }
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/sleep", arguments: ["0.2"], directory: root.path)
        let binding = try await runtime.create(spec)
        var changed = false
        for _ in 0..<100 {
            let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
            if date != before { changed = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(changed)
        let observation = try await runtime.inspect(binding)
        XCTAssertEqual(observation?.dead, true)
    }
    func testExistingPrivateServerReceivesEventsWithoutReplacingProcess() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-m1-upgrade-" + UUID().uuidString.prefix(8))
        try PrivateFiles.directory(root)
        let file = root.appendingPathComponent("runtime-event")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        let helper = TestExecutables.launchHelper(bundle: Bundle(for: Self.self))
        let old = try TmuxRuntime(executable: PackagedRuntime.tmux(), helper: helper, root: root)
        let socket = await old.socket
        defer { _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"]); try? FileManager.default.removeItem(at: root) }
        let binding = try await old.create(LaunchSpec(tool: .shell, executable: "/bin/sleep", arguments: ["0.6"], directory: root.path))
        let original = try await old.inspect(binding)
        let upgraded = try TmuxRuntime(executable: PackagedRuntime.tmux(), helper: helper, root: root, eventFile: file)
        let observed = try await upgraded.inspect(binding)
        XCTAssertEqual(observed?.processID, original?.processID)
        var changed = false
        for _ in 0..<100 {
            let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
            if date != before { changed = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(changed)
    }
}
