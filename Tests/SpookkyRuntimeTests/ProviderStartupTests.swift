import XCTest
@testable import SpookkyCore

final class ProviderStartupTests: XCTestCase {
    private let began = Date(timeIntervalSince1970: 1_000)
    private func event(_ kind: AgentEventKind, binding: UUID, child: String? = nil, at: TimeInterval = 1_001) -> AgentEvent {
        var event = AgentEvent(bindingID: binding, invocationID: UUID(), secret: UUID(),
            provider: .claude, kind: kind, childID: child)
        event.occurredAt = at
        return event
    }
    func testRuntimeAttachmentDoesNotProvePromptAcceptance() throws {
        var state = WorkspaceState(); state.newWorkspace(directory: "/tmp")
        let terminal = try XCTUnwrap(state.primaryTerminalID)
        let spec = try LaunchSpec(tool: .claude, executable: "/bin/cat", directory: "/tmp", initialPrompt: "Keep literal input")
        state.apply(.preparing, to: terminal); state.apply(.intent(spec, .pending), to: terminal)
        state.apply(.observed(SessionBinding(spec: spec), dead: false, exitCode: nil, prompt: .suppliedToProcess), to: terminal)
        state.updateTab(terminal) { $0.startup = ProviderStartup(operationID: spec.operationID, beganAt: began, expectsPrompt: true) }
        XCTAssertNil(state.tab(terminal)?.startupMessage(at: began.addingTimeInterval(14)))
        XCTAssertNotNil(state.tab(terminal)?.startupMessage(at: began.addingTimeInterval(15)))
        XCTAssertEqual(state.tab(terminal)?.promptDelivery, .suppliedToProcess)
        let invocation = UUID(), secret = UUID()
        for kind in [AgentEventKind.unsupported, .attached] {
            var native = AgentEvent(bindingID: spec.operationID, invocationID: invocation, secret: secret, provider: .claude, kind: kind)
            native.occurredAt = 1_001; state.recordAgentEvent(native)
            XCTAssertNotNil(state.tab(terminal)?.startupMessage(at: began.addingTimeInterval(30)))
        }
        var working = AgentEvent(bindingID: spec.operationID, invocationID: invocation, secret: secret, provider: .claude, kind: .working)
        working.occurredAt = 1_002; state.recordAgentEvent(working)
        XCTAssertNil(state.tab(terminal)?.startupMessage(at: began.addingTimeInterval(30)))
        XCTAssertEqual(state.tab(terminal)?.promptDelivery, .suppliedToProcess)
        XCTAssertEqual(state.tab(terminal)?.launch, spec)
    }

    func testOnlyCurrentNativeInteractionSettlesStartup() {
        let operation = UUID()
        var startup = ProviderStartup(operationID: operation, beganAt: began, expectsPrompt: true)
        for invalid in [event(.working, binding: UUID()), event(.working, binding: operation, child: "child"),
                        event(.working, binding: operation, at: 999), event(.unsupported, binding: operation), event(.detached, binding: operation)] {
            startup.observe(invalid)
            XCTAssertFalse(startup.interactionObserved)
        }
        startup.observe(event(.needsInput, binding: operation))
        XCTAssertTrue(startup.interactionObserved)
        var empty = ProviderStartup(operationID: operation, beganAt: began, expectsPrompt: false)
        empty.observe(event(.attached, binding: operation))
        XCTAssertTrue(empty.interactionObserved)
    }

    func testNativeConversationSwitchObservesStartupInTheMovedTerminal() throws {
        for (expectsPrompt, kind) in [(false, AgentEventKind.attached), (true, .working)] {
            let original = ConversationID(provider: .claude, sessionID: UUID().uuidString)
            let destination = ConversationID(provider: .claude, sessionID: UUID().uuidString)
            var state = WorkspaceState()
            let workspace = state.ensureConversationWorkspace(original, location: WorkspaceLocation(path: "/tmp"))
            let terminal = try XCTUnwrap(state.primaryTerminalID)
            let spec = try LaunchSpec(tool: .claude, executable: "/bin/cat", directory: "/tmp",
                                      initialPrompt: expectsPrompt ? "Literal starting prompt" : nil)
            state.bindWorkspace(workspace)
            state.apply(.preparing, to: terminal); state.apply(.intent(spec, expectsPrompt ? .pending : .none), to: terminal)
            let binding = SessionBinding(spec: spec)
            state.apply(.observed(binding, dead: false, exitCode: nil, prompt: nil), to: terminal)
            state.updateTab(terminal) { $0.startup = ProviderStartup(operationID: spec.operationID, beganAt: began, expectsPrompt: expectsPrompt) }
            var native = AgentEvent(bindingID: spec.operationID, invocationID: spec.operationID, secret: UUID(),
                                    provider: .claude, kind: kind, sessionID: destination.sessionID)
            native.occurredAt = 1_001
            XCTAssertEqual(state.recordAgentEvent(native, followTerminal: true), terminal)
            let moved = try XCTUnwrap(state.workspace(for: destination)?.primaryTerminal)
            XCTAssertEqual(moved.id, terminal); XCTAssertEqual(moved.binding, binding); XCTAssertEqual(moved.launch, spec)
            XCTAssertTrue(moved.startup?.interactionObserved == true)
            XCTAssertNil(moved.startupMessage(at: began.addingTimeInterval(30)))
            try state.validate()
        }
    }

    func testStartupStateRestoresAndOldRecordsRemainCompatible() throws {
        var tab = WorkspaceTab(tool: .claude)
        let spec = try LaunchSpec(tool: .claude, executable: "/bin/cat", directory: "/tmp")
        tab.status = .running; tab.launch = spec; tab.binding = SessionBinding(spec: spec)
        tab.startup = ProviderStartup(operationID: spec.operationID, beganAt: began, expectsPrompt: false)
        let data = try JSONEncoder().encode(tab)
        let restored = try JSONDecoder().decode(WorkspaceTab.self, from: data)
        XCTAssertEqual(restored, tab)
        XCTAssertNotNil(restored.startupMessage(at: began.addingTimeInterval(30)))
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); old.removeValue(forKey: "startup")
        let legacy = try JSONDecoder().decode(WorkspaceTab.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.startupMessage(at: began.addingTimeInterval(30)))
        var stale = restored; stale.binding = nil; stale.launch = nil
        XCTAssertNil(stale.pendingStartup)
        var ended = restored; ended.status = .ended
        XCTAssertNil(ended.pendingStartup)
        var dismissed = restored; dismissed.startup?.dismissNotice()
        XCTAssertNil(dismissed.pendingStartup)
        XCTAssertFalse(dismissed.startup!.interactionObserved)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceTab.self, from: JSONEncoder().encode(dismissed)), dismissed)
    }
}
