import XCTest
import SpookkyTestSupport
import SpookkyCore
import SpookkyWorkspace

private actor SlowPersistence: WorkspacePersistence {
    private var began = false
    private let started = TestGate()
    private let release = TestGate()
    func waitForSave() async { await started.wait() }
    func releaseSave() async { await release.signal() }
    private var states: [WorkspaceState] = []
    func load() async throws -> WorkspaceState? { states.last }
    func save(_ state: WorkspaceState) async throws {
        if !began {
            began = true
            await started.signal()
            await release.wait()
        }
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
        await persistence.waitForSave()
        store.update { $0.newTab() }
        let second = Task { try await store.flush() }
        await persistence.releaseSave()
        try await first.value; try await second.value
        let saved = try await persistence.load(), count = await persistence.count()
        XCTAssertEqual(saved, store.state)
        XCTAssertLessThanOrEqual(count, 2)
    }
}
