import Foundation
import SpookkyCore
import SpookkyRuntime

public struct ConversationContinuationTarget: Equatable, Sendable {
    public let workspaceID: UUID
    public let terminalID: UUID
    public let conversationID: ConversationID?
    public let provider: SessionTool
    public let directory: String
    public let binding: SessionBinding?
    public let launchID: UUID?
    public let viewClosed: Bool
    public let ambiguous: Bool
    public let locationOwnerID: UUID?
    public let availability: ConversationAvailability?
}

public struct ConversationContinuationPresentation: Sendable {
    public let target: ConversationContinuationTarget
    public let guide: ProviderContinuationGuide
    public let capabilities: ProviderContinuationCapabilities
    public let ownership: ProviderOwnershipAssessment?
    public let warning: String?
}

@MainActor public final class ConversationContinuationCoordinator {
    public var metadata: ((ConversationID) -> ConversationMetadata?)?
    private let store: WorkspaceStore
    private let resolver: any ExecutableResolver
    private let probe: @Sendable (LaunchSpec) async throws -> ProviderContinuationCapabilities
    private let ownership: @Sendable (LaunchSpec, String) async -> ProviderOwnershipAssessment
    private var preparing = false

    public init(store: WorkspaceStore, resolver: any ExecutableResolver = CLIResolver(),
                probe: @escaping @Sendable (LaunchSpec) async throws -> ProviderContinuationCapabilities = { try await ProviderContinuationCapabilities.inspect($0) },
                ownership: @escaping @Sendable (LaunchSpec, String) async -> ProviderOwnershipAssessment = { await ProviderOwnershipCheck.assess($0, sessionID: $1) }) {
        self.store = store; self.resolver = resolver; self.probe = probe; self.ownership = ownership
    }

    public func capture(workspaceID: UUID) throws -> ConversationContinuationTarget {
        guard let workspace = store.state.workspaces.first(where: { $0.id == workspaceID }),
              let primary = workspace.primaryTerminal else {
            throw LaunchError.invalid("The primary conversation is unavailable.")
        }
        let provider = workspace.conversationID?.provider ?? ProviderContinuationCapabilities.provider(for: primary) ?? primary.launch?.tool
        guard let provider, provider != .shell else {
            throw LaunchError.invalid("This workspace has no primary provider conversation to continue.")
        }
        let saved = workspace.conversationID.flatMap { metadata?($0) }
        guard saved == nil || saved?.id == workspace.conversationID else {
            throw LaunchError.invalid("The saved conversation identity changed. Refresh its history before continuing.")
        }
        let directory = saved?.directory ?? primary.startDirectory ?? primary.binding?.directory ?? primary.launch?.directory ?? workspace.directory
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            throw LaunchError.invalid("The primary conversation's original folder is unavailable.")
        }
        return ConversationContinuationTarget(workspaceID: workspaceID, terminalID: primary.id,
            conversationID: workspace.conversationID, provider: provider, directory: directory,
            binding: primary.binding, launchID: primary.launch?.operationID,
            viewClosed: workspace.viewClosed == true, ambiguous: workspace.conversationOwnershipAmbiguous == true,
            locationOwnerID: workspace.locationOwnerWorkspaceID, availability: saved?.availability)
    }

    public func isCurrent(_ target: ConversationContinuationTarget) -> Bool {
        (try? capture(workspaceID: target.workspaceID)) == target
    }

    public func prepare(_ target: ConversationContinuationTarget) async throws -> ConversationContinuationPresentation? {
        guard !preparing, isCurrent(target) else { return nil }
        guard target.locationOwnerID == nil else {
            throw LaunchError.invalid("The primary conversation's folder is still being prepared. Finish location recovery before continuing.")
        }
        preparing = true; defer { preparing = false }
        try Task.checkCancellation()
        let spec = try await resolver.resolve(target.provider, directory: target.directory, prompt: nil)
        guard isCurrent(target) else { return nil }
        let capabilities = try await probe(spec)
        try Task.checkCancellation()
        guard isCurrent(target) else { return nil }
        let assessment: ProviderOwnershipAssessment?
        if target.ambiguous {
            assessment = ProviderOwnershipAssessment(route: .unknown,
                explanation: "More than one workspace reports this conversation identity. External ownership is unknown. Only an already-owned terminal may be reconnected.")
        } else if let id = target.conversationID, target.binding == nil {
            assessment = await ownership(spec, id.sessionID)
        } else { assessment = nil }
        try Task.checkCancellation()
        guard isCurrent(target), let primary = store.state.tab(target.terminalID) else { return nil }
        let liveProvider = primary.status == .running && ProviderContinuationCapabilities.provider(for: primary) == target.provider
        let guide = try capabilities.guide(sessionID: target.conversationID?.sessionID, directory: target.directory, hasLiveProvider: liveProvider, hasOwnedBinding: target.binding != nil)
        var warnings: [String] = []
        if let availability = target.availability, availability != .local {
            warnings.append("The saved folder or history is unavailable. Locate or refresh it through provider history before resuming. This panel does not repair or launch it.")
        }
        if primary.promptDelivery == .uncertain || [.uncertain, .unavailable, .launching, .preparing].contains(primary.status) {
            warnings.append("Primary launch or prompt delivery is uncertain. This panel does not retry a launch or resend input. Check the owned terminal before any saved resume.")
        }
        let warning = warnings.isEmpty ? nil : warnings.joined(separator: "\n\n")
        return ConversationContinuationPresentation(target: target, guide: guide, capabilities: capabilities,
                                                    ownership: assessment, warning: warning)
    }

    /// Reconcile the captured owned binding only. Surface attachment and focus stay with the native controller.
    public func reconnect(_ target: ConversationContinuationTarget, using launches: LaunchCoordinator) async -> Bool {
        guard target.binding != nil, isCurrent(target) else { return false }
        await launches.reconcile(target.terminalID)
        return isCurrent(target) && store.state.tab(target.terminalID)?.status == .running
    }
}
