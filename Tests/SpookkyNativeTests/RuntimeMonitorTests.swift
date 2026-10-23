import Foundation
import XCTest
@testable import SpookkyHarness

@MainActor final class RuntimeMonitorTests: XCTestCase {
    func testAtomicReplacementDeletionAndObserverRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-monitor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var monitor: RuntimeEventMonitor? = try RuntimeEventMonitor(root: root)
        var events = 0
        monitor?.onChange = { events += 1 }
        func waitForEvent(after count: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while events <= count && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertGreaterThan(events, count)
        }
        let file = root.appendingPathComponent("runtime-event")
        try Data("replacement".utf8).write(to: file, options: .atomic)
        try await waitForEvent(after: 0)
        var before = events
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        try await waitForEvent(after: before)
        before = events
        try FileManager.default.removeItem(at: file)
        try await waitForEvent(after: before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        monitor = nil
        before = events
        try Data("released".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(events, before)
    }
}
