import XCTest
import SpookkyCore
import SpookkyRuntime
import SpookkyWorkspace

private struct CaptureResolver: ExecutableResolver {
    let executable: String
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try LaunchSpec(tool: tool, executable: executable, directory: directory,
            initialPrompt: tool == .shell ? nil : prompt)
    }
}

@MainActor final class PromptCaptureTests: XCTestCase {
    func testBothProviderPromptPathsReachOwnedProcessAsLiteralArguments() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-m1-prompt-" + UUID().uuidString.prefix(8))
        try PrivateFiles.directory(root)
        let executable = root.appendingPathComponent("capture")
        try "#!/bin/zsh -f\n/usr/bin/printf '%s\\0' \"$@\" >> received\n/usr/bin/touch finished\nexec /bin/cat\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let runtime = try TmuxRuntime(executable: PackagedRuntime.tmux(),
            helper: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/spookky-launch").path,
            root: root.appendingPathComponent("rt"))
        let socket = await runtime.socket
        defer { _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"]); try? FileManager.default.removeItem(at: root) }
        for tool in [SessionTool.codex, .claude] {
            for prompt in ["", "café's 日本語\n$(touch MUST_NOT_EXIST) --option"] {
                let folder = root.appendingPathComponent(UUID().uuidString)
                try PrivateFiles.directory(folder)
                let store = WorkspaceStore()
                store.update { $0.newWorkspace(directory: folder.path) }
                let id = try XCTUnwrap(store.state.selectedTab?.id)
                store.update { $0.editDraft(id, tool: tool, prompt: prompt) }
                let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: CaptureResolver(executable: executable.path))
                await coordinator.launch(id)
                let binding = try XCTUnwrap(store.state.tab(id)?.binding)
                let received = folder.appendingPathComponent("received")
                for _ in 0..<100 {
                    if FileManager.default.fileExists(atPath: folder.appendingPathComponent("finished").path) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let bytes = try Data(contentsOf: received)
                let expected = prompt.isEmpty ? Data([0]) : Data(("--\0" + prompt + "\0").utf8)
                XCTAssertEqual(bytes, expected)
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("MUST_NOT_EXIST").path))
                let before = try await runtime.inspect(binding)
                await coordinator.reconcile(id); await coordinator.launch(id)
                let after = try await runtime.inspect(binding)
                XCTAssertEqual(before?.processID, after?.processID)
                XCTAssertEqual(try Data(contentsOf: received), bytes)
                try await runtime.terminate(binding)
            }
        }
    }
}
