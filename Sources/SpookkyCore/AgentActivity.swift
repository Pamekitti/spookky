import Foundation

public enum AgentActivityState: String, Codable, Sendable {
    case unknown, idle, working, needsInput, finished, failed, interrupted

    public var label: String {
        switch self {
        case .unknown: "Activity unknown"
        case .idle: "Idle"
        case .working: "Working"
        case .needsInput: "Needs input"
        case .finished: "Finished, unread"
        case .failed: "Agent failed"
        case .interrupted: "Interrupted"
        }
    }
    public var priority: Int {
        switch self {
        case .needsInput: 5
        case .failed: 4
        case .working: 3
        case .finished: 2
        case .unknown, .interrupted: 1
        case .idle: 0
        }
    }
    public var needsAttention: Bool { self == .needsInput || self == .finished || self == .failed }
}

public enum AgentEventKind: String, Codable, Sendable {
    case attached, working, needsInput, finished, failed, interrupted, detached, unsupported
    case childStarted, childActivity, childEnded
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public let bindingID: UUID
    public let invocationID: UUID
    public let secret: UUID
    public let provider: SessionTool
    public let kind: AgentEventKind
    public var sessionID: String?
    public var turnID: String?
    public var childID: String?
    public var childType: String?
    public var preview: String?
    public var occurredAt: TimeInterval = Date().timeIntervalSince1970

    public init(bindingID: UUID, invocationID: UUID, secret: UUID, provider: SessionTool, kind: AgentEventKind,
                sessionID: String? = nil, turnID: String? = nil, childID: String? = nil, childType: String? = nil, preview: String? = nil) {
        self.bindingID = bindingID; self.invocationID = invocationID; self.secret = secret
        self.provider = provider; self.kind = kind; self.sessionID = sessionID; self.turnID = turnID
        self.childID = childID; self.childType = childType; self.preview = preview.map(Self.cleanPreview)
    }

    public var isValid: Bool {
        provider != .shell && occurredAt.isFinite && occurredAt > 0 &&
        [sessionID, turnID, childID, childType].allSatisfy { $0 == nil || ($0!.utf8.count <= 256 && !$0!.contains("\0")) } &&
        (preview?.count ?? 0) <= 180
    }

    public static func cleanPreview(_ value: String) -> String {
        let plain = value.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        return String(plain.split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }).joined(separator: " ").prefix(180))
    }
}

public struct AgentChild: Equatable, Sendable {
    public let id: String
    public var type: String?
    public var lastEventAt: TimeInterval
}

public struct AgentActivity: Codable, Equatable, Sendable {
    public var invocationID: UUID
    public var provider: SessionTool
    public var sessionID: String?
    public var state: AgentActivityState = .unknown
    public var lastEventID: UUID?
    public var lastEventAt: TimeInterval = 0
    public var completionID: UUID?
    public var seenCompletionID: UUID?
    public var manualUnread = false
    public var preview: String?
    public var attached = true
    public var children: [AgentChild] = []

    // Child presence is transient. Restoring it would invent live child sessions.
    enum CodingKeys: String, CodingKey {
        case invocationID, provider, sessionID, state, lastEventID, lastEventAt, completionID, seenCompletionID, manualUnread, preview, attached
    }

    public init(invocationID: UUID, provider: SessionTool) { self.invocationID = invocationID; self.provider = provider }
    public var unread: Bool { manualUnread || (completionID != nil && completionID != seenCompletionID) }
    public var displayState: AgentActivityState { state == .finished && !unread ? .idle : state }
    public var needsAttention: Bool { unread || displayState == .needsInput || displayState == .failed }
    public var isValid: Bool {
        provider != .shell && lastEventAt.isFinite && (preview?.count ?? 0) <= 180 && children.count <= 64 && (sessionID?.utf8.count ?? 0) <= 256
    }

    public mutating func acknowledge() { seenCompletionID = completionID; manualUnread = false }
    public mutating func reset() { state = .unknown; acknowledge(); children.removeAll() }
    public mutating func restore() { state = .unknown; attached = false; children.removeAll() }
    public mutating func disconnect() {
        attached = false; children.removeAll()
        if state == .working || state == .needsInput { state = .unknown }
    }

    @discardableResult public mutating func apply(_ event: AgentEvent) -> Bool {
        guard event.isValid, event.invocationID == invocationID, event.provider == provider,
              event.id != lastEventID, event.occurredAt >= lastEventAt else { return false }
        if let childID = event.childID {
            switch event.kind {
            case .childEnded: children.removeAll { $0.id == childID }
            default:
                if let index = children.firstIndex(where: { $0.id == childID }) {
                    children[index].lastEventAt = event.occurredAt
                } else if children.count < 64 {
                    children.append(AgentChild(id: childID, type: event.childType, lastEventAt: event.occurredAt))
                }
            }
            return true
        }
        if let sessionID, let incoming = event.sessionID, incoming != sessionID, event.kind != .attached { return false }
        if let incoming = event.sessionID {
            if sessionID != nil && sessionID != incoming { children.removeAll() }
            sessionID = incoming
        }
        lastEventID = event.id; lastEventAt = event.occurredAt
        if let preview = event.preview, !preview.isEmpty { self.preview = preview }
        switch event.kind {
        case .attached:
            attached = true
            if state == .unknown { state = .idle }
        case .working: state = .working; attached = true
        case .needsInput: state = .needsInput
        case .finished:
            if state != .finished { completionID = event.id }
            state = .finished
        case .failed: state = .failed
        case .interrupted: state = .interrupted
        case .unsupported: state = .unknown; attached = false; children.removeAll()
        case .detached: disconnect()
        case .childStarted, .childActivity, .childEnded: break
        }
        return true
    }
}

public enum AgentHookPayload {
    public static func event(data: Data, provider: SessionTool, bindingID: UUID, invocationID: UUID, secret: UUID) -> AgentEvent? {
        guard data.count <= 1_048_576, let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func string(_ keys: String...) -> String? { keys.lazy.compactMap { raw[$0] as? String }.first }
        let name = string("hook_event_name", "hookEventName", "type") ?? ""
        let child = string("agent_id", "agentId")
        let tool = raw["tool_name"] as? String ?? ""
        let kind: AgentEventKind
        if child != nil {
            kind = ["SubagentStop", "Stop", "SessionEnd"].contains(name) ? .childEnded : (name == "SubagentStart" ? .childStarted : .childActivity)
        } else {
            switch name {
            case "SessionStart": kind = .attached
            case "SessionEnd": kind = .detached
            case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PermissionResult", "ElicitationResult": kind = .working
            case "PermissionRequest", "Elicitation": kind = .needsInput
            case "PreToolUse":
                guard ["request_user_input", "AskUserQuestion", "ExitPlanMode"].contains(tool) else { return nil }
                kind = .needsInput
            case "Notification":
                guard ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(string("notification_type") ?? "") else { return nil }
                kind = .needsInput
            case "Stop", "agent-turn-complete": kind = .finished
            case "StopFailure": kind = .failed
            case "Interrupt": kind = .interrupted
            default: return nil
            }
        }
        let input = raw["tool_input"] as? [String: Any]
        let message = kind == .failed ? string("error_details", "error", "last_assistant_message") :
            (kind == .needsInput ? (input?["description"] as? String ?? string("message")) : string("last_assistant_message", "last-assistant-message", "message"))
        return AgentEvent(bindingID: bindingID, invocationID: invocationID, secret: secret, provider: provider, kind: kind,
                          sessionID: string("session_id", "sessionId", "thread-id"), turnID: string("turn_id"),
                          childID: child, childType: string("agent_type", "agentType"), preview: message)
    }
}

public struct AgentNotificationPreferences: Codable, Equatable, Sendable {
    public var codex = true
    public var claude = true
    public var inputBanner = true
    public var finishedBanner = true
    public var failedBanner = true
    public var inputSound = false
    public var finishedSound = false
    public var failedSound = false
    public var previews = true
    public var dockBadge = true
    public var suppressVisible = true
    public var sound = "Glass"
    public var volume: Float = 0.5
    public init() {}
    public func enabled(_ tool: SessionTool) -> Bool { tool == .codex ? codex : tool == .claude ? claude : false }
    public func banner(_ state: AgentActivityState) -> Bool { state == .needsInput ? inputBanner : state == .finished ? finishedBanner : state == .failed ? failedBanner : false }
    public func playsSound(_ state: AgentActivityState) -> Bool { state == .needsInput ? inputSound : state == .finished ? finishedSound : state == .failed ? failedSound : false }
}
