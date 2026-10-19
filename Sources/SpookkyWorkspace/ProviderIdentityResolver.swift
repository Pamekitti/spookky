import Foundation
import SpookkyCore

/// Identity must not wait for another provider's history index.
public enum ProviderIdentityResolver {
    public static func codex(candidates: [String], directory: String,
                             resolver: any ExecutableResolver = CLIResolver()) async -> ConversationMetadata? {
        guard !candidates.isEmpty, candidates.count <= 8 else { return nil }
        let directories = await HistoryQuery.folderAliases(directory)
        guard !Task.isCancelled, let spec = try? await resolver.resolve(.codex, directory: directory, prompt: nil) else { return nil }
        let metadata = Task.detached {
            try? CodexHistoryReader.page(executable: spec.executable,
                environment: ProcessInfo.processInfo.environment.merging(spec.environment) { _, value in value },
                query: HistoryQuery(directories: directories, limit: 100, exactDirectories: true))
        }
        let page = await withTaskCancellationHandler {
            await metadata.value
        } onCancel: {
            metadata.cancel()
        }
        guard !Task.isCancelled else { return nil }
        let matches = page?.conversations.filter {
            $0.id.provider == .codex && $0.source == "cli" && candidates.contains($0.id.sessionID) && directories.contains($0.directory)
        } ?? []
        return matches.count == 1 ? matches[0] : nil
    }
}
