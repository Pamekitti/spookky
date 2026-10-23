import AppKit
import SpookkyCore
import SpookkyWorkspace
import SpookkyRuntime
import SpookkyPersistence

@MainActor enum ApplicationBootstrap {
    static func workspace(paths: AppPaths, initialStore: WorkspaceStore? = nil,
                          resolver: any ExecutableResolver = CLIResolver(), backgroundFixture: Bool = false) async throws -> WorkspaceWindowController {
        let loaded: WorkspaceStore
        if let initialStore { loaded = initialStore } else { loaded = try await store(paths: paths) }
        return try WorkspaceWindowController(root: paths.runtime, initialStore: loaded, resolver: resolver,
                                             backgroundFixture: backgroundFixture, dataDirectory: paths.data)
    }
    static func store(paths: AppPaths) async throws -> WorkspaceStore {
        let path = paths.data.appendingPathComponent("workspace.sqlite").path
        let database = try await Task.detached { try WorkspaceDatabase(path: path) }.value
        let saved = try await database.load()
        let store = WorkspaceStore(state: saved ?? WorkspaceState(), persistence: database)
        store.update { $0.restoreInterruptedDrafts() }
        return store
    }
}
