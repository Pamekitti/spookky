import Foundation
@main struct Probe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-m3-scale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in 0..<100 {
            let folder = root.appendingPathComponent("dir-\(directory)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in 0..<500 { _ = FileManager.default.createFile(atPath: folder.appendingPathComponent("file-\(file).txt").path, contents: Data()) }
        }
        let service = FileService(), start = ProcessInfo.processInfo.systemUptime
        let result = try await service.search(root: root.path, query: "no-match")
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let cancel = Task { try await service.search(root: root.path, query: "no-match") }
        try await Task.sleep(for: .milliseconds(5)); cancel.cancel()
        var cancelled = false
        do { _ = try await cancel.value } catch is CancellationError { cancelled = true }
        let limited = try await service.search(root: root.path, query: "file")
        print(String(data: try JSONSerialization.data(withJSONObject: ["files": 50_000, "directories": 100, "elapsed_seconds": elapsed, "visited": result.visited, "incomplete": result.incomplete, "matches_at_limit": limited.entries.count, "match_limit_reported": limited.incomplete, "cancelled": cancelled], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
