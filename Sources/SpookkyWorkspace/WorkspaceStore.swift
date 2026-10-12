import Foundation
import SpookkyCore

public protocol WorkspacePersistence: Sendable {
    func load() async throws -> WorkspaceState?
    func save(_ state: WorkspaceState) async throws
}

@MainActor public final class WorkspaceStore {
    public private(set) var state: WorkspaceState
    public private(set) var saveError: String?
    public var onChange: (() -> Void)?
    private let persistence: (any WorkspacePersistence)?
    private var saveTask: Task<Void, Never>?
    private var revision = 0
    private var savedRevision = 0
    private var inFlight: (revision: Int, task: Task<Void, Error>)?

    public init(state: WorkspaceState = WorkspaceState(), persistence: (any WorkspacePersistence)? = nil) {
        self.state = state; self.persistence = persistence
    }
    public func update(debounced: Bool = false, _ change: (inout WorkspaceState) -> Void) {
        let before = state
        change(&state)
        guard before != state else { return }
        revision += 1; onChange?()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            if debounced { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, let self else { return }
            do { try await self.flush() } catch { }
        }
    }
    public func flush() async throws {
        guard let persistence else { return }
        while savedRevision < revision {
            let write: (revision: Int, task: Task<Void, Error>)
            if let inFlight { write = inFlight }
            else {
                let snapshot = state, savingRevision = revision
                try snapshot.validate()
                let task = Task { try await persistence.save(snapshot) }
                write = (savingRevision, task); inFlight = write
            }
            do {
                try await write.task.value
                savedRevision = max(savedRevision, write.revision)
                if inFlight?.revision == write.revision { inFlight = nil }
                if saveError != nil { saveError = nil; onChange?() }
            } catch {
                if inFlight?.revision == write.revision { inFlight = nil }
                saveError = "Changes are not saved: " + error.localizedDescription
                onChange?(); throw error
            }
        }
    }
}
