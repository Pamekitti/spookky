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

final class InstalledProjectAssociationTests: XCTestCase {
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
