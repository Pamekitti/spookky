import Foundation

/// Optional display metadata for the primary terminal. ConversationID remains authoritative.
public struct ProviderConversationTitle: Codable, Equatable, Sendable {
    public let provider: SessionTool
    public let sessionID: String
    public var title: String?
    public var id: ConversationID { ConversationID(provider: provider, sessionID: sessionID) }
    public init(provider: SessionTool, sessionID: String, title: String?) {
        self.provider = provider; self.sessionID = sessionID; self.title = Self.clean(title)
    }
    public var isValid: Bool {
        provider != .shell && !sessionID.isEmpty && sessionID.utf8.count <= 256 &&
        !sessionID.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } && title == Self.clean(title)
    }
    static func clean(_ title: String?) -> String? {
        guard let title else { return nil }
        let bounded = String(String.UnicodeScalarView(title.unicodeScalars.prefix(2048)))
        let value = bounded.split(whereSeparator: {
            $0.isWhitespace || $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }).joined(separator: " ")
        return value.isEmpty ? nil : String(value.prefix(256))
    }
}

extension ConversationID {
    var acceptsTitleUpdate: Bool {
        switch provider {
        case .codex: return UUID(uuidString: sessionID) != nil
        case .claude: return UUID(uuidString: sessionID) != nil
        case .shell: return false
        }
    }
}

extension WorkspaceTab {
    public var displayTool: SessionTool {
        if let activity, activity.attached || status == .ended { return activity.provider }
        return binding?.tool ?? launch?.tool ?? draft.tool
    }
    func matchesConversation(_ id: ConversationID) -> Bool {
        guard let activity, let sessionID = activity.sessionID else { return true }
        return activity.provider == id.provider && sessionID == id.sessionID
    }
}

extension Workspace {
    public var displayTitle: String {
        if customTitle { return title }
        guard let primary = primaryTerminal else { return title }
        if primary.customTitle { return primary.title }
        guard let conversationID, let metadata = primary.providerTitle,
              metadata.id == conversationID, primary.matchesConversation(conversationID), let name = metadata.title else { return title }
        return name
    }
    public var displayProvider: SessionTool {
        conversationID?.provider ?? primaryTerminal?.displayTool ?? .shell
    }
}

extension SupportingTab {
    public var displayTitle: String {
        switch target {
        case .changes: return "Changes"
        case .file(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .artifact(let path): return URL(fileURLWithPath: path).lastPathComponent
        case .browser: return title.isEmpty ? "Browser" : title
        case .terminal: return title.isEmpty ? "Terminal" : title
        }
    }
    public var contentLabel: String {
        switch target {
        case .changes: "Changes"
        case .file: "File"
        case .artifact: "Artifact"
        case .browser: "Browser"
        case .terminal: "Terminal"
        }
    }
}

extension WorkspaceState {
    public mutating func associateConversation(provider: SessionTool, sessionID: String, title: String?, workspaceID: UUID) {
        let id = ConversationID(provider: provider, sessionID: sessionID)
        guard id.acceptsTitleUpdate, let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.conversationID == nil || workspace.conversationID == id,
              workspace.primaryTerminal?.matchesConversation(id) == true else { return }
        associateConversation(id, workspaceID: workspaceID)
        updateConversationTitle(provider: provider, sessionID: sessionID, title: title)
    }
    public mutating func updateConversationTitle(provider: SessionTool, sessionID: String, title: String?) {
        let id = ConversationID(provider: provider, sessionID: sessionID)
        guard id.acceptsTitleUpdate else { return }
        let metadata = ProviderConversationTitle(provider: provider, sessionID: sessionID, title: title)
        for workspace in workspaces where workspace.conversationID == id {
            guard let primary = workspace.primaryTerminal, primary.matchesConversation(id) else { continue }
            updateTab(primary.id) { $0.providerTitle = metadata }
        }
    }
}
