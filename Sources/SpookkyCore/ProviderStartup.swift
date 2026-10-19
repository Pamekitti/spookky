import Foundation

public struct ProviderStartup: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let beganAt: Date
    public let expectsPrompt: Bool
    public private(set) var interactionObserved = false
    public private(set) var noticeDismissed = false
    public static let noticeDelay: TimeInterval = 15

    public init(operationID: UUID, beganAt: Date = Date(), expectsPrompt: Bool) {
        self.operationID = operationID; self.beganAt = beganAt; self.expectsPrompt = expectsPrompt
    }
    public mutating func observe(_ event: AgentEvent) {
        guard event.bindingID == operationID, event.childID == nil, event.occurredAt >= beganAt.timeIntervalSince1970 else { return }
        switch event.kind {
        case .attached: if !expectsPrompt { interactionObserved = true }
        case .working, .needsInput, .finished, .failed, .interrupted: interactionObserved = true
        case .unsupported, .detached, .childStarted, .childActivity, .childEnded: break
        }
    }
    public var noticeDate: Date { beganAt.addingTimeInterval(Self.noticeDelay) }
    public mutating func dismissNotice() { noticeDismissed = true }
}

extension WorkspaceTab {
    public var pendingStartup: ProviderStartup? {
        guard status == .running, displayTool != .shell, let startup, !startup.interactionObserved, !startup.noticeDismissed,
              startup.beganAt.timeIntervalSince1970.isFinite,
              startup.operationID == binding?.id || startup.operationID == launch?.operationID else { return nil }
        return startup
    }
    public func startupMessage(at now: Date = Date()) -> String? {
        guard let pending = pendingStartup, now >= pending.noticeDate else { return nil }
        return pending.expectsPrompt
            ? "Starting-prompt acceptance is unconfirmed. Check native prompts and macOS file access before copying text."
            : "Provider startup is unconfirmed. Check its terminal, trust prompts or macOS file access. Activity may be unavailable."
    }
}

extension WorkspaceState {
    public mutating func dismissStartupNotice(_ tabID: UUID) { updateTab(tabID) { $0.startup?.dismissNotice() } }
}
