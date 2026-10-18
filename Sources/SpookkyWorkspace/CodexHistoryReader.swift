import Darwin
import Foundation
import SpookkyCore

// Only initialize and database-only thread/list are allowed on this short-lived connection.
// It never loads a thread, subscribes to a turn, or repairs provider metadata.
struct CodexHistoryReader {
    static let sourceKinds = ["cli", "vscode", "appServer", "exec", "unknown"]
    static func read(executable: String, environment: [String: String], limit: Int = 5_000) throws -> SessionCatalogSnapshot {
        let rpc = try MetadataRPC(executable: executable, environment: environment)
        defer { rpc.close() }
        _ = try rpc.request("initialize", ["clientInfo": ["name": "spookky_history", "title": "Spookky History", "version": "0.1.0"]])
        try rpc.send(["method": "initialized", "params": [:]])
        var entries: [ConversationMetadata] = [], cursor: String?, seen = Set<String>(), scanned = 0
        repeat {
            var params: [String: Any] = ["limit": min(100, limit - scanned), "sortKey": "updated_at",
                "sortDirection": "desc", "sourceKinds": sourceKinds, "modelProviders": [], "useStateDbOnly": true]
            if let cursor { params["cursor"] = cursor }
            let page = try rpc.request("thread/list", params)
            guard let rows = page["data"] as? [[String: Any]] else { throw MetadataRPC.failure() }
            scanned += rows.count
            entries += rows.compactMap(metadata)
            cursor = page["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw MetadataRPC.failure() }
            if scanned >= limit { break }
        } while cursor != nil
        return SessionCatalogSnapshot(conversations: entries, truncated: cursor != nil)
    }

    static func metadata(_ row: [String: Any]) -> ConversationMetadata? {
        guard let id = row["id"] as? String, UUID(uuidString: id) != nil,
              let cwd = row["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0"),
              let updated = row["updatedAt"] as? Double, row["ephemeral"] as? Bool != true,
              row["parentThreadId"] as? String == nil else { return nil }
        let path = row["path"] as? String
        return ConversationMetadata(id: ConversationID(provider: .codex, sessionID: id), title: row["name"] as? String,
            directory: cwd, updatedAt: Date(timeIntervalSince1970: updated), source: row["source"] as? String,
            providerProjectID: row["projectId"] as? String, historyPath: path)
    }
}

private final class MetadataRPC {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data(), nextID = 0, received = 0
    private let deadline: TimeInterval
    static func failure() -> LaunchError { .invalid("Codex local history is unavailable or uses an unsupported metadata format.") }
    init(executable: String, environment: [String: String]) throws {
        deadline = ProcessInfo.processInfo.systemUptime + 12
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    func send(_ value: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: value); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }
    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        nextID += 1
        try send(["id": nextID, "method": method, "params": params])
        while true {
            let value = try line()
            guard value["id"] as? Int == nextID else { continue }
            guard value["error"] == nil, let result = value["result"] as? [String: Any] else { throw Self.failure() }
            return result
        }
    }
    private func line() throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let data = buffer[..<newline]; buffer.removeSubrange(...newline)
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Self.failure() }
                return value
            }
            guard ProcessInfo.processInfo.systemUptime < deadline, buffer.count < 4_194_304, received < 67_108_864 else { throw Self.failure() }
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; throw Self.failure() }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(fd.fd, &bytes, bytes.count)
            guard count > 0 else { throw Self.failure() }
            buffer.append(contentsOf: bytes.prefix(count)); received += count
        }
    }
    func close() {
        try? input.fileHandleForWriting.close()
        // Only the metadata helper started by this reader belongs to this connection.
        if process.isRunning { process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
    }
}
