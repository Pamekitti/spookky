import XCTest
import Darwin
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

    func testIdentityFolderAliasesPreserveSelectedSubdirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-alias-" + UUID().uuidString)
        let target = root.appendingPathComponent("real folder/child")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target.deletingLastPathComponent())
        let aliases = await HistoryQuery.folderAliases(link.appendingPathComponent("child").path)
        XCTAssertTrue(aliases.contains(link.appendingPathComponent("child").path))
        let canonical = try XCTUnwrap(realpath(target.path, nil)); defer { free(canonical) }
        XCTAssertTrue(aliases.contains(String(cString: canonical)))
        XCTAssertFalse(aliases.contains(target.deletingLastPathComponent().path))
    }

    func testCodexIdentityConfirmsOnlyTheExactCliCandidateInItsFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-codex-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString, hidden = UUID().uuidString
        let rows: [[String: Any]] = [
            ["id": id, "cwd": root.resolvingSymlinksInPath().path, "source": "cli", "updatedAt": 100, "name": "Native title"],
            ["id": hidden, "cwd": root.resolvingSymlinksInPath().path, "source": "exec", "updatedAt": 101]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["data": rows])
        let encoded = data.base64EncodedString()
        let cli = root.appendingPathComponent("codex")
        let script = """
        #!/usr/bin/python3
        import json,sys,base64
        for line in sys.stdin:
            request=json.loads(line)
            if 'id' in request:
                result={} if request['method']=='initialize' else json.loads(base64.b64decode('\(encoded)'))
                print(json.dumps({'id':request['id'],'result':result}),flush=True)
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let resolver = IdentityFixtureResolver(executable: cli.path)
        let metadata = await ProviderIdentityResolver.codex(candidates: [hidden, id], directory: root.path, resolver: resolver)
        XCTAssertEqual(metadata?.id.sessionID, id)
        let other = await ProviderIdentityResolver.codex(candidates: [id], directory: "/another/folder", resolver: resolver)
        XCTAssertNil(other)
    }

    func testInstalledCodexIdentityFromDisposableSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let id = environment["SPOOKKY_IDENTITY_TEST_SESSION"],
              let directory = environment["SPOOKKY_IDENTITY_TEST_DIRECTORY"] else {
            throw XCTSkip("Opt in with a disposable saved Codex session")
        }
        let metadata = await ProviderIdentityResolver.codex(candidates: [id], directory: directory)
        XCTAssertEqual(metadata?.id.sessionID, id)
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
