import Foundation

@main struct MonitorCheck {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: "/tmp/spookky-m4-monitor-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        var monitor: RuntimeEventMonitor? = try RuntimeEventMonitor(root: root)
        var events = 0
        monitor?.onChange = { events += 1 }
        let file = root.appendingPathComponent("runtime-event")
        try Data("replacement".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(300))
        let first = events
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        try await Task.sleep(for: .milliseconds(300))
        guard first > 0, events > first else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.removeItem(at: file)
        try await Task.sleep(for: .milliseconds(300))
        guard FileManager.default.fileExists(atPath: file.path) else { throw CocoaError(.fileNoSuchFile) }
        let before = events
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        try await Task.sleep(for: .milliseconds(300))
        guard events > before else { throw CocoaError(.fileReadUnknown) }
        monitor = nil
        let released = events
        try Data("after release".utf8).write(to: file, options: .atomic)
        try await Task.sleep(for: .milliseconds(300))
        guard events == released else { throw CocoaError(.fileReadUnknown) }
        print("{\"atomic_replacement\":true,\"subsequent_touch\":true,\"deleted_file_recreated\":true,\"observer_released\":true}")
    }
}
