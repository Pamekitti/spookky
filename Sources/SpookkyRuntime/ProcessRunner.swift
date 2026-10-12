import Darwin
import Foundation
import SpookkyCore

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
}

public enum ProcessRunner {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10, outputLimit: Int = 1_048_576,
                           environment: [String: String]? = nil) throws -> CommandResult {
        guard (1...8_388_608).contains(outputLimit) else { throw LaunchError.invalid("Command output limit is invalid.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-command-" + UUID().uuidString)
        try PrivateFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let outputURL = root.appendingPathComponent("stdout")
        let errorURL = root.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        if completed.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 0.1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                completed.wait()
            }
            throw LaunchError.command("Command timed out: " + URL(fileURLWithPath: executable).lastPathComponent)
        }
        func read(_ url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return String(decoding: try handle.read(upToCount: outputLimit) ?? Data(), as: UTF8.self)
        }
        return try CommandResult(status: process.terminationStatus, output: read(outputURL), error: read(errorURL))
    }

    public static func asyncRun(_ executable: String, _ arguments: [String], outputLimit: Int = 1_048_576,
                                environment: [String: String]? = nil) async throws -> CommandResult {
        try await Task.detached { try run(executable, arguments, outputLimit: outputLimit, environment: environment) }.value
    }
}
