import SpookkyCore
import SpookkyRuntime

public struct ConversationExecutionDecision: Sendable {
    public let assessment: ProviderOwnershipAssessment
    public let launch: LaunchSpec
}

public enum ConversationExecutionCheck {
    public static func prepare(_ conversation: ConversationMetadata,
                               resolver: any ExecutableResolver = CLIResolver()) async throws -> ConversationExecutionDecision {
        try Task.checkCancellation()
        let base = try await resolver.resolve(conversation.id.provider, directory: conversation.directory, prompt: nil)
        try Task.checkCancellation()
        let capabilities = try await ProviderContinuationCapabilities.inspect(base)
        try Task.checkCancellation()
        let assessment = await ProviderOwnershipCheck.assess(base, sessionID: conversation.id.sessionID, capabilities: capabilities)
        try Task.checkCancellation()
        let launch = try assessment.continuationSpec(capabilities: capabilities, sessionID: conversation.id.sessionID, executable: base)
        return ConversationExecutionDecision(assessment: assessment, launch: launch)
    }

    public static func blockReason(_ conversation: ConversationMetadata, resolver: any ExecutableResolver = CLIResolver()) async -> String? {
        do { _ = try await prepare(conversation, resolver: resolver); return nil }
        catch is CancellationError { return "Opening this conversation was cancelled." }
        catch { return error.localizedDescription }
    }
}
