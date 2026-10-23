import XCTest
import SpookkyCore
import SpookkyWorkspace

private actor SlowPersistence: WorkspacePersistence {
    private var states: [WorkspaceState] = []
    func load() async throws -> WorkspaceState? { states.last }
    func save(_ state: WorkspaceState) async throws {
        try await Task.sleep(for: .milliseconds(30))
        states.append(state)
    }
    func count() -> Int { states.count }
}

@MainActor final class StoreTests: XCTestCase {
    func testConcurrentFlushAndEditsKeepNewestSnapshot() async throws {
        let persistence = SlowPersistence()
        let store = WorkspaceStore(persistence: persistence)
        store.update { $0.newWorkspace(directory: "/tmp") }
        let first = Task { try await store.flush() }
        try await Task.sleep(for: .milliseconds(5))
        store.update { $0.newTab() }
        let second = Task { try await store.flush() }
        try await first.value; try await second.value
        let saved = try await persistence.load(), count = await persistence.count()
        XCTAssertEqual(saved, store.state)
        XCTAssertLessThanOrEqual(count, 2)
    }
}
