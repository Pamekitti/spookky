import Darwin
import Foundation
import SpookkyCore
import SpookkyGit
import SpookkyRuntime

public protocol CodexProjectConnection: Sendable {
    func request(_ method: String, params: Data) async throws -> Data
}

public enum CodexProjectError: Error, LocalizedError, Sendable {
    case unsupported, invalidResponse, limit, rejected(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported: "This Codex backend does not expose the required project metadata APIs. Execution stays in the selected checkout."
        case .invalidResponse: "Codex returned invalid project metadata."
        case .limit: "Codex project discovery exceeded its time or size limit."
        case .rejected(let message): message
        }
    }
}

public struct CodexProjectClient: Sendable {
    private let git: GitRepository
    public init(git: GitRepository = GitRepository(executor: NativeGitExecutor(timeout: 2, outputLimit: 32_768))) { self.git = git }

    public func associate(sessionID: String, resolution: ProjectAssociationResolution,
                          connection: any CodexProjectConnection,
                          isCurrent: @Sendable () async -> Bool = { true }) async -> ProviderProjectAssociation {
        func outcome(_ status: ProviderProjectAssociation.Status, _ message: String, id: String? = nil) -> ProviderProjectAssociation {
            ProviderProjectAssociation(sessionID: sessionID, projectID: id, status: status, message: message)
        }
        guard !sessionID.isEmpty, sessionID.utf8.count <= 256, !sessionID.contains("\0"),
              resolution.status == .matched, let location = resolution.location,
              let root = resolution.projectRoot, let key = resolution.key else {
            return outcome(.unavailable, resolution.message ?? "Choose an available project before associating this conversation.")
        }
        guard await isCurrent() else { return outcome(.unavailable, "The conversation changed before project association.") }
        do {
            var cursor: String?, seenCursors = Set<String>(), exact = Set<String>(), related = Set<String>()
            var roots: [String: WorkspaceLocation] = [:], attemptedRoots = Set<String>()
            let discoveryDeadline = Date().addingTimeInterval(12)
            for page in 0..<4 {
                var params: [String: Any] = ["limit": 64]
                if let cursor { params["cursor"] = cursor }
                let response = try await object(connection, "project/list", params)
                guard let projects = response["data"] as? [[String: Any]], projects.count <= 64 else { throw CodexProjectError.invalidResponse }
                for project in projects {
                    guard Date() < discoveryDeadline else { throw CodexProjectError.limit }
                    guard let id = project["id"] as? String, !id.isEmpty,
                          let paths = project["roots"] as? [[String: Any]], paths.count <= 16 else { throw CodexProjectError.invalidResponse }
                    for item in paths {
                        guard let path = item["path"] as? String, path.hasPrefix("/"), !path.contains("\0") else { throw CodexProjectError.invalidResponse }
                        guard Date() < discoveryDeadline else { throw CodexProjectError.limit }
                        if !attemptedRoots.contains(path), attemptedRoots.count >= 256 { throw CodexProjectError.limit }
                        if attemptedRoots.insert(path).inserted, let observed = try? await git.discover(URL(fileURLWithPath: path)) {
                            roots[path] = observed
                        }
                        if roots[path]?.path == root { exact.insert(id) }
                        if roots[path]?.projectAssociationKey == key { related.insert(id) }
                    }
                }
                cursor = response["nextCursor"] as? String
                if cursor == nil { break }
                guard page < 3, seenCursors.insert(cursor!).inserted else { throw CodexProjectError.limit }
            }
            let candidates = exact.isEmpty ? related : exact
            guard candidates.count == 1, let projectID = candidates.first else {
                return outcome(candidates.isEmpty ? .unregistered : .ambiguous,
                    candidates.isEmpty ? "No matching project is registered in this Codex backend. Register the intended project in Codex Desktop."
                        : "Multiple Codex projects match this repository. Project association needs an explicit choice.")
            }
            let before = try await thread(connection, sessionID)
            guard let cwd = before["cwd"] as? String,
                  let actual = try? await git.discover(URL(fileURLWithPath: cwd)),
                  actual.path == location.path, actual.checkoutIdentity == location.checkoutIdentity,
                  actual.projectAssociationKey == key else {
                return outcome(.unavailable, "The provider conversation working directory does not match this launch. No association was changed.")
            }
            if let existing = before["projectId"] as? String, !existing.isEmpty, existing != projectID {
                return outcome(.ambiguous, "This Codex conversation already belongs to another project. Its association was preserved.")
            }
            guard await isCurrent() else { return outcome(.unavailable, "The conversation changed before project association.") }
            if before["projectId"] as? String != projectID {
                _ = try await object(connection, "thread/metadata/update", ["threadId": sessionID, "projectId": projectID])
            }
            let after = try await thread(connection, sessionID)
            guard after["projectId"] as? String == projectID, let finalCwd = after["cwd"] as? String,
                  let finalLocation = try? await git.discover(URL(fileURLWithPath: finalCwd)),
                  finalLocation.path == actual.path, finalLocation.checkoutIdentity == actual.checkoutIdentity,
                  finalLocation.projectAssociationKey == key else { throw CodexProjectError.invalidResponse }
            return outcome(.associated, "Associated with the existing Codex project. Execution stays in the selected checkout.", id: projectID)
        } catch CodexProjectError.unsupported { return outcome(.unsupported, CodexProjectError.unsupported.localizedDescription) }
        catch { return outcome(.failed, "Codex project association could not be verified. The selected working directory is unchanged.") }
    }

    private func thread(_ connection: any CodexProjectConnection, _ id: String) async throws -> [String: Any] {
        let response = try await object(connection, "thread/read", ["threadId": id, "includeTurns": false])
        guard let thread = response["thread"] as? [String: Any], thread["id"] as? String == id else { throw CodexProjectError.invalidResponse }
        return thread
    }
    private func object(_ connection: any CodexProjectConnection, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: params)
        let response = try await connection.request(method, params: data)
        guard let result = try JSONSerialization.jsonObject(with: response) as? [String: Any] else { throw CodexProjectError.invalidResponse }
        return result
    }
}

// A short-lived metadata-only app-server connection. It never creates/resumes a thread or sends a turn.
public actor CodexProjectRPC: CodexProjectConnection {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let completed = DispatchSemaphore(value: 0)
    private let deadline: Date
    private var sequence = 0
    private var pending = Data()
    private var received = 0
    private var initialized = false

    public init(executable: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                directory: String? = nil, timeout: TimeInterval = 15) throws {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.environment = environment
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        self.process = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        deadline = Date().addingTimeInterval(timeout)
        let completed = self.completed
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
    }
    deinit {
        try? input.close()
        if process.isRunning, completed.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning {
            process.terminate()
            if completed.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        try? output.close()
    }
    public func close() {
        try? input.close()
        if process.isRunning, completed.wait(timeout: .now() + 0.3) == .timedOut, process.isRunning {
            process.terminate()
            if completed.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
        }
        try? output.close()
    }
    public func request(_ method: String, params: Data) async throws -> Data {
        if !initialized {
            _ = try exchange("initialize", params: ["clientInfo": ["name": "spookky_project_association", "version": "0.1"],
                                                    "capabilities": ["experimentalApi": true]])
            try write(["method": "initialized"])
            initialized = true
        }
        guard let object = try JSONSerialization.jsonObject(with: params) as? [String: Any] else { throw CodexProjectError.invalidResponse }
        return try exchange(method, params: object)
    }
    private func write(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
        try input.write(contentsOf: data)
    }
    private func exchange(_ method: String, params: [String: Any]) throws -> Data {
        sequence += 1
        try write(["id": sequence, "method": method, "params": params])
        for _ in 0..<256 {
            let line = try readLine()
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CodexProjectError.invalidResponse }
            guard message["id"] as? Int == sequence else { continue }
            if let error = message["error"] as? [String: Any] {
                if error["code"] as? Int == -32601 { throw CodexProjectError.unsupported }
                throw CodexProjectError.rejected("Codex rejected the project metadata request.")
            }
            guard let result = message["result"] else { throw CodexProjectError.invalidResponse }
            return try JSONSerialization.data(withJSONObject: result)
        }
        throw CodexProjectError.limit
    }
    private func readLine() throws -> Data {
        while true {
            try Task.checkCancellation()
            if let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline); pending.removeSubrange(...newline); return Data(line)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, received < 524_288 else { throw CodexProjectError.limit }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(min(remaining * 1000, 15_000))) > 0 else { throw CodexProjectError.limit }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            guard count > 0 else { throw CodexProjectError.invalidResponse }
            received += count; pending.append(contentsOf: bytes.prefix(count))
        }
    }
}
