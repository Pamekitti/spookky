import Foundation
import XCTest
import SpookkyTestSupport
import SpookkyCore
import SpookkyRuntime

final class RuntimeTests: XCTestCase {
    private func fixture() throws -> (TmuxRuntime, URL) {
        try TestRuntime.make(bundle: Bundle(for: Self.self))
    }

    func testShellRejectsAgentPrompt() throws {
        expectThrows(LaunchError.self) {
            try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp", initialPrompt: "Do something")
        }
    }

    func testRealTerminalDoesNotInheritCapturedOutputColorFlags() {
        let inherited = ["NO_COLOR": "1", "TERM": "dumb", "COLORTERM": "", "FORCE_COLOR": "0", "PATH": "/bin"]
        let values = TerminalEnvironment.nativePTY(inherited: inherited, overrides: [:])
        expectTrue(values["NO_COLOR"] == nil && values["FORCE_COLOR"] == nil)
        expectTrue(values["TERM"] == "xterm-ghostty" && values["COLORTERM"] == "truecolor")
        expectTrue(values["PATH"] == "/bin")
    }

    func testTerminalCapabilitiesAndExplicitColorChoicesArePreserved() {
        let values = TerminalEnvironment.nativePTY(inherited: ["TMUX": "/owned/socket,1,0", "TERM": "tmux-256color"],
            overrides: ["NO_COLOR": "1", "COLORTERM": "custom", "PATH": "/explicit/bin"])
        expectTrue(values["TERM"] == "tmux-256color" && values["NO_COLOR"] == "1")
        expectTrue(values["COLORTERM"] == "custom" && values["PATH"] == "/explicit/bin")
    }

    func testNewLaunchCorrectsColorEnvironmentFromSurvivingServer() async throws {
        let (runtime, root) = try fixture()
        let socket = await runtime.socket
        defer {
            _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: root)
        }
        let survivor = try await runtime.create(LaunchSpec(tool: .shell, executable: "/bin/cat", directory: root.path))
        let original = try requireValue(await runtime.inspect(survivor))
        for (key, value) in ["NO_COLOR": "1", "COLORTERM": "", "TERM": "dumb"] {
            let result = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "set-environment", "-g", key, value])
            expectTrue(result.status == 0)
        }
        let script = "import json,os,sys; values={k:os.environ.get(k) for k in ['TERM','COLORTERM','NO_COLOR']}; values['tty']=os.isatty(1); json.dump(values,open(sys.argv[1],'w'))"
        for explicit in [false, true] {
            let output = root.appendingPathComponent(explicit ? "explicit-color.json" : "native-color.json")
            _ = try await runtime.create(LaunchSpec(tool: .shell, executable: "/usr/bin/python3", arguments: ["-c", script, output.path],
                directory: root.path, environment: explicit ? ["NO_COLOR": "1"] : [:]))
            var values: [String: Any]?
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: output), let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { values = result; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let result = try requireValue(values)
            expectTrue(result["tty"] as? Bool == true && result["TERM"] as? String == "tmux-256color")
            expectTrue(result["COLORTERM"] as? String == "truecolor")
            if explicit { expectTrue(result["NO_COLOR"] as? String == "1") }
            else { expectTrue(result["NO_COLOR"] is NSNull) }
        }
        expectTrue(try await runtime.inspect(survivor)?.processID == original.processID)
    }

    func testRestoredServerEnablesFocusEventsWithoutRestartingItsProcess() async throws {
        let (runtime, root) = try fixture()
        let socket = await runtime.socket
        let tmux = try PackagedRuntime.tmux()
        defer { _ = try? ProcessRunner.run(tmux, ["-S", socket, "kill-server"]); try? FileManager.default.removeItem(at: root) }
        let binding = try await runtime.create(LaunchSpec(tool: .shell, executable: "/bin/cat", directory: root.path))
        let before = try requireValue(await runtime.inspect(binding))
        expectTrue(try ProcessRunner.run(tmux, ["-S", socket, "set-option", "-g", "focus-events", "off"]).status == 0)
        let helper = TestExecutables.launchHelper(bundle: Bundle(for: Self.self))
        let restored = try TmuxRuntime(executable: tmux, helper: helper, root: root)
        let after = try requireValue(await restored.inspect(binding))
        expectTrue(after.processID == before.processID && !after.dead)
        expectTrue(try ProcessRunner.run(tmux, ["-S", socket, "show-option", "-gv", "focus-events"]).output.trimmingCharacters(in: .whitespacesAndNewlines) == "on")
    }

    func testLegacyServerKeepsItsProcessWithoutUnsafeFocusForwarding() async throws {
        let (runtime, root) = try fixture()
        let socket = await runtime.socket, tmux = try PackagedRuntime.tmux()
        defer { _ = try? ProcessRunner.run(tmux, ["-S", socket, "kill-server"]); try? FileManager.default.removeItem(at: root) }
        let binding = try await runtime.create(LaunchSpec(tool: .shell, executable: "/bin/cat", directory: root.path))
        let before = try requireValue(await runtime.inspect(binding))
        expectTrue(try ProcessRunner.run(tmux, ["-S", socket, "set-option", "-gu", "@spookky-focus-guard"]).status == 0)
        let helper = TestExecutables.launchHelper(bundle: Bundle(for: Self.self))
        let restored = try TmuxRuntime(executable: tmux, helper: helper, root: root)
        let after = try requireValue(await restored.inspect(binding))
        expectTrue(after.processID == before.processID && !after.dead)
        expectTrue(try ProcessRunner.run(tmux, ["-S", socket, "show-option", "-gv", "focus-events"]).output.trimmingCharacters(in: .whitespacesAndNewlines) == "off")
    }

    func testMouseRoutingPreservesApplicationInputAndNativeHistorySelection() async throws {
        let (runtime, root) = try fixture()
        let socket = await runtime.socket
        defer {
            _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: root)
        }
        let shell = try await runtime.create(LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp"))
        expectTrue(try await runtime.applicationCapturesMouse(shell) == false)
        let app = try await runtime.create(LaunchSpec(tool: .shell, executable: "/bin/sh",
            arguments: ["-c", "printf '\\033[?1002h\\033[?1006h'; exec /bin/cat"], directory: "/tmp"))
        for _ in 0..<20 {
            if try await runtime.applicationCapturesMouse(app) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        expectTrue(try await runtime.applicationCapturesMouse(app))
        let entered = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "copy-mode", "-t", "=" + app.name + ":0.0"])
        expectTrue(entered.status == 0)
        expectTrue(try await runtime.applicationCapturesMouse(app) == false)
        let cancelled = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "send-keys", "-t", "=" + app.name + ":0.0", "-X", "cancel"])
        expectTrue(cancelled.status == 0)
        expectTrue(try await runtime.applicationCapturesMouse(app))
        expectTrue(try await runtime.inspect(shell)?.dead == false)
        expectTrue(try await runtime.inspect(app)?.dead == false)
    }

    func testMouseRoutingRejectsWrongOwner() async throws {
        let (runtime, root) = try fixture()
        let socket = await runtime.socket
        defer {
            _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: root)
        }
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let binding = try await runtime.create(spec)
        await expectThrowsAsync(LaunchError.self) { try await runtime.applicationCapturesMouse(SessionBinding(spec: spec)) }
        expectTrue(try await runtime.applicationCapturesMouse(binding) == false)
        expectTrue(try await runtime.inspect(binding)?.dead == false)
    }

    func testNullBytesRejected() throws {
        expectThrows(LaunchError.self) {
            try LaunchSpec(tool: .shell, executable: "/bin/cat", arguments: ["a\0b"], directory: "/tmp")
        }
    }

    func testLiteralArgumentsAndDirectory() async throws {
        let (runtime, root) = try fixture()
        let directory = root.appendingPathComponent("folder with spaces 日本語")
        try PrivateFiles.directory(directory)
        let output = directory.appendingPathComponent("observed.json")
        let marker = root.appendingPathComponent("SHOULD-NOT-EXIST")
        let literal = "quoted '\"\n$HOME $(touch \(marker.path)) `touch \(marker.path)` --flag"
        let script = "import json,os,sys;json.dump([os.getcwd(),sys.argv[2]],open(sys.argv[1],'w'))"
        let spec = try LaunchSpec(tool: .shell, executable: "/usr/bin/python3",
                                  arguments: ["-c", script, output.path, literal], directory: directory.path)
        let binding = try await runtime.create(spec)
        do {
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: output.path) {
                try await Task.sleep(for: .milliseconds(50))
            }
            let values = try JSONDecoder().decode([String].self, from: Data(contentsOf: output))
            expectTrue(values[0].replacingOccurrences(of: "/private/tmp/", with: "/tmp/") == directory.path)
            expectTrue(values[1] == literal)
            expectTrue(!FileManager.default.fileExists(atPath: marker.path))
            expectTrue(!FileManager.default.fileExists(atPath: root.appendingPathComponent("request-" + binding.id.uuidString + ".json").path))
            let receipt = try String(contentsOf: root.appendingPathComponent(binding.id.uuidString + ".json"), encoding: .utf8)
            expectTrue(!receipt.contains("SHOULD-NOT-EXIST"))
        } catch {
            try? await runtime.terminate(binding)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        try await runtime.terminate(binding)
        try FileManager.default.removeItem(at: root)
    }

    func testRetryAndAttachmentDoNotDuplicate() async throws {
        let (runtime, root) = try fixture()
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let binding = try await runtime.create(spec)
        do {
            let before = try requireValue(await runtime.inspect(binding))
            let again = try await runtime.create(spec)
            _ = try await runtime.attachmentArguments(binding)
            let after = try requireValue(await runtime.inspect(again))
            expectTrue(before.processID == after.processID)
            expectTrue(try await runtime.list().count == 1)
            expectTrue(!before.dead)
        } catch {
            try? await runtime.terminate(binding)
            throw error
        }
        try await runtime.terminate(binding)
        expectTrue(try await runtime.inspect(binding) == nil)
        expectTrue(try await runtime.list().isEmpty)
        try FileManager.default.removeItem(at: root)
    }

    func testMissingTargetWithAnotherSessionAliveIsAbsent() async throws {
        let (runtime, root) = try fixture()
        let socket = await runtime.socket
        defer {
            _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: root)
        }
        let live = try await runtime.create(LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp"))
        let before = try requireValue(await runtime.inspect(live))
        let absent = SessionBinding(spec: try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp"))
        expectTrue(try await runtime.inspect(absent) == nil)
        expectTrue(try await runtime.inspect(live)?.processID == before.processID)
        try await runtime.terminate(live)
    }

    func testUncertainLaunchDoesNotRestart() async throws {
        let (runtime, root) = try fixture()
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let binding = SessionBinding(spec: spec, phase: .starting)
        try PrivateFiles.write(binding, to: root.appendingPathComponent(binding.id.uuidString + ".json"))
        await expectThrowsAsync(LaunchError.self) { try await runtime.create(spec) }
        expectTrue(try await runtime.inspect(binding) == nil)
        try FileManager.default.removeItem(at: root)
    }

    func testConcurrentRequestsShareOneProcess() async throws {
        let (runtime, root) = try fixture()
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let first = Task { try await runtime.create(spec) }
        let second = Task { try await runtime.create(spec) }
        let a = try? await first.value
        let b = try? await second.value
        let binding = try requireValue(a ?? b)
        expectTrue(try await runtime.list().count == 1)
        expectTrue(try await runtime.inspect(binding)?.dead == false)
        if let a, let b { expectTrue(a.id == b.id) }
        try await runtime.terminate(binding)
        try FileManager.default.removeItem(at: root)
    }

    func testWrongOwnerCannotTerminate() async throws {
        let (runtime, root) = try fixture()
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let binding = try await runtime.create(spec)
        let impostor = SessionBinding(spec: spec)
        await expectThrowsAsync(LaunchError.self) { try await runtime.terminate(impostor) }
        expectTrue(try await runtime.inspect(binding)?.dead == false)
        try await runtime.terminate(binding)
        try FileManager.default.removeItem(at: root)
    }

    func testRetainsExitStatusAndRestore() async throws {
        let (runtime, root) = try fixture()
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/sh", arguments: ["-c", "exit 7"], directory: "/tmp")
        let binding = try await runtime.create(spec)
        for _ in 0..<30 {
            if try await runtime.inspect(binding)?.dead == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let restored = try TmuxRuntime(executable: PackagedRuntime.tmux(),
                                       helper: TestExecutables.launchHelper(bundle: Bundle(for: Self.self)), root: root)
        expectTrue(try await restored.list().map(\.id) == [binding.id])
        let observation = try requireValue(await restored.inspect(binding))
        expectTrue(observation.dead)
        expectTrue(observation.exitCode == 7)
        let same = try await restored.create(spec)
        expectTrue(same.id == binding.id)
        expectTrue(try await restored.inspect(same)?.dead == true)
        try await restored.terminate(binding)
        try FileManager.default.removeItem(at: root)
    }

    func testMissingExecutableCanBeCorrectedBeforeStart() async throws {
        let (runtime, root) = try fixture()
        let id = UUID()
        let missing = try LaunchSpec(operationID: id, tool: .shell, executable: "/missing/spookky-test", directory: "/tmp")
        await expectThrowsAsync(LaunchError.self) { try await runtime.create(missing) }
        let corrected = try LaunchSpec(operationID: id, tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let binding = try await runtime.create(corrected)
        expectTrue(try await runtime.inspect(binding)?.dead == false)
        try await runtime.terminate(binding)
        try FileManager.default.removeItem(at: root)
    }
}
