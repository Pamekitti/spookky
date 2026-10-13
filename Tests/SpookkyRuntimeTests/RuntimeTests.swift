import Foundation
import Testing
import SpookkyCore
import SpookkyRuntime

@Suite(.serialized) struct RuntimeTests {
    private func fixture() throws -> (TmuxRuntime, URL) {
        let root = URL(fileURLWithPath: "/tmp/spookky-test-" + UUID().uuidString.prefix(8))
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/spookky-launch").path
        return (try TmuxRuntime(executable: PackagedRuntime.tmux(), helper: helper, root: root), root)
    }

    @Test func shellRejectsAgentPrompt() throws {
        #expect(throws: LaunchError.self) {
            try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp", initialPrompt: "Do something")
        }
    }

    @Test func mouseRoutingPreservesApplicationInputAndNativeHistorySelection() async throws {
        let (runtime, root) = try fixture()
        let socket = await runtime.socket
        defer {
            _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: root)
        }
        let shell = try await runtime.create(LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp"))
        #expect(try await runtime.applicationCapturesMouse(shell) == false)
        let app = try await runtime.create(LaunchSpec(tool: .shell, executable: "/bin/sh",
            arguments: ["-c", "printf '\\033[?1002h\\033[?1006h'; exec /bin/cat"], directory: "/tmp"))
        for _ in 0..<20 {
            if try await runtime.applicationCapturesMouse(app) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await runtime.applicationCapturesMouse(app))
        let entered = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "copy-mode", "-t", "=" + app.name + ":0.0"])
        #expect(entered.status == 0)
        #expect(try await runtime.applicationCapturesMouse(app) == false)
        let cancelled = try ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "send-keys", "-t", "=" + app.name + ":0.0", "-X", "cancel"])
        #expect(cancelled.status == 0)
        #expect(try await runtime.applicationCapturesMouse(app))
        #expect(try await runtime.inspect(shell)?.dead == false)
        #expect(try await runtime.inspect(app)?.dead == false)
    }

    @Test func mouseRoutingRejectsWrongOwner() async throws {
        let (runtime, root) = try fixture()
        let socket = await runtime.socket
        defer {
            _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: root)
        }
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let binding = try await runtime.create(spec)
        await #expect(throws: LaunchError.self) { try await runtime.applicationCapturesMouse(SessionBinding(spec: spec)) }
        #expect(try await runtime.applicationCapturesMouse(binding) == false)
        #expect(try await runtime.inspect(binding)?.dead == false)
    }

    @Test func nullBytesRejected() throws {
        #expect(throws: LaunchError.self) {
            try LaunchSpec(tool: .shell, executable: "/bin/cat", arguments: ["a\0b"], directory: "/tmp")
        }
    }

    @Test func literalArgumentsAndDirectory() async throws {
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
            #expect(values[0].replacingOccurrences(of: "/private/tmp/", with: "/tmp/") == directory.path)
            #expect(values[1] == literal)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("request-" + binding.id.uuidString + ".json").path))
            let receipt = try String(contentsOf: root.appendingPathComponent(binding.id.uuidString + ".json"), encoding: .utf8)
            #expect(!receipt.contains("SHOULD-NOT-EXIST"))
        } catch {
            try? await runtime.terminate(binding)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        try await runtime.terminate(binding)
        try FileManager.default.removeItem(at: root)
    }

    @Test func retryAndAttachmentDoNotDuplicate() async throws {
        let (runtime, root) = try fixture()
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let binding = try await runtime.create(spec)
        do {
            let before = try #require(await runtime.inspect(binding))
            let again = try await runtime.create(spec)
            _ = try await runtime.attachmentArguments(binding)
            let after = try #require(await runtime.inspect(again))
            #expect(before.processID == after.processID)
            #expect(try await runtime.list().count == 1)
            #expect(!before.dead)
        } catch {
            try? await runtime.terminate(binding)
            throw error
        }
        try await runtime.terminate(binding)
        #expect(try await runtime.inspect(binding) == nil)
        #expect(try await runtime.list().isEmpty)
        try FileManager.default.removeItem(at: root)
    }

    @Test func missingTargetWithAnotherSessionAliveIsAbsent() async throws {
        let (runtime, root) = try fixture()
        let socket = await runtime.socket
        defer {
            _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: root)
        }
        let live = try await runtime.create(LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp"))
        let before = try #require(await runtime.inspect(live))
        let absent = SessionBinding(spec: try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp"))
        #expect(try await runtime.inspect(absent) == nil)
        #expect(try await runtime.inspect(live)?.processID == before.processID)
        try await runtime.terminate(live)
    }

    @Test func uncertainLaunchDoesNotRestart() async throws {
        let (runtime, root) = try fixture()
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let binding = SessionBinding(spec: spec, phase: .starting)
        try PrivateFiles.write(binding, to: root.appendingPathComponent(binding.id.uuidString + ".json"))
        await #expect(throws: LaunchError.self) { try await runtime.create(spec) }
        #expect(try await runtime.inspect(binding) == nil)
        try FileManager.default.removeItem(at: root)
    }

    @Test func concurrentRequestsShareOneProcess() async throws {
        let (runtime, root) = try fixture()
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let first = Task { try await runtime.create(spec) }
        let second = Task { try await runtime.create(spec) }
        let a = try? await first.value
        let b = try? await second.value
        let binding = try #require(a ?? b)
        #expect(try await runtime.list().count == 1)
        #expect(try await runtime.inspect(binding)?.dead == false)
        if let a, let b { #expect(a.id == b.id) }
        try await runtime.terminate(binding)
        try FileManager.default.removeItem(at: root)
    }

    @Test func wrongOwnerCannotTerminate() async throws {
        let (runtime, root) = try fixture()
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let binding = try await runtime.create(spec)
        let impostor = SessionBinding(spec: spec)
        await #expect(throws: LaunchError.self) { try await runtime.terminate(impostor) }
        #expect(try await runtime.inspect(binding)?.dead == false)
        try await runtime.terminate(binding)
        try FileManager.default.removeItem(at: root)
    }

    @Test func retainsExitStatusAndRestore() async throws {
        let (runtime, root) = try fixture()
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/sh", arguments: ["-c", "exit 7"], directory: "/tmp")
        let binding = try await runtime.create(spec)
        for _ in 0..<30 {
            if try await runtime.inspect(binding)?.dead == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let restored = try TmuxRuntime(executable: PackagedRuntime.tmux(),
                                       helper: FileManager.default.currentDirectoryPath + "/.build/debug/spookky-launch", root: root)
        #expect(try await restored.list().map(\.id) == [binding.id])
        let observation = try #require(await restored.inspect(binding))
        #expect(observation.dead)
        #expect(observation.exitCode == 7)
        let same = try await restored.create(spec)
        #expect(same.id == binding.id)
        #expect(try await restored.inspect(same)?.dead == true)
        try await restored.terminate(binding)
        try FileManager.default.removeItem(at: root)
    }

    @Test func missingExecutableCanBeCorrectedBeforeStart() async throws {
        let (runtime, root) = try fixture()
        let id = UUID()
        let missing = try LaunchSpec(operationID: id, tool: .shell, executable: "/missing/spookky-test", directory: "/tmp")
        await #expect(throws: LaunchError.self) { try await runtime.create(missing) }
        let corrected = try LaunchSpec(operationID: id, tool: .shell, executable: "/bin/cat", directory: "/tmp")
        let binding = try await runtime.create(corrected)
        #expect(try await runtime.inspect(binding)?.dead == false)
        try await runtime.terminate(binding)
        try FileManager.default.removeItem(at: root)
    }
}
