import XCTest
import Darwin
import SpookkyCore
@testable import SpookkyRuntime
import SpookkyWorkspace
import SpookkyPersistence
import GRDB

final class AgentActivityTests: XCTestCase {
    private let binding = UUID(), runID = UUID(), secret = UUID()
    private func event(_ kind: AgentEventKind, session: String? = "parent", child: String? = nil) -> AgentEvent {
        AgentEvent(bindingID: binding, invocationID: runID, secret: secret, provider: .codex, kind: kind, sessionID: session, childID: child)
    }
    func testCompletionAndAcknowledgmentAreSeparateFromInput() throws {
        var activity = AgentActivity(invocationID: runID, provider: .codex)
        activity.apply(event(.unsupported)); XCTAssertEqual(activity.displayState, .unknown); XCTAssertFalse(activity.attached)
        activity.apply(event(.attached)); XCTAssertEqual(activity.displayState, .idle)
        activity.apply(event(.working)); XCTAssertEqual(activity.displayState, .working)
        activity.apply(event(.needsInput)); activity.acknowledge()
        XCTAssertEqual(activity.displayState, .needsInput); XCTAssertTrue(activity.needsAttention)
        activity.apply(event(.working)); activity.apply(event(.finished))
        XCTAssertTrue(activity.unread); XCTAssertEqual(activity.displayState, .finished)
        let completion = activity.completionID
        activity.apply(event(.finished)); XCTAssertEqual(activity.completionID, completion)
        activity.acknowledge(); XCTAssertEqual(activity.displayState, .idle)
        activity.apply(event(.failed)); activity.acknowledge(); XCTAssertEqual(activity.displayState, .failed)
        activity.reset(); XCTAssertEqual(activity.displayState, .unknown)
    }
    func testChildrenCannotFinishOrRelabelParent() throws {
        var activity = AgentActivity(invocationID: runID, provider: .codex)
        activity.apply(event(.working))
        activity.apply(event(.childStarted, session: "child-thread", child: "child-1"))
        XCTAssertEqual(activity.children.count, 1); XCTAssertEqual(activity.sessionID, "parent")
        XCTAssertEqual(activity.state, .working)
        activity.apply(event(.childEnded, session: "child-thread", child: "child-1"))
        XCTAssertTrue(activity.children.isEmpty); XCTAssertFalse(activity.unread)
        for index in 0..<80 { activity.apply(event(.childStarted, child: String(index))) }
        XCTAssertEqual(activity.children.count, 64)
        let restored = try JSONDecoder().decode(AgentActivity.self, from: JSONEncoder().encode(activity))
        XCTAssertTrue(restored.children.isEmpty)
    }
    func testStaleDuplicateAndForeignEventsAreRejected() {
        var activity = AgentActivity(invocationID: runID, provider: .codex)
        let working = event(.working)
        XCTAssertTrue(activity.apply(working)); XCTAssertFalse(activity.apply(working))
        var old = event(.finished); old.occurredAt = working.occurredAt - 1
        XCTAssertFalse(activity.apply(old))
        XCTAssertFalse(activity.apply(event(.finished, session: "foreign")))
        let foreign = AgentEvent(bindingID: binding, invocationID: UUID(), secret: secret, provider: .codex, kind: .finished)
        XCTAssertFalse(activity.apply(foreign)); XCTAssertEqual(activity.state, .working)
    }
    func testRestorationRetainsUnreadWithoutInventingActivity() {
        var activity = AgentActivity(invocationID: runID, provider: .codex)
        activity.apply(event(.finished)); activity.restore()
        XCTAssertEqual(activity.state, .unknown); XCTAssertTrue(activity.unread)
        activity.acknowledge(); XCTAssertFalse(activity.needsAttention)
    }
    func testHookNormalizationFiltersToolsAndKeepsFailuresDistinct() throws {
        func decode(_ raw: [String: Any], provider: SessionTool = .claude) throws -> AgentEvent? {
            AgentHookPayload.event(data: try JSONSerialization.data(withJSONObject: raw), provider: provider,
                                   bindingID: binding, invocationID: runID, secret: secret)
        }
        XCTAssertNil(try decode(["hook_event_name": "PreToolUse", "tool_name": "Bash"]))
        XCTAssertNil(try decode(["hook_event_name": "Notification", "notification_type": "idle_prompt"]))
        XCTAssertEqual(try decode(["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion"])?.kind, .needsInput)
        XCTAssertEqual(try decode(["hook_event_name": "PermissionRequest"])?.kind, .needsInput)
        XCTAssertEqual(try decode(["hook_event_name": "PostToolUseFailure"])?.kind, .working)
        XCTAssertEqual(try decode(["hook_event_name": "StopFailure"])?.kind, .failed)
        XCTAssertEqual(try decode(["hook_event_name": "Interrupt"])?.kind, .interrupted)
        let child = try decode(["hook_event_name": "Stop", "session_id": "child", "agent_id": "c"])
        XCTAssertEqual(child?.kind, .childEnded)
        let preview = try decode(["hook_event_name": "Stop", "last_assistant_message": "\u{001B}[31m" + String(repeating: "hello\n", count: 100)])?.preview
        XCTAssertEqual(preview?.count, 180); XCTAssertFalse(preview?.contains("\u{001B}") ?? true)
        XCTAssertNil(AgentHookPayload.event(data: Data(repeating: 32, count: 1_048_577), provider: .claude, bindingID: binding, invocationID: runID, secret: secret))
    }
    func testLaunchArgumentsPreservePromptAndProviderTrust() throws {
        let context = AgentTerminalContext(bindingID: binding, root: "/tmp/odd ' folder 日本語", helper: "/tmp/Spookky App's/helper")
        let invocation = AgentInvocation(context: context, provider: .codex)
        let prompt = "$(touch /tmp/should-never-run) `date`\n--dangerously-bypass-hook-trust"
        let original = ["--", prompt]
        let arguments = try AgentIntegration.hookArguments(provider: .codex, invocation: invocation, original: original)
        XCTAssertEqual(Array(arguments.suffix(2)), original)
        XCTAssertFalse(arguments.contains("--dangerously-bypass-hook-trust"))
        let nextInvocation = AgentInvocation(context: context, provider: .codex)
        XCTAssertEqual(try AgentIntegration.hookArguments(provider: .codex, invocation: nextInvocation, original: original), arguments)
        let repeated = try AgentIntegration.hookArguments(provider: .codex, invocation: invocation, original: ["--dangerously-bypass-hook-trust"] + original)
        XCTAssertEqual(repeated.filter { $0 == "--dangerously-bypass-hook-trust" }.count, 1)
        XCTAssertFalse(arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        let claude = try AgentIntegration.hookArguments(provider: .claude, invocation: AgentInvocation(context: context, provider: .claude), original: original)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(claude[1].utf8)) as? [String: Any])
        XCTAssertNotNil(json["hooks"]); XCTAssertNil(json["permissions"])
        XCTAssertEqual(Array(claude.suffix(2)), original)
    }
    func testDisabledHooksAndPromptBoundary() {
        XCTAssertTrue(AgentIntegration.hooksDisabled(provider: .codex, arguments: ["--disable", "hooks"]))
        XCTAssertTrue(AgentIntegration.hooksDisabled(provider: .claude, arguments: ["--bare"]))
        XCTAssertFalse(AgentIntegration.hooksDisabled(provider: .codex, arguments: ["--", "--disable", "hooks"]))
    }
    func testPrimaryActivityIgnoresSupportingTerminalsAndNewInvocationKeepsUnreadWork() throws {
        var state = WorkspaceState()
        state.newWorkspace(directory: "/tmp")
        var ids: [UUID] = []
        for index in 0..<3 {
            if index > 0 { state.newTab() }
            let id = try XCTUnwrap(state.selectedTab?.id)
            let spec = try LaunchSpec(operationID: id, tool: .shell, executable: "/bin/zsh", directory: "/tmp")
            state.apply(.preparing, to: id)
            state.apply(.intent(spec, .none), to: id)
            state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: id)
            let kind: AgentEventKind = [.working, .needsInput, .finished][index]
            XCTAssertEqual(state.recordAgentEvent(AgentEvent(bindingID: id, invocationID: UUID(), secret: secret, provider: .codex, kind: kind)), id)
            ids.append(id)
        }
        XCTAssertEqual(state.selected?.activityState, .working)
        XCTAssertFalse(state.selected?.needsAttention == true)
        state.acknowledgeAgent(ids[1]); XCTAssertEqual(state.selected?.activityState, .working)
        state.resetAgent(ids[1]); XCTAssertEqual(state.selected?.activityState, .working)
        let next = AgentEvent(bindingID: ids[2], invocationID: UUID(), secret: secret, provider: .claude, kind: .attached)
        XCTAssertEqual(state.recordAgentEvent(next), ids[2])
        XCTAssertTrue(state.tab(ids[2])?.activity?.unread == true)
        XCTAssertEqual(state.tab(ids[2])?.activity?.provider, .claude)
        XCTAssertNil(state.recordAgentEvent(event(.finished)))
        state.closeTab(ids[2]); XCTAssertFalse(state.selected?.needsAttention == true)
    }
    func testMonitoringAndPreviewPreferencesPreserveUnreadCompletions() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let id = try XCTUnwrap(state.selectedTab?.id)
        let spec = try LaunchSpec(operationID: binding, tool: .codex, executable: "/bin/true", directory: "/tmp")
        state.apply(.preparing, to: id)
        state.apply(.intent(spec, .none), to: id)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: id)
        var completion = event(.finished); completion.preview = "Private completion"
        state.recordAgentEvent(completion)
        state.suspendAgentMonitoring(.codex); state.clearAgentPreviews()
        let activity = try XCTUnwrap(state.tab(id)?.activity)
        XCTAssertEqual(activity.state, .unknown); XCTAssertFalse(activity.attached)
        XCTAssertTrue(activity.unread); XCTAssertNil(activity.preview)
        state.acknowledgeAgent(id); XCTAssertFalse(state.selected?.needsAttention == true)
    }
    func testProcessExitKeepsLateCompletionButRejectsLateWorkingState() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let id = try XCTUnwrap(state.selectedTab?.id)
        let spec = try LaunchSpec(operationID: binding, tool: .codex, executable: "/bin/true", directory: "/tmp")
        state.apply(.preparing, to: id); state.apply(.intent(spec, .none), to: id)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: nil), to: id)
        state.recordAgentEvent(event(.working))
        state.apply(.observed(SessionBinding(spec: spec), dead: true, exitCode: 0, prompt: nil), to: id)
        XCTAssertEqual(state.tab(id)?.activity?.state, .unknown)
        XCTAssertNil(state.recordAgentEvent(event(.working)))
        XCTAssertEqual(state.recordAgentEvent(event(.finished)), id)
        XCTAssertEqual(state.tab(id)?.status, .ended)
        XCTAssertEqual(state.tab(id)?.activity?.displayState, .finished)
        XCTAssertTrue(state.tab(id)?.activity?.unread == true)
        XCTAssertFalse(state.tab(id)?.activity?.attached == true)
    }
    func testZshStartupPreservesUserConfigurationAndRestoresWrapperPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-shell-" + UUID().uuidString)
        try PrivateFiles.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user's dot files 日本語")
        try PrivateFiles.directory(user)
        for (name, marker) in [(".zshenv", "e"), (".zprofile", "p"), (".zshrc", "r"), (".zlogin", "l")] {
            let script = "export SPOOKKY_FIXTURE_STARTUP=\"${SPOOKKY_FIXTURE_STARTUP:-}\(marker)\"\nexport PATH=/usr/bin:/bin\n"
            try script.write(to: user.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let spec = try LaunchSpec(tool: .shell, executable: "/bin/zsh", arguments: ["-l"], directory: root.path,
                                  environment: ["ZDOTDIR": user.path, "PATH": "/usr/bin:/bin"])
        let prepared = try AgentIntegration.prepare(spec, root: root, helper: "/bin/true")
        let result = try ProcessRunner.run("/bin/zsh", ["-l", "-i", "-c", "builtin printf '%s\\n' \"$SPOOKKY_FIXTURE_STARTUP\" \"$ZDOTDIR\"; whence -p codex; whence -p claude"], environment: prepared.environment)
        XCTAssertEqual(result.status, 0, result.error)
        let output = result.output.components(separatedBy: .newlines)
        XCTAssertEqual(Array(output.prefix(2)), ["eprl", user.path])
        XCTAssertEqual(Array(output.dropFirst(2).prefix(2)), ["codex", "claude"].map { root.appendingPathComponent("agent-bin/" + $0).path })
        XCTAssertFalse(try String(contentsOf: user.appendingPathComponent(".zshrc"), encoding: .utf8).contains("spookky"))
        let plain = try AgentIntegration.prepare(LaunchSpec(tool: .shell, executable: "/bin/zsh", arguments: ["-f"], directory: root.path), root: root, helper: "/bin/true")
        XCTAssertNil(plain.environment["ZDOTDIR"])
    }
    func testReceiverValidatesActiveInvocationAndOwnership() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-agent-" + UUID().uuidString.prefix(8))
        try PrivateFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AgentTerminalContext(bindingID: binding, secret: secret, root: root.path, helper: "/bin/true")
        let current = AgentInvocation(context: context, provider: .codex)
        try PrivateFiles.write(current, to: URL(fileURLWithPath: context.activePath))
        let accepted = expectation(description: "Only the current registration is accepted")
        accepted.assertForOverFulfill = true
        let receiver = try AgentActivityReceiver(root: root) { received in
            XCTAssertEqual(received.invocationID, current.id); accepted.fulfill()
        }
        XCTAssertThrowsError(try AgentActivityReceiver(root: root) { _ in })
        AgentActivitySocket.send(event(.finished), socket: context.socket)
        var wrong = current.event(.finished)
        wrong = AgentEvent(bindingID: binding, invocationID: current.id, secret: UUID(), provider: .codex, kind: .finished)
        AgentActivitySocket.send(wrong, socket: context.socket)
        AgentActivitySocket.send(current.event(.working), socket: context.socket)
        await fulfillment(of: [accepted], timeout: 2)
        withExtendedLifetime(receiver) {}
    }
    func testReceiverCanRetryAfterItsPreviousOwnerStopsWithoutCleanup() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-agent-" + UUID().uuidString.prefix(8))
        try PrivateFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("activity.sock").path
        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        var address = try AgentActivitySocket.address(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertThrowsError(try AgentActivityReceiver(root: root) { _ in })
        close(descriptor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        let context = AgentTerminalContext(bindingID: binding, secret: secret, root: root.path, helper: "/bin/true")
        let invocation = AgentInvocation(context: context, provider: .claude)
        try PrivateFiles.write(invocation, to: URL(fileURLWithPath: context.activePath))
        let received = expectation(description: "Retry receives the current provider event")
        let receiver = try AgentActivityReceiver(root: root) { event in
            XCTAssertEqual(event.invocationID, invocation.id); received.fulfill()
        }
        AgentActivitySocket.send(invocation.event(.working), socket: socketPath)
        await fulfillment(of: [received], timeout: 2)
        withExtendedLifetime(receiver) {}
    }
    func testVersionThreeMigrationPreservesActivityDefaultsAndBackup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-activity-db-" + UUID().uuidString)
        try PrivateFiles.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.sqlite").path
        var old = WorkspaceState(); old.version = 3; old.newWorkspace(directory: "/tmp")
        let payload = try JSONEncoder().encode(old)
        let queue = try DatabaseQueue(path: path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE workspace_snapshot (id INTEGER PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for migration in ["workspace-v1", "workspace-v2", "workspace-v3"] { try db.execute(sql: "INSERT INTO grdb_migrations VALUES (?)", arguments: [migration]) }
            try db.execute(sql: "INSERT INTO workspace_snapshot VALUES (1, 3, ?)", arguments: [payload])
        }
        let database = try WorkspaceDatabase(path: path)
        let restored = try await database.load()
        XCTAssertEqual(restored?.version, 8); XCTAssertEqual(restored?.workspaces.flatMap(\.tabs), old.workspaces.flatMap(\.tabs))
        XCTAssertNil(restored?.selectedTab?.activity)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.contains("pre-v6") })
    }
}
