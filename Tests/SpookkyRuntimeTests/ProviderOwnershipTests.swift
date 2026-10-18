import XCTest
import SpookkyCore
import SpookkyWorkspace
@testable import SpookkyRuntime

final class ProviderOwnershipTests: XCTestCase {
    private let target = "11111111-1111-4111-8111-111111111111"
    private let other = "22222222-2222-4222-8222-222222222222"

    func testClaudeExactConversationOwnsTheBlockNotOtherProviderProcesses() throws {
        let rows = """
        [{"kind":"interactive","sessionId":"\(other)","pid":20},
         {"kind":"interactive","sessionId":"\(target)","pid":30}]
        """
        let result = ProviderOwnershipCheck.claudeAssessment(json: Data(rows.utf8), sessionID: target)
        XCTAssertEqual(result.route, .interactiveOwner(processIDs: [30]))
        XCTAssertFalse(result.canContinue)
    }
    func testClaudeAbsenceUsesOrdinaryResumeWithoutClaimingExclusiveOwnership() {
        for rows in ["[]", "[{\"kind\":\"interactive\",\"sessionId\":\"\(other)\",\"pid\":20}]",
                     "[{\"kind\":\"interactive\",\"pid\":20}]"] {
            let result = ProviderOwnershipCheck.claudeAssessment(json: Data(rows.utf8), sessionID: target)
            XCTAssertEqual(result.route, .providerArbitrated)
            XCTAssertTrue(result.canInvokeNativeResume)
            XCTAssertTrue(result.explanation.contains("does not establish exclusive"))
        }
    }
    func testClaudeMultipleForegroundClientsRemainExplicit() {
        let rows = """
        [{"kind":"interactive","sessionId":"\(target)","pid":40},
         {"kind":"interactive","sessionId":"\(target)","pid":30}]
        """
        XCTAssertEqual(ProviderOwnershipCheck.claudeAssessment(json: Data(rows.utf8), sessionID: target).route,
                       .interactiveOwner(processIDs: [30, 40]))
    }
    func testLiveBackgroundOwnerUsesItsRegistryIDWithoutConvertingResumeIntoBackgroundLaunch() throws {
        let rows = "[{\"kind\":\"background\",\"sessionId\":\"\(target)\",\"id\":\"agent-123\",\"state\":\"blocked\"}]"
        let assessment = ProviderOwnershipCheck.claudeAssessment(json: Data(rows.utf8), sessionID: target)
        XCTAssertEqual(assessment.route, .backgroundOwner)
        XCTAssertFalse(assessment.canInvokeNativeResume)
        XCTAssertTrue(assessment.canContinue)
        let capability = ProviderContinuationCapabilities(provider: .claude, version: "future", help: "--resume attach agents",
            agentsHelp: "--json", attachHelp: "Usage: claude attach <id|name>")
        let base = try LaunchSpec(tool: .claude, executable: "/tmp/claude", directory: "/tmp/original checkout")
        let launch = try assessment.continuationSpec(capabilities: capability, sessionID: target, executable: base)
        XCTAssertEqual(launch.arguments, ["attach", "agent-123"])
        XCTAssertEqual(launch.directory, base.directory)
        XCTAssertEqual(launch.environment, [:])
    }
    func testKnownBackgroundOwnerRequiresAnUnambiguousSupportedAttachID() {
        for rows in [
            "[{\"kind\":\"background\",\"sessionId\":\"\(target)\",\"state\":\"blocked\"}]",
            "[{\"kind\":\"background\",\"sessionId\":\"\(target)\",\"id\":\"--help\",\"state\":\"blocked\"}]",
            "[{\"kind\":\"background\",\"sessionId\":\"\(target)\",\"id\":\"a\",\"state\":\"working\"},{\"kind\":\"background\",\"sessionId\":\"\(target)\",\"id\":\"b\",\"state\":\"working\"}]"
        ] {
            let result = ProviderOwnershipCheck.claudeAssessment(json: Data(rows.utf8), sessionID: target)
            XCTAssertEqual(result.route, .backgroundOwner)
            XCTAssertFalse(result.canContinue)
        }
        let rows = "[{\"kind\":\"background\",\"sessionId\":\"\(target)\",\"id\":\"a\",\"state\":\"stopped\"}]"
        XCTAssertEqual(ProviderOwnershipCheck.claudeAssessment(json: Data(rows.utf8), sessionID: target).route, .providerArbitrated)
    }
    func testUnavailableOwnershipMetadataUsesNativeResumeButInvalidSessionIDsNeverLaunch() {
        for rows in ["{}", "[{\"kind\":\"interactive\",\"sessionId\":\"\(target)\",\"pid\":999999999999}]", "not JSON"] {
            XCTAssertTrue(ProviderOwnershipCheck.claudeAssessment(json: Data(rows.utf8), sessionID: target).canInvokeNativeResume)
        }
        XCTAssertEqual(ProviderOwnershipCheck.claudeAssessment(json: Data("[]".utf8), sessionID: target + "\0").route, .unknown)
    }
    func testSupportedResumeDoesNotDependOnVersionOrRemoteControl() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-owner-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        try """
        #!/bin/sh
        case "$*" in
          --version) echo 'codex-cli development';;
          --help) echo 'app';;
          'resume --help') echo '[SESSION_ID] --cd';;
          'remote-control --help') exit 1;;
          *) touch "$(dirname "$0")/unexpected-launch"; exit 1;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let spec = try LaunchSpec(tool: .codex, executable: executable.path, directory: root.path)
        let supported = await ProviderOwnershipCheck.assess(spec, sessionID: target)
        XCTAssertEqual(supported.route, .providerArbitrated)
        XCTAssertTrue(supported.canInvokeNativeResume)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-launch").path))
    }
    func testClaudeFailedOrUnavailableOwnershipProbeKeepsOrdinaryResumeAvailable() async throws {
        let base = try LaunchSpec(tool: .claude, executable: "/nonexistent/claude", directory: "/tmp")
        for agentsHelp in ["", "--json"] {
            let capability = ProviderContinuationCapabilities(provider: .claude, version: "unknown", help: "--resume", agentsHelp: agentsHelp)
            let assessment = await ProviderOwnershipCheck.assess(base, sessionID: target, capabilities: capability)
            XCTAssertTrue(assessment.canInvokeNativeResume)
            XCTAssertEqual(try assessment.continuationSpec(capabilities: capability, sessionID: target, executable: base).arguments,
                           ["--resume", target])
        }
    }
    func testPreparedClaudeDecisionUsesNativeBackgroundAttachWithoutLaunchingAnything() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-attach-decision-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        try """
        #!/bin/sh
        case "$*" in
          --version) exit 1;;
          --help) echo '--resume agents attach';;
          'agents --help') echo '--json';;
          'attach --help') echo 'Usage: claude attach <id|name>';;
          'agents --json') echo '[{"kind":"background","id":"agent-42","sessionId":"\(target)","state":"working"}]';;
          *) touch "$(dirname "$0")/unexpected-launch"; exit 1;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let resolver = FixedProviderResolver(executable: executable.path)
        let conversation = ConversationMetadata(id: ConversationID(provider: .claude, sessionID: target), title: nil,
            directory: root.path, updatedAt: Date())
        let decision = try await ConversationExecutionCheck.prepare(conversation, resolver: resolver)
        XCTAssertEqual(decision.assessment.nativeAttachID, "agent-42")
        XCTAssertEqual(decision.launch.arguments, ["attach", "agent-42"])
        XCTAssertEqual(decision.launch.directory, root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-launch").path))
    }
    func testUnsafeAttachIdentifiersCannotBecomeArguments() throws {
        let capability = ProviderContinuationCapabilities(provider: .claude, version: "", help: "--resume", attachHelp: "attach <id>")
        for id in ["--help", "a\n", "a b", "a\0", "../a", ""] {
            XCTAssertThrowsError(try capability.attachSpec(attachID: id, originalDirectory: "/tmp", executable: "/tmp/claude"))
        }
    }

}

private struct FixedProviderResolver: ExecutableResolver {
    let executable: String
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try LaunchSpec(tool: tool, executable: executable, directory: directory)
    }
}
