import XCTest
import SpookkyCore
import SpookkyRuntime
@testable import SpookkyWorkspace

private struct IdentityFixtureResolver: ExecutableResolver {
    let executable: String
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try LaunchSpec(tool: tool, executable: executable, directory: directory,
                       environment: ["PATH": "/usr/bin:/bin"], initialPrompt: prompt)
    }
}

final class ProviderIdentityTests: XCTestCase, @unchecked Sendable {
    func testFreshClaudeIdentityDoesNotAffectResumeResolution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s\\n' '--session-id <uuid>'\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let resolver = AgentActivityResolver(base: IdentityFixtureResolver(executable: cli.path), root: root, helper: "/usr/bin/true")
        let prompt = "Keep $(literal) input"
        let fresh = try await resolver.resolveFresh(.claude, directory: root.path, prompt: prompt)
        let id = try XCTUnwrap(fresh.environment["SPOOKKY_PROVIDER_SESSION_ID"])
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertTrue(fresh.arguments.contains("--session-id"))
        XCTAssertEqual(fresh.arguments.filter { $0 == prompt }.count, 1)
        let resume = try await resolver.resolve(.claude, directory: root.path, prompt: nil)
        XCTAssertFalse(resume.arguments.contains("--session-id"))
        XCTAssertNil(resume.environment["SPOOKKY_PROVIDER_SESSION_ID"])
        try "#!/bin/sh\necho unsupported\n".write(to: cli, atomically: true, encoding: .utf8)
        let unsupported = try await resolver.resolveFresh(.claude, directory: root.path, prompt: nil)
        XCTAssertNil(unsupported.environment["SPOOKKY_PROVIDER_SESSION_ID"])
        XCTAssertFalse(unsupported.arguments.contains("--session-id"))
    }

    func testCodexNotificationOverrideIsValidTomlAndKeepsTheExistingCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("codex")
        let script = """
        #!/usr/bin/python3
        import json,sys
        for line in sys.stdin:
            request=json.loads(line)
            result={} if request['method']=='initialize' else {'config':{'notify':['/usr/bin/true','preserve literal']}}
            if 'id' in request:
                print(json.dumps({'id':request['id'],'result':result}),flush=True)
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let resolver = AgentActivityResolver(base: IdentityFixtureResolver(executable: cli.path), root: root, helper: "/usr/bin/true")
        let spec = try await resolver.resolveFresh(.codex, directory: root.path, prompt: nil)
        let argument = try XCTUnwrap(spec.arguments.first { $0.hasPrefix("notify=") })
        XCTAssertFalse(argument.contains("\\/"), "JSON slash escapes are not TOML escapes")
        let command = try JSONDecoder().decode([String].self, from: Data(argument.dropFirst(7).utf8))
        XCTAssertEqual(Array(command.prefix(2)), ["/usr/bin/true", "--agent-identity"])
        let original = try JSONDecoder().decode([String].self, from: XCTUnwrap(Data(base64Encoded: command[3])))
        XCTAssertEqual(original, ["/usr/bin/true", "preserve literal"])
    }

    func testReceiptNeverRetainsPromptOrNotificationText() throws {
        let context = AgentTerminalContext(bindingID: UUID(), root: "/tmp/identity-fixture", helper: "/usr/bin/true")
        let ids = (0..<12).map { _ in UUID().uuidString }
        let receipt = ProviderIdentityReceipt(context: context, candidates: ["not-an-id"] + ids)
        XCTAssertEqual(receipt.candidates, Array(ids.suffix(8)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["bindingID", "secret", "candidates"])
    }
}
