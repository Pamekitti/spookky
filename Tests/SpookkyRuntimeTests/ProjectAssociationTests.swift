import XCTest
import SpookkyCore
import SpookkyGit
import SpookkyRuntime
import SpookkyWorkspace

private actor ProjectFixtureConnection: CodexProjectConnection {
    let projects: [[String: String]]
    let cwd: String
    let returnedID: String
    var projectID: String?
    var writes = 0
    var unsupported = false
    init(projects: [[String: String]], cwd: String, id: String = "fixture-session", assigned: String? = nil, unsupported: Bool = false) {
        self.projects = projects; self.cwd = cwd; returnedID = id; projectID = assigned; self.unsupported = unsupported
    }
    func request(_ method: String, params: Data) throws -> Data {
        if unsupported { throw CodexProjectError.unsupported }
        var result: [String: Any]
        switch method {
        case "project/list":
            result = ["data": projects.map { ["id": $0["id"]!, "roots": [["path": $0["path"]!]]] }]
        case "thread/read":
            var thread: [String: Any] = ["id": returnedID, "cwd": cwd]
            if let projectID { thread["projectId"] = projectID }
            result = ["thread": thread]
        case "thread/metadata/update":
            let values = try JSONSerialization.jsonObject(with: params) as! [String: String]
            XCTAssertEqual(Set(values.keys), ["projectId", "threadId"])
            projectID = values["projectId"]; writes += 1; result = [:]
        default: throw CodexProjectError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: result)
    }
}

final class ProjectAssociationTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-association-" + UUID().uuidString)
        try PrivateFiles.directory(root)
        return root
    }
    private func git(_ root: URL, _ arguments: [String]) throws {
        let result = try ProcessRunner.run("/usr/bin/git", ["-C", root.path] + arguments)
        XCTAssertEqual(result.status, 0, result.error)
    }
    private func repository(_ root: URL, _ name: String) throws -> URL {
        let repo = root.appendingPathComponent(name)
        try PrivateFiles.directory(repo)
        try git(repo, ["init", "-b", "main"])
        try git(repo, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"])
        return repo
    }
    func testRootAndSiblingWorktreesKeepCheckoutAndSubdirectory() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try repository(root, "original"), one = root.appendingPathComponent("generated-one"), two = root.appendingPathComponent("generated-two")
        try git(repo, ["worktree", "add", "-b", "one", one.path]); try git(repo, ["worktree", "add", "-b", "two", two.path])
        let sub = two.appendingPathComponent("src/café"); try PrivateFiles.directory(sub)
        let original = try await LocationDiscovery.discover(repo)
        var state = WorkspaceState(); let id = state.registerProject(original)
        let resolver = ProjectAssociationResolver()
        for cwd in [repo, one, sub] {
            let result = await resolver.resolve(directory: cwd.path, projects: state.projects, preferredProjectID: id)
            XCTAssertEqual(result.projectID, id); XCTAssertEqual(result.projectRoot, original.path)
            XCTAssertEqual(result.key, original.projectAssociationKey)
            XCTAssertEqual(result.location?.path, cwd.resolvingSymlinksInPath().path)
            XCTAssertEqual(result.status, .matched)
            let launch = try LaunchSpec(tool: .codex, executable: "/fixture/codex", directory: result.location!.path)
            XCTAssertEqual(launch.directory, cwd.resolvingSymlinksInPath().path)
        }
        let discovered = try await LocationDiscovery.discover(one)
        XCTAssertEqual(state.registerProject(discovered), id); XCTAssertEqual(state.projects.count, 1)
        XCTAssertNotEqual(discovered.checkoutIdentity, original.checkoutIdentity)
        let alias = root.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sub)
        let aliased = await resolver.resolve(directory: alias.path, projects: state.projects)
        XCTAssertEqual(aliased.location?.path, sub.resolvingSymlinksInPath().path); XCTAssertEqual(aliased.projectID, id)
    }
    func testSameNamesRemotesPlainFoldersAndDuplicatesStayDistinct() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let one = try repository(root, "a/repo"), two = try repository(root, "b/repo")
        try git(one, ["remote", "add", "origin", "https://example.invalid/repo"])
        try git(two, ["remote", "add", "origin", "https://example.invalid/repo"])
        let first = try await LocationDiscovery.discover(one), second = try await LocationDiscovery.discover(two)
        let plainA = root.appendingPathComponent("c/repo"), plainB = root.appendingPathComponent("d/repo")
        try PrivateFiles.directory(plainA); try PrivateFiles.directory(plainB)
        var state = WorkspaceState(); let firstID = state.registerProject(first), secondID = state.registerProject(second)
        XCTAssertNotEqual(firstID, secondID)
        let a = try await LocationDiscovery.discover(plainA), b = try await LocationDiscovery.discover(plainB)
        XCTAssertNotEqual(state.registerProject(a), state.registerProject(b)); XCTAssertEqual(state.projects.count, 4)
        let duplicate = Project(name: "same name", location: first)
        let resolver = ProjectAssociationResolver(), projects = state.projects + [duplicate]
        let ambiguous = await resolver.resolve(directory: one.path, projects: projects)
        XCTAssertEqual(ambiguous.status, .ambiguous)
        let selected = await resolver.resolve(directory: one.path, projects: projects, preferredProjectID: duplicate.id)
        XCTAssertEqual(selected.projectID, duplicate.id)
        let unrelatedPreference = await resolver.resolve(directory: two.path, projects: state.projects, preferredProjectID: firstID)
        XCTAssertEqual(unrelatedPreference.status, .unavailable); XCTAssertNil(unrelatedPreference.projectID)
    }
    func testMovedAndMissingWorktreesNeedFreshDiscovery() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try repository(root, "repo"), old = root.appendingPathComponent("old"), moved = root.appendingPathComponent("moved")
        try git(repo, ["worktree", "add", "-b", "topic", old.path])
        let original = try await LocationDiscovery.discover(repo), previous = try await LocationDiscovery.discover(old)
        let project = Project(name: "repo", location: original)
        try git(repo, ["worktree", "move", old.path, moved.path])
        let resolver = ProjectAssociationResolver()
        let missing = await resolver.resolve(directory: old.path, projects: [project]); XCTAssertEqual(missing.status, .unavailable)
        let fresh = await resolver.resolve(directory: moved.path, projects: [project]); XCTAssertEqual(fresh.projectID, project.id)
        XCTAssertEqual(fresh.location?.checkoutIdentity, previous.checkoutIdentity)
        let staleProject = Project(name: "old", location: previous)
        let stale = await resolver.resolve(directory: moved.path, projects: [staleProject]); XCTAssertEqual(stale.status, .unregistered)
    }
    func testProviderAssociationUsesExistingIDAndExactCheckout() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try repository(root, "repo"), worktree = root.appendingPathComponent("generated")
        try git(repo, ["worktree", "add", "-b", "topic", worktree.path])
        let original = try await LocationDiscovery.discover(repo), project = Project(name: "repo", location: original)
        let resolution = await ProjectAssociationResolver().resolve(directory: worktree.path, projects: [project])
        let api = ProjectFixtureConnection(projects: [["id": "provider-project", "path": repo.path]], cwd: worktree.resolvingSymlinksInPath().path)
        let client = CodexProjectClient()
        let result = await client.associate(sessionID: "fixture-session", resolution: resolution, connection: api)
        XCTAssertEqual(result.status, .associated); XCTAssertEqual(result.projectID, "provider-project")
        let writes = await api.writes; XCTAssertEqual(writes, 1)
        let again = await client.associate(sessionID: "fixture-session", resolution: resolution, connection: api)
        XCTAssertEqual(again.status, .associated)
        let duplicateWrites = await api.writes; XCTAssertEqual(duplicateWrites, 1)
        for (cwd, assigned, expected) in [(repo.resolvingSymlinksInPath().path, Optional<String>.none, ProviderProjectAssociation.Status.unavailable),
                                          (worktree.resolvingSymlinksInPath().path, "user-chosen-project", .ambiguous)] {
            let other = ProjectFixtureConnection(projects: [["id": "provider-project", "path": repo.path]], cwd: cwd, assigned: assigned)
            let rejected = await client.associate(sessionID: "fixture-session", resolution: resolution, connection: other)
            XCTAssertEqual(rejected.status, expected); let writes = await other.writes; XCTAssertEqual(writes, 0)
        }
    }
    func testUnsupportedMissingAndDuplicateProviderProjectsDoNotWrite() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let location = try await LocationDiscovery.discover(root), project = Project(name: "folder", location: location)
        let resolution = await ProjectAssociationResolver().resolve(directory: root.path, projects: [project])
        for (projects, unsupported, status) in [([], false, ProviderProjectAssociation.Status.unregistered),
            ([["id": "a", "path": root.path], ["id": "b", "path": root.path]], false, .ambiguous), ([], true, .unsupported)] {
            let api = ProjectFixtureConnection(projects: projects, cwd: root.path, unsupported: unsupported)
            let result = await CodexProjectClient().associate(sessionID: "fixture-session", resolution: resolution, connection: api)
            XCTAssertEqual(result.status, status); let writes = await api.writes; XCTAssertEqual(writes, 0)
        }
    }
    func testChangedOwnerStopsProviderProjectWrite() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let location = try await LocationDiscovery.discover(root)
        let resolution = await ProjectAssociationResolver().resolve(directory: root.path, projects: [Project(name: "Fixture", location: location)])
        let api = ProjectFixtureConnection(projects: [["id": "provider-project", "path": root.path]], cwd: location.path)
        actor Owner {
            var checks = 0
            func current() -> Bool { checks += 1; return checks == 1 }
        }
        let owner = Owner()
        let result = await CodexProjectClient().associate(sessionID: "fixture-session", resolution: resolution,
            connection: api, isCurrent: { await owner.current() })
        XCTAssertEqual(result.status, .unavailable)
        let writes = await api.writes; XCTAssertEqual(writes, 0)
    }
    @MainActor func testResumeRemoteAndShellLaunchesAreExcluded() throws {
        for args in [["resume", "id"], ["fork", "id"], ["--remote", "unix://"], ["--remote=unix://"], ["--worktree"]] {
            let launch = try LaunchSpec(tool: .codex, executable: "/fixture/codex", arguments: args, directory: "/tmp")
            XCTAssertNil(ProjectAssociationCoordinator.freshExecutable(launch))
        }
        let wrapped = try LaunchSpec(tool: .codex, executable: "/fixture/helper", arguments: ["--agent-run", "codex", "--executable", "/fixture/codex", "--", "--", "resume is prompt text"], directory: "/tmp")
        XCTAssertEqual(ProjectAssociationCoordinator.freshExecutable(wrapped), "/fixture/codex")
        let shell = try LaunchSpec(tool: .shell, executable: "/bin/zsh", directory: "/tmp")
        XCTAssertNil(ProjectAssociationCoordinator.freshExecutable(shell))
    }
    func testLateAssociationCannotOverwriteAnotherInvocation() throws {
        var state = WorkspaceState(); let workspaceID = state.newWorkspace(directory: "/tmp")
        let tabID = state.selectedTab!.id, invocation = UUID()
        let spec = try LaunchSpec(tool: .codex, executable: "/fixture/codex", directory: "/tmp")
        state.apply(.preparing, to: tabID); state.apply(.intent(spec, .none), to: tabID)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: tabID)
        let event = AgentEvent(bindingID: spec.operationID, invocationID: invocation, secret: UUID(), provider: .codex,
                               kind: .working, sessionID: "new-session")
        _ = state.recordAgentEvent(event)
        let stale = ProviderProjectAssociation(sessionID: "old-session", status: .associated, message: "Fixture")
        state.recordProjectAssociation(stale, workspaceID: workspaceID, primaryTerminalID: tabID, invocationID: invocation, operationID: spec.operationID)
        XCTAssertNil(state.tab(tabID)?.projectAssociation)
        let current = ProviderProjectAssociation(sessionID: "new-session", status: .associated, message: "Fixture")
        state.recordProjectAssociation(current, workspaceID: workspaceID, primaryTerminalID: tabID, invocationID: UUID(), operationID: spec.operationID)
        XCTAssertNil(state.tab(tabID)?.projectAssociation)
        state.recordProjectAssociation(current, workspaceID: workspaceID, primaryTerminalID: tabID, invocationID: invocation, operationID: spec.operationID)
        XCTAssertEqual(state.tab(tabID)?.projectAssociation, current)
        XCTAssertEqual(state.workspace(containing: tabID)?.currentProjectAssociation, current)
        let replacement = AgentEvent(bindingID: spec.operationID, invocationID: UUID(), secret: UUID(), provider: .codex,
                                     kind: .working, sessionID: "replacement-session")
        _ = state.recordAgentEvent(replacement)
        XCTAssertNil(state.workspace(containing: tabID)?.currentProjectAssociation)
        XCTAssertEqual(state.selectedWorkspaceID, workspaceID)
    }
    func testProjectRPCUsesAPICapabilitiesWithoutInspectingVersionStrings() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let server = root.appendingPathComponent("server.py"), executable = root.appendingPathComponent("codex")
        try """
        import json, sys
        for line in sys.stdin:
            row = json.loads(line)
            if "id" not in row:
                continue
            response = {"id": row["id"], "result": {"data": []}}
            print(json.dumps(response), flush=True)
        """.write(to: server, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        if [ "$1" != app-server ]; then
          touch "$(dirname "$0")/unexpected-version-check"
          exit 1
        fi
        exec /usr/bin/python3 -u "$(dirname "$0")/server.py"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let rpc = try CodexProjectRPC(executable: executable.path)
        let data = try await rpc.request("project/list", params: Data("{}".utf8))
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((page["data"] as? [String])?.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected-version-check").path))
        await rpc.close()
    }
    func testProjectRPCReportsMissingNativeMethodsAsUnsupported() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        try """
        #!/usr/bin/python3
        import json, sys
        for line in sys.stdin:
            row = json.loads(line)
            if "id" not in row:
                continue
            if row.get("method") == "initialize":
                response = {"id": row["id"], "result": {}}
            else:
                response = {"id": row["id"], "error": {"code": -32601, "message": "Method unavailable"}}
            print(json.dumps(response), flush=True)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for method in ["project/list", "thread/metadata/update"] {
            let rpc = try CodexProjectRPC(executable: executable.path)
            do {
                _ = try await rpc.request(method, params: Data("{}".utf8))
                XCTFail("A missing project capability must remain unavailable")
            } catch CodexProjectError.unsupported { }
            await rpc.close()
        }
    }
    func testLegacyMetadataDecodesWithoutProviderAssociation() throws {
        let tab = WorkspaceTab(); let data = try JSONEncoder().encode(tab)
        XCTAssertNil(try JSONDecoder().decode(WorkspaceTab.self, from: data).projectAssociation)
    }
    func testInstalledProviderProjectAssociationWhenRequested() async throws {
        guard let executable = ProcessInfo.processInfo.environment["SPOOKKY_CODEX_PROJECT_FIXTURE_EXECUTABLE"] else {
            throw XCTSkip("Set SPOOKKY_CODEX_PROJECT_FIXTURE_EXECUTABLE to test disposable installed-provider state.")
        }
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try repository(root, "repo"), worktree = root.appendingPathComponent("generated")
        try git(repo, ["worktree", "add", "-b", "topic", worktree.path])
        let home = root.appendingPathComponent("home"), state = root.appendingPathComponent("provider")
        try PrivateFiles.directory(home); try PrivateFiles.directory(state)
        let env = ["HOME": home.path, "CODEX_HOME": state.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        let rpc = try CodexProjectRPC(executable: executable, environment: env)
        func request(_ method: String, _ values: [String: String]) async throws -> [String: Any] {
            let response = try await rpc.request(method, params: JSONSerialization.data(withJSONObject: values))
            return try JSONSerialization.jsonObject(with: response) as! [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["idempotencyKey": "fixture", "name": "Fixture", "roots": [["path": repo.path]]])
        let created = try await rpc.request("project/create", params: data)
        let projectID = ((try JSONSerialization.jsonObject(with: created) as! [String: Any])["project"] as! [String: Any])["id"] as! String
        let location = try await LocationDiscovery.discover(worktree)
        let started = try await request("thread/start", ["cwd": location.path, "model": "fixture-model", "modelProvider": "openai", "historyMode": "paginated"])
        let sessionID = (started["thread"] as! [String: Any])["id"] as! String
        _ = try await request("thread/shellCommand", ["threadId": sessionID, "command": ":"])
        let original = try await LocationDiscovery.discover(repo)
        let resolution = await ProjectAssociationResolver().resolve(directory: location.path, projects: [Project(name: "Fixture", location: original)])
        var result = await CodexProjectClient().associate(sessionID: sessionID, resolution: resolution, connection: rpc)
        for _ in 0..<10 where result.status != .associated {
            try await Task.sleep(for: .milliseconds(100))
            result = await CodexProjectClient().associate(sessionID: sessionID, resolution: resolution, connection: rpc)
        }
        XCTAssertEqual(result.status, .associated); XCTAssertEqual(result.projectID, projectID)
        await rpc.close()
        let reopened = try CodexProjectRPC(executable: executable, environment: env)
        let read = try await reopened.request("thread/read", params: JSONSerialization.data(withJSONObject: ["threadId": sessionID, "includeTurns": false]))
        let persisted = (try JSONSerialization.jsonObject(with: read) as! [String: Any])["thread"] as! [String: Any]
        XCTAssertEqual(persisted["projectId"] as? String, projectID)
        XCTAssertEqual(URL(fileURLWithPath: persisted["cwd"] as! String).standardizedFileURL.resolvingSymlinksInPath().path, location.path)
        await reopened.close()
    }

}
