import XCTest
import SpookkyCore
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
        XCTAssertFalse(result.canInvokeNativeResume)
    }
    func testClaudeAbsenceCannotProveReleaseOrWinAnOwnershipRace() {
        for rows in ["[]", "[{\"kind\":\"interactive\",\"sessionId\":\"\(other)\",\"pid\":20}]",
                     "[{\"kind\":\"interactive\",\"pid\":20}]"] {
            let result = ProviderOwnershipCheck.claudeAssessment(json: Data(rows.utf8), sessionID: target)
            XCTAssertEqual(result.route, .unknown)
            XCTAssertFalse(result.canInvokeNativeResume)
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
    func testBackgroundLogicalOwnerDoesNotBecomeFreeWhenPIDIsAbsent() {
        let rows = "[{\"kind\":\"background\",\"sessionId\":\"\(target)\",\"state\":\"blocked\"}]"
        XCTAssertEqual(ProviderOwnershipCheck.claudeAssessment(json: Data(rows.utf8), sessionID: target).route, .backgroundOwner)
        let ended = "[{\"kind\":\"background\",\"sessionId\":\"\(target)\",\"state\":\"stopped\"}]"
        XCTAssertEqual(ProviderOwnershipCheck.claudeAssessment(json: Data(ended.utf8), sessionID: target).route, .unknown)
    }
    func testMalformedOrInvalidIDsNeverAuthorizeResume() {
        for rows in ["{}", "[{\"kind\":\"interactive\",\"sessionId\":\"\(target)\",\"pid\":999999999999}]", "not JSON"] {
            XCTAssertFalse(ProviderOwnershipCheck.claudeAssessment(json: Data(rows.utf8), sessionID: target).canInvokeNativeResume)
        }
        XCTAssertEqual(ProviderOwnershipCheck.claudeAssessment(json: Data("[]".utf8), sessionID: target + "\0").route, .unknown)
    }
    func testOnlyVerifiedCodexBuildUsesProviderArbitration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-owner-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        func script(_ version: String) throws {
            try """
            #!/bin/sh
            case "$*" in
              --version) echo '\(version)';;
              'resume --help') echo '[SESSION_ID] --remote --cd';;
              *) touch "$(dirname "$0")/unexpected-launch"; exit 1;;
            esac
            """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let spec = try LaunchSpec(tool: .codex, executable: executable.path, directory: root.path)
        try script("codex-cli 0.162.1")
        let supported = await ProviderOwnershipCheck.assess(spec, sessionID: target)
        XCTAssertEqual(supported.route, .providerArbitrated)
        XCTAssertTrue(supported.canInvokeNativeResume)
        try script("codex-cli 0.163.0")
        let unsupported = await ProviderOwnershipCheck.assess(spec, sessionID: target)
        XCTAssertEqual(unsupported.route, .unknown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-launch").path))
    }
}
