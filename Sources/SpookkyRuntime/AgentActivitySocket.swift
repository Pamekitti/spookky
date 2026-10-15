import Darwin
import Foundation
import SpookkyCore

public enum AgentActivitySocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: value.sun_path) else { throw LaunchError.invalid("Activity socket path is too long.") }
        value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            target.copyBytes(from: Array(path.utf8) + [0])
        }
        return value
    }
    public static func send(_ event: AgentEvent, socket path: String) {
        guard event.isValid, let data = try? JSONEncoder().encode(event), data.count <= 8192, var endpoint = try? address(path) else { return }
        let fd = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        withUnsafePointer(to: &endpoint) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                _ = data.withUnsafeBytes { bytes in sendto(fd, bytes.baseAddress, bytes.count, 0, address, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
        }
    }
}

public final class AgentActivityReceiver: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let path: String
    private let identity: UInt64

    public init(root: URL, onEvent: @escaping @Sendable (AgentEvent) -> Void) throws {
        try PrivateFiles.directory(root)
        path = root.appendingPathComponent("activity.sock").path
        var endpoint = try AgentActivitySocket.address(path)
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw POSIXError(.EACCES) }
            let probe = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
            guard probe >= 0 else { throw POSIXError(.EIO) }
            let connected = withUnsafePointer(to: &endpoint) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            let error = errno; close(probe)
            guard connected != 0, error == ECONNREFUSED || error == ENOENT else { throw LaunchError.invalid("Activity monitoring is already owned by another app instance.") }
            guard unlink(path) == 0 else { throw POSIXError(.EACCES) }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let bound = withUnsafePointer(to: &endpoint) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { close(fd); throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        _ = chmod(path, 0o600); _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        guard lstat(path, &info) == 0 else { close(fd); throw POSIXError(.EIO) }
        identity = UInt64(info.st_ino)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "dev.spookky.agent-events", qos: .utility))
        source.setCancelHandler { close(fd) }
        source.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 8193)
            // Bound each drain so tool bursts cannot monopolize the queue.
            for _ in 0..<128 {
                let count = recv(fd, &bytes, bytes.count, 0)
                guard count > 0 else { break }
                guard count <= 8192, let event = try? JSONDecoder().decode(AgentEvent.self, from: Data(bytes.prefix(count))), event.isValid,
                      let invocation = try? AgentIntegration.read(AgentInvocation.self, path: root.path + "/agent-active-" + event.bindingID.uuidString + ".json"),
                      invocation.id == event.invocationID, invocation.context.secret == event.secret,
                      invocation.context.bindingID == event.bindingID, invocation.context.root == root.path,
                      invocation.provider == event.provider,
                      AgentIntegration.preferences(root: root.path).enabled(event.provider) else { continue }
                onEvent(event)
            }
        }
        source.resume()
    }
    deinit {
        source.cancel()
        var info = stat()
        if lstat(path, &info) == 0, UInt64(info.st_ino) == identity { _ = unlink(path) }
    }
}
