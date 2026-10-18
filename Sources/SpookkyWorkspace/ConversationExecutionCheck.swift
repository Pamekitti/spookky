import SpookkyCore
import SpookkyRuntime

public enum ConversationExecutionCheck {
    public static func blockReason(_ conversation: ConversationMetadata, resolver: any ExecutableResolver = CLIResolver()) async -> String? {
        do {
            let base = try await resolver.resolve(conversation.id.provider, directory: conversation.directory, prompt: nil)
            let assessment = await ProviderOwnershipCheck.assess(base, sessionID: conversation.id.sessionID)
            return assessment.canInvokeNativeResume ? nil : assessment.explanation
        } catch { return "The provider is unavailable. Check its installation before continuing." }
    }
}
