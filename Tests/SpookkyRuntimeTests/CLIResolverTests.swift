import Foundation
import XCTest
import SpookkyCore
import SpookkyRuntime
@testable import SpookkyWorkspace

private struct CLIFixture {
    let root: URL
    let home: URL

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/spookky-cli-" + UUID().uuidString.prefix(8))
        home = root.appendingPathComponent("Home's café 日本語")
        try PrivateFiles.directory(home)
        try profile("export PATH=/usr/bin:/bin\n")
    }

    func profile(_ text: String) throws {
        try text.write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
    }

    func executable(_ relativePath: String, text: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try PrivateFiles.directory(url.deletingLastPathComponent())
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func resolver(path: String = "/usr/bin:/bin") -> CLIResolver {
        CLIResolver(environment: ["PATH": path, "HOME": home.path, "ZDOTDIR": home.path],
                    homeDirectory: home, standardDirectories: ["/usr/bin", "/bin"])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor LookupRuntime: SessionRuntime {
    private var creates = 0
    func count() -> Int { creates }
    func create(_ spec: LaunchSpec) async throws -> SessionBinding { creates += 1; return SessionBinding(spec: spec, phase: .attachedRuntime) }
    func inspect(_ binding: SessionBinding) async throws -> SessionObservation? { nil }
    func list() async throws -> [SessionBinding] { [] }
    func attachmentArguments(_ binding: SessionBinding) async throws -> [String] { [] }
    func terminate(_ binding: SessionBinding) async throws {}
}

final class CLIResolverTests: XCTestCase {
    func testInheritedExecutableWinsWithoutRunningStartupFiles() async throws {
        let fixture = try CLIFixture(); defer { fixture.remove() }
        let executable = try fixture.executable("selected/bin/codex")
        _ = try fixture.executable(".local/bin/codex")
        try fixture.profile("/usr/bin/touch \"$HOME/startup-ran\"\nexit 1\n")
        let bin = executable.deletingLastPathComponent().path
        let spec = try await fixture.resolver(path: bin + ":" + bin + ":/usr/bin:/bin").resolve(.codex, directory: fixture.home.path, prompt: nil)
        XCTAssertEqual(spec.executable, executable.path)
        XCTAssertEqual(spec.environment["PATH"]?.components(separatedBy: ":").filter { $0 == bin }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("startup-ran").path))
    }

    func testLoginPathSurvivesStartupOutputAndUnusualDirectoryNames() async throws {
        let fixture = try CLIFixture(); defer { fixture.remove() }
        let executable = try fixture.executable("custom/bin/codex")
        try fixture.profile("printf 'Startup message\\n'\nexport PATH=\"$HOME/custom/bin:/usr/bin:/bin\"\n")
        let draft = "café's 日本語\n$(touch SHOULD_NOT_EXIST) --option"
        let spec = try await fixture.resolver().resolve(.codex, directory: fixture.home.path, prompt: draft)
        XCTAssertEqual(spec.executable, executable.path)
        XCTAssertEqual(spec.arguments, ["--", draft])
        XCTAssertEqual(spec.directory, fixture.home.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    func testNativeClaudeInstallationAndShellFallback() async throws {
        let fixture = try CLIFixture(); defer { fixture.remove() }
        let target = try fixture.executable(".local/share/claude/versions/fixture")
        let link = fixture.home.appendingPathComponent(".local/bin/claude")
        try PrivateFiles.directory(link.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let resolver = fixture.resolver()
        let spec = try await resolver.resolve(.claude, directory: fixture.home.path, prompt: nil)
        XCTAssertEqual(spec.executable, link.path)
        let shell = try await resolver.resolve(.shell, directory: fixture.home.path, prompt: "Never send to shell")
        XCTAssertEqual(shell.executable, "/bin/zsh")
        XCTAssertEqual(shell.arguments, ["-l"])
    }

    func testNvmSymlinkKeepsAdjacentNodeAndLiteralPromptThroughRuntime() async throws {
        let fixture = try CLIFixture(); defer { fixture.remove() }
        try fixture.profile("exit 3\n")
        _ = try fixture.executable(".nvm/versions/node/v22.9.0/bin/codex")
        let version = ".nvm/versions/node/v22.22.0"
        let target = try fixture.executable(version + "/lib/node_modules/codex/bin/codex.js", text: "#!/usr/bin/env node\n")
        _ = try fixture.executable(version + "/bin/node", text: "#!/bin/sh\n/usr/bin/printf '%s\\0' \"$@\" > received\n/usr/bin/touch finished\nexec /bin/cat\n")
        let link = fixture.home.appendingPathComponent(version + "/bin/codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let draft = "Literal ' café 日本語\n$(touch SHOULD_NOT_EXIST) --flag"
        let spec = try await fixture.resolver().resolve(.codex, directory: fixture.home.path, prompt: draft)
        XCTAssertEqual(spec.executable, link.path)
        XCTAssertEqual(spec.environment["PATH"]?.components(separatedBy: ":").first, link.deletingLastPathComponent().path)
        let runtime = try TmuxRuntime(executable: PackagedRuntime.tmux(),
            helper: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/spookky-launch").path,
            root: fixture.root.appendingPathComponent("runtime"))
        let socket = await runtime.socket
        defer { _ = try? ProcessRunner.run(PackagedRuntime.tmux(), ["-S", socket, "kill-server"]) }
        let binding = try await runtime.create(spec)
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("finished").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let expected = Data((link.path + "\0--\0" + draft + "\0").utf8)
        XCTAssertEqual(try Data(contentsOf: fixture.home.appendingPathComponent("received")), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("SHOULD_NOT_EXIST").path))
        try await runtime.terminate(binding)
    }

    @MainActor func testMissingExecutableRetainsDraftUntilExplicitRetry() async throws {
        let fixture = try CLIFixture(); defer { fixture.remove() }
        try PrivateFiles.directory(fixture.home.appendingPathComponent(".local/bin/codex"))
        let store = WorkspaceStore(), runtime = LookupRuntime()
        store.update { $0.newWorkspace(directory: fixture.home.path) }
        let id = try XCTUnwrap(store.state.selectedTab?.id)
        let draft = "Retain café 日本語\nsecond line"
        store.update { $0.editDraft(id, tool: .codex, prompt: draft) }
        let coordinator = LaunchCoordinator(store: store, runtime: runtime, resolver: fixture.resolver())
        await coordinator.launch(id)
        let before = await runtime.count()
        XCTAssertEqual(before, 0)
        XCTAssertEqual(store.state.tab(id)?.status, .failed)
        XCTAssertNil(store.state.tab(id)?.launch)
        XCTAssertEqual(store.state.tab(id)?.draft.prompt, draft)
        _ = try fixture.executable(".nvm/versions/node/v22.22.0/bin/codex")
        XCTAssertEqual(store.state.tab(id)?.status, .failed)
        await coordinator.launch(id)
        let after = await runtime.count()
        XCTAssertEqual(after, 1)
        XCTAssertEqual(store.state.tab(id)?.status, .running)
        XCTAssertEqual(store.state.tab(id)?.launch?.arguments, ["--", draft])
    }
}
