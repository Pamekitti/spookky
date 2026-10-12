import Darwin
import Foundation
import SpookkyCore

public struct GitExecutionContext: Sendable {
    public let root: URL
    public let operationID: UUID
    public let commandID: UUID
    public init(root: URL, operationID: UUID, commandID: UUID = UUID()) { self.root = root; self.operationID = operationID; self.commandID = commandID }
    var path: URL { root.appendingPathComponent(operationID.uuidString).appendingPathComponent(commandID.uuidString + ".json") }
}
struct GitProcessIdentity: Codable, Equatable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
    static func read(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), info.pbi_pgid == pid else { return nil }
        return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
}
private struct GitExecutionRecord: Codable {
    let operationID: UUID
    let commandID: UUID
    var identity: GitProcessIdentity?
    var finished: Bool
}
public enum GitExecutionJournal {
    static func record(_ context: GitExecutionContext, identity: GitProcessIdentity?, finished: Bool) throws {
        try PrivateFiles.directory(context.path.deletingLastPathComponent())
        try PrivateFiles.write(GitExecutionRecord(operationID: context.operationID, commandID: context.commandID, identity: identity, finished: finished), to: context.path)
    }
    public static func hasLiveCommands(root: URL, operationID: UUID) throws -> Bool {
        let folder = root.appendingPathComponent(operationID.uuidString)
        guard FileManager.default.fileExists(atPath: folder.path) else { return false }
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let data = try Data(contentsOf: file)
            guard data.count <= 4096 else { throw LaunchError.invalid("Git execution receipt is invalid.") }
            let record = try JSONDecoder().decode(GitExecutionRecord.self, from: data)
            guard record.operationID == operationID else { throw LaunchError.ownershipMismatch }
            guard let identity = record.identity else {
                if !record.finished { throw LaunchError.invalid("Git startup was interrupted before process ownership was saved. Inspect the operation before retrying.") }
                continue
            }
            if GitProcessIdentity.read(identity.pid) == identity { return true }
            if kill(-identity.pid, 0) == 0 && !record.finished { throw LaunchError.invalid("Git helpers may still be running. Operation outcome remains uncertain.") }
        }
        return false
    }
    public static func cancel(root: URL, operationID: UUID) throws {
        let folder = root.appendingPathComponent(operationID.uuidString)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let data = try Data(contentsOf: file)
            guard data.count <= 4096 else { throw LaunchError.ownershipMismatch }
            let record = try JSONDecoder().decode(GitExecutionRecord.self, from: data)
            guard record.operationID == operationID else { throw LaunchError.ownershipMismatch }
            if let identity = record.identity, GitProcessIdentity.read(identity.pid) == identity { kill(-identity.pid, SIGKILL) }
        }
    }
}
