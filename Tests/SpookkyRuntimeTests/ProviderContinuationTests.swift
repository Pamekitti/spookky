import XCTest
import SpookkyCore
import SpookkyRuntime
import SpookkyWorkspace

final class ProviderContinuationTests: XCTestCase {
    private let id = "11111111-1111-4111-8111-111111111111"
    private var codex: ProviderContinuationCapabilities {
        .init(provider: .codex, version: "codex-cli 0.162.1", help: "app", resumeHelp: "[SESSION_ID] --cd", remoteHelp: "start pair")
    }
    private var claude: ProviderContinuationCapabilities {
        .init(provider: .claude, version: "2.1.296 (Claude Code)", help: "--desktop --resume --remote-control")
    }
    func testExactResumeDoesNotForkOrSupplyInitialPrompt() throws {
        let folder = "/tmp/fixture folder/日本語; $(false)"
        let first = try codex.resumeSpec(sessionID: id, originalDirectory: folder, executable: "/tmp/codex")
        XCTAssertEqual(first.arguments, ["resume", id, "--cd", folder])
        XCTAssertEqual(first.directory, folder)
        let second = try claude.resumeSpec(sessionID: id, originalDirectory: folder, executable: "/tmp/claude")
        XCTAssertEqual(second.arguments, ["--resume", id])
        XCTAssertEqual(second.directory, folder)
        XCTAssertEqual(second.environment, [:])
    }
    func testClaudeDesktopUsesExactIDAndCodexNeverOpensAnUnrelatedProject() throws {
        let spec = try claude.desktopSpec(sessionID: id, originalDirectory: "/tmp/original checkout", executable: "/tmp/claude")
        XCTAssertEqual(spec.arguments, ["--desktop", "--resume", id])
        XCTAssertEqual(spec.directory, "/tmp/original checkout")
        XCTAssertThrowsError(try codex.desktopSpec(sessionID: id, originalDirectory: "/tmp", executable: "/tmp/codex"))
        XCTAssertThrowsError(try claude.desktopSpec(sessionID: "--last", originalDirectory: "/tmp", executable: "/tmp/claude"))
    }
    func testInvalidOrNamedIDsAndMissingCapabilitiesFailClosed() {
        for value in ["", "--last", "friendly name", id + "\0"] {
            XCTAssertThrowsError(try codex.resumeSpec(sessionID: value, originalDirectory: "/tmp", executable: "/tmp/codex"))
            XCTAssertThrowsError(try claude.guide(sessionID: value, directory: "/tmp"))
        }
        for version in ["", "development build", "0.100.0", "900.1.0"] {
            let supported = ProviderContinuationCapabilities(provider: .codex, version: version, help: "app", resumeHelp: "[SESSION_ID] --cd", remoteHelp: "start pair")
            XCTAssertEqual(supported.desktopCommand, "/app")
            XCTAssertEqual(supported.remoteCommand, "codex remote-control")
            XCTAssertTrue(supported.exactResume)
            let missing = ProviderContinuationCapabilities(provider: .codex, version: version, help: "")
            XCTAssertFalse(missing.exactResume)
            XCTAssertNil(missing.desktopCommand)
            XCTAssertNil(missing.remoteCommand)
        }
        XCTAssertThrowsError(try codex.resumeSpec(sessionID: id, originalDirectory: "relative", executable: "/tmp/codex"))
        XCTAssertThrowsError(try codex.resumeSpec(sessionID: id, originalDirectory: "/tmp\0", executable: "/tmp/codex"))
    }
    func testExitedManualAgentDoesNotOfferProviderCommandsInAnOrdinaryShell() throws {
        var tab = WorkspaceTab()
        tab.binding = SessionBinding(spec: try LaunchSpec(tool: .shell, executable: "/bin/zsh", directory: "/tmp"))
        tab.activity = AgentActivity(invocationID: UUID(), provider: .claude)
        XCTAssertEqual(ProviderContinuationCapabilities.provider(for: tab), .claude)
        tab.activity?.disconnect()
        XCTAssertNil(ProviderContinuationCapabilities.provider(for: tab))
        tab.binding = SessionBinding(spec: try LaunchSpec(tool: .codex, executable: "/tmp/codex", directory: "/tmp"))
        XCTAssertEqual(ProviderContinuationCapabilities.provider(for: tab), .codex)
        tab.binding = nil
        XCTAssertNil(ProviderContinuationCapabilities.provider(for: tab))
    }
    func testAbsentFlagsDisableOnlyTheirRoute() {
        let partial = ProviderContinuationCapabilities(provider: .claude, version: "2.1.296", help: "--resume")
        XCTAssertTrue(partial.exactResume)
        XCTAssertNil(partial.desktopCommand)
        XCTAssertNil(partial.remoteCommand)
        XCTAssertNil(ProviderContinuationCapabilities(provider: .shell, version: "2.1.296", help: "--resume --desktop").desktopCommand)
    }
    func testProbeDoesNotLaunchOrDisableKnownResumeWhenRemoteHelpFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-continuation-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        try """
        #!/bin/sh
        case "$*" in
          --version) echo 'codex-cli 0.162.1';;
          --help) echo 'app';;
          'resume --help') echo '[SESSION_ID] --cd';;
          'remote-control --help') exit 1;;
          *) touch "$(dirname "$0")/unexpected-launch"; exit 1;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let spec = try LaunchSpec(tool: .codex, executable: executable.path, directory: root.path)
        let capability = try await ProviderContinuationCapabilities.inspect(spec)
        XCTAssertTrue(capability.exactResume)
        XCTAssertEqual(capability.desktopCommand, "/app")
        XCTAssertNil(capability.remoteCommand)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-launch").path))
    }
    func testCodexRemoteDoesNotClaimSelectedThreadTransferOrRelease() throws {
        let guide = try codex.guide(directory: "/tmp")
        XCTAssertEqual(codex.desktopCommand, "/app")
        XCTAssertTrue(guide.remote.contains("does not transfer the selected conversation"))
        XCTAssertTrue(guide.remote.contains("host awake and reachable"))
        XCTAssertTrue(guide.desktop.contains("terminal exit does not prove"))
        XCTAssertTrue(guide.returnToTerminal.contains("never starts an agent"))
    }
    func testAdvertisedCodexDirectoryFlagIsUsedWithoutRequiringItForBasicResume() throws {
        for (help, expected) in [("[SESSION_ID] -C", ["resume", id, "-C", "/tmp"]),
                                 ("[SESSION_ID]", ["resume", id])] {
            let capability = ProviderContinuationCapabilities(provider: .codex, version: "old", help: "", resumeHelp: help)
            XCTAssertTrue(capability.exactResume)
            let spec = try capability.resumeSpec(sessionID: id, originalDirectory: "/tmp", executable: "/tmp/codex")
            XCTAssertEqual(spec.arguments, expected)
            XCTAssertEqual(spec.directory, "/tmp")
        }
        XCTAssertFalse(ProviderContinuationCapabilities(provider: .claude, version: "new", help: "--resume-copy --desktop-copy").exactResume)
    }
    func testCapabilitiesCacheUntilExecutableVersionOrIdentityChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-capability-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex"), version = root.appendingPathComponent("version")
        try "old".write(to: version, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        base=$(dirname "$0")
        case "$*" in
          --version) cat "$base/version";;
          --help) echo help >> "$base/probes"; echo 'app';;
          'resume --help') echo '[SESSION_ID] --cd';;
          'remote-control --help') exit 1;;
          *) exit 1;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let base = try LaunchSpec(tool: .codex, executable: executable.path, directory: root.path)
        _ = try await ProviderContinuationCapabilities.inspect(base)
        _ = try await ProviderContinuationCapabilities.inspect(base)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("probes"), encoding: .utf8).split(separator: "\n").count, 1)
        try "new".write(to: version, atomically: true, encoding: .utf8)
        let updated = try await ProviderContinuationCapabilities.inspect(base)
        XCTAssertEqual(updated.version, "new")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("probes"), encoding: .utf8).split(separator: "\n").count, 2)
        var script = try String(contentsOf: executable, encoding: .utf8)
        script = script.replacingOccurrences(of: "[SESSION_ID] --cd", with: "no exact session interface")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let replaced = try await ProviderContinuationCapabilities.inspect(base)
        XCTAssertFalse(replaced.exactResume)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("probes"), encoding: .utf8).split(separator: "\n").count, 3)
    }

}
