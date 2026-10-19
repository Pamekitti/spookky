import Foundation
import SpookkyCore
import SpookkyRuntime

public protocol ExecutableResolver: Sendable {
    func resolveFresh(_ tool: SessionTool, directory: String, prompt: String?, images: [String]) async throws -> LaunchSpec
    func resolveFresh(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec
}

extension ExecutableResolver {
    public func resolveFresh(_ tool: SessionTool, directory: String, prompt: String?, images: [String]) async throws -> LaunchSpec {
        let spec = try await resolveFresh(tool, directory: directory, prompt: prompt)
        return try await spec.attachingPromptImages(images)
    }
    public func resolveFresh(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try await resolve(tool, directory: directory, prompt: prompt)
    }
}

@MainActor public final class LaunchCoordinator {
    public let runtime: any SessionRuntime
    private let store: WorkspaceStore
    private let resolver: any ExecutableResolver
    private var operations: Set<UUID> = []
    public init(store: WorkspaceStore, runtime: any SessionRuntime, resolver: any ExecutableResolver = CLIResolver()) {
        self.store = store; self.runtime = runtime; self.resolver = resolver
    }
    public func isBusy(_ id: UUID) -> Bool { operations.contains(id) }

    public func launch(_ id: UUID, tool: SessionTool? = nil) async {
        guard !operations.contains(id) else { return }
        operations.insert(id); defer { operations.remove(id) }
        await performLaunch(id, tool: tool)
    }
    private func performLaunch(_ id: UUID, tool: SessionTool? = nil, prepared: LaunchSpec? = nil, resuming: Bool = false) async {
        guard !Task.isCancelled, let tab = store.state.tab(id),
              let workspace = store.state.workspace(containing: id),
              tab.binding == nil, tab.isEditable || tab.status == .preparing || (tab.status == .failed && tab.launch != nil) else { return }
        store.update { $0.apply(.preparing, to: id) }
        var starting = false
        do {
            let spec: LaunchSpec
            if let frozen = tab.launch ?? prepared { spec = frozen }
            else {
                spec = try await resolver.resolveFresh(tool ?? tab.draft.tool,
                    directory: tab.startDirectory ?? workspace.directory,
                    prompt: tab.draft.prompt.isEmpty ? nil : tab.draft.prompt, images: tab.draft.images)
            }
            try Task.checkCancellation()
            store.update {
                $0.bindWorkspace(workspace.id)
                if spec.tool != .shell { $0.promoteLanding(workspace.id) }
                if !resuming, let sessionID = spec.environment["SPOOKKY_PROVIDER_SESSION_ID"], UUID(uuidString: sessionID) != nil {
                    $0.associateConversation(provider: spec.tool, sessionID: sessionID, title: nil, workspaceID: workspace.id)
                }
                $0.apply(.intent(spec, resuming || tab.draft.isEmpty || spec.tool == .shell ? .none : .pending), to: id)
            }
            try await store.flush()
            starting = true
            // Durable intent is the commit point. Finish recording the owned result even if its view closes.
            let runtime = self.runtime
            let binding = try await Task { try await runtime.create(spec) }.value
            store.update { $0.apply(.observed(binding, dead: false, exitCode: nil,
                prompt: resuming || tab.draft.isEmpty || spec.tool == .shell ? PromptDelivery.none : .suppliedToProcess), to: id) }
            try await store.flush()
        } catch is CancellationError where !starting && store.state.tab(id)?.status == .preparing && store.state.tab(id)?.launch == tab.launch {
            store.update { $0.cancelPreparation(id, restoring: tab) }
        } catch {
            if starting {
                do {
                    let receipts = try await runtime.list()
                    if let intent = store.state.tab(id)?.launch,
                       let receipt = receipts.first(where: { $0.id == intent.operationID }) {
                        if let observation = try await runtime.inspect(receipt) {
                            store.update { $0.apply(.observed(receipt, dead: observation.dead, exitCode: observation.exitCode,
                                prompt: $0.tab(id)?.promptDelivery == PromptDelivery.none ? PromptDelivery.none : .uncertain), to: id) }
                            return
                        }
                        if receipt.phase != .intent {
                            fail(id, status: .uncertain, phase: .launch, error: LaunchError.uncertainLaunch)
                            return
                        }
                    }
                    fail(id, status: .failed, phase: .validation, error: error, clearIntent: true)
                } catch { fail(id, status: .unavailable, phase: .observation, error: error) }
            } else { fail(id, status: .failed, phase: .validation, error: error, clearIntent: true) }
        }
    }
    /// Explicit history continuation carries no initial prompt, including a retained composer draft.
    public func resume(_ id: UUID, conversation: ConversationMetadata, prepared: LaunchSpec? = nil) async {
        guard !operations.contains(id), !Task.isCancelled, conversation.availability == .local,
              UUID(uuidString: conversation.id.sessionID) != nil, conversation.id.provider != .shell,
              let tab = store.state.tab(id), let workspace = store.state.workspace(containing: id),
              workspace.conversationID == nil || workspace.conversationID == conversation.id else { return }
        let fresh = tab.isEditable && tab.binding == nil && tab.launch == nil && tab.draft.isEmpty
        let ended = tab.status == .ended && tab.promptDelivery != .pending && tab.promptDelivery != .uncertain
        guard fresh || ended else { return }
        operations.insert(id); defer { operations.remove(id) }
        do {
            let spec: LaunchSpec
            if let prepared {
                try validatePreparedResume(prepared, conversation: conversation)
                spec = prepared
            } else {
                let base = try await resolver.resolve(conversation.id.provider, directory: conversation.directory, prompt: nil)
                let arguments = try ProviderContinuationCapabilities.resumeArguments(provider: conversation.id.provider,
                    sessionID: conversation.id.sessionID, originalDirectory: conversation.directory)
                spec = try LaunchSpec(operationID: base.operationID, tool: conversation.id.provider, executable: base.executable,
                    arguments: base.arguments + arguments, directory: conversation.directory, environment: base.environment)
            }
            try Task.checkCancellation()
            guard store.state.tab(id) == tab else { return }
            store.update {
                if ended { $0.prepareEndedConversationResume(id) }
                $0.editDraft(id, tool: conversation.id.provider)
            }
            await performLaunch(id, prepared: spec, resuming: true)
        } catch is CancellationError { return }
        catch { fail(id, status: .failed, phase: .validation, error: error, clearIntent: true) }
    }

    private func validatePreparedResume(_ spec: LaunchSpec, conversation: ConversationMetadata) throws {
        guard spec.tool == conversation.id.provider, spec.directory == conversation.directory else {
            throw LaunchError.invalid("The prepared continuation no longer matches this conversation or its original folder.")
        }
        let id = conversation.id.sessionID, arguments = spec.arguments
        let valid: Bool
        switch conversation.id.provider {
        case .codex:
            valid = arguments == ["resume", id] || arguments == ["resume", id, "--cd", conversation.directory] ||
                arguments == ["resume", id, "-C", conversation.directory]
        case .claude:
            valid = arguments == ["--resume", id] ||
                (arguments.count == 2 && arguments[0] == "attach" && ProviderContinuationCapabilities.validAttachID(arguments[1]))
        case .shell: valid = false
        }
        guard valid else { throw LaunchError.invalid("The prepared continuation has unexpected arguments. Refresh this conversation before continuing.") }
    }


    public func reconcile(_ id: UUID) async {
        guard !operations.contains(id), let tab = store.state.tab(id) else { return }
        if tab.status == .ended && tab.binding == nil { return }
        operations.insert(id); defer { operations.remove(id) }
        do {
            let receipt: SessionBinding?
            if let binding = tab.binding { receipt = binding }
            else if let spec = tab.launch { receipt = try await runtime.list().first { $0.id == spec.operationID } }
            else { return }
            guard let receipt else {
                store.update { $0.apply(.failure(.failed, TabFailure(.validation, "Launch did not start. Edit the draft or retry."), clearIntent: true), to: id) }
                return
            }
            if let observation = try await runtime.inspect(receipt) {
                store.update { $0.apply(.observed(receipt, dead: observation.dead, exitCode: observation.exitCode,
                    prompt: $0.tab(id)?.promptDelivery == .pending ? .uncertain : nil), to: id) }
            } else if receipt.phase == .starting {
                fail(id, status: .uncertain, phase: .launch, error: LaunchError.uncertainLaunch)
            } else if receipt.phase == .intent {
                store.update { $0.apply(.failure(.failed, TabFailure(.validation, "Launch did not start. Edit the draft or retry."), clearIntent: true), to: id) }
            } else {
                store.update { $0.apply(.terminated, to: id) }
            }
        } catch { fail(id, status: .unavailable, phase: .observation, error: error) }
    }
    public func terminate(_ id: UUID) async throws {
        guard !operations.contains(id), let tab = store.state.tab(id) else { throw LaunchError.invalid("This terminal has an operation in progress.") }
        if tab.binding == nil, tab.launch != nil {
            await reconcile(id)
            guard store.state.tab(id)?.status != .uncertain, store.state.tab(id)?.status != .unavailable else { throw LaunchError.uncertainLaunch }
        }
        guard !operations.contains(id) else { throw LaunchError.invalid("This terminal has an operation in progress.") }
        operations.insert(id); defer { operations.remove(id) }
        if let binding = store.state.tab(id)?.binding { try await runtime.terminate(binding) }
        store.update { $0.apply(.terminated, to: id) }
        try await store.flush()
    }
    private func fail(_ id: UUID, status: TabStatus, phase: FailurePhase, error: Error, clearIntent: Bool = false) {
        let recovery: FailureRecovery?
        if case .folderUnavailable = error as? LaunchError { recovery = .locateFolder } else { recovery = nil }
        store.update { $0.apply(.failure(status, TabFailure(phase, error.localizedDescription, recovery: recovery), clearIntent: clearIntent), to: id) }
    }
    public static func label(_ tool: SessionTool) -> String {
        tool.displayName
    }
}
