import Foundation
import SpookkyCore
import SpookkyRuntime

public protocol ExecutableResolver: Sendable {
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec
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
        guard !operations.contains(id), let tab = store.state.tab(id),
              let workspace = store.state.workspace(containing: id),
              tab.binding == nil, tab.isEditable || tab.status == .preparing || (tab.status == .failed && tab.launch != nil) else { return }
        operations.insert(id); defer { operations.remove(id) }
        store.update { $0.apply(.preparing, to: id) }
        var starting = false
        do {
            let spec: LaunchSpec
            if let frozen = tab.launch { spec = frozen }
            else {
                spec = try await resolver.resolve(tool ?? tab.draft.tool,
                    directory: tab.startDirectory ?? workspace.directory,
                    prompt: tab.draft.prompt.isEmpty ? nil : tab.draft.prompt)
            }
            store.update {
                $0.bindWorkspace(workspace.id)
                $0.apply(.intent(spec, tab.draft.prompt.isEmpty || spec.tool == .shell ? .none : .pending), to: id)
            }
            try await store.flush()
            starting = true
            let binding = try await runtime.create(spec)
            store.update { $0.apply(.observed(binding, dead: false, exitCode: nil,
                prompt: tab.draft.prompt.isEmpty || spec.tool == .shell ? PromptDelivery.none : .suppliedToProcess), to: id) }
            try await store.flush()
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
