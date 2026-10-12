import Darwin
import Foundation
import SpookkyCore

public struct GitResult: Sendable {
    public let status: Int32
    public let outputData: Data
    public var output: String { String(decoding: outputData, as: UTF8.self) }
    public let error: String
    public let truncated: Bool
    public init(status: Int32, output: String = "", error: String = "", truncated: Bool = false, outputData: Data? = nil) {
        self.status = status; self.outputData = outputData ?? Data(output.utf8); self.error = error; self.truncated = truncated
    }
    public func checked() throws -> String {
        try validate()
        return output
    }
    func validate() throws {
        guard !truncated else { throw LaunchError.command("Git output exceeded the supported size.") }
        guard status == 0 else {
            var message = error.isEmpty ? "Git exited with status \(status)." : String(decoding: error.utf8.prefix(4096), as: UTF8.self)
            if ["terminal prompts disabled", "Authentication failed", "Permission denied", "Host key verification failed", "could not read Username", "could not read Password"].contains(where: { message.contains($0) }) {
                message += "\nComplete Git authentication or host verification in Terminal, then explicitly retry. Existing files and form values are retained."
            }
            throw LaunchError.command(message)
        }
    }
}
public protocol GitCommandExecutor: Sendable {
    var isAvailable: Bool { get }
    func execute(_ arguments: [String]) async throws -> GitResult
    func execute(_ arguments: [String], context: GitExecutionContext) async throws -> GitResult
}
public extension GitCommandExecutor {
    var isAvailable: Bool { true }
    func execute(_ arguments: [String], context: GitExecutionContext) async throws -> GitResult { try await execute(arguments) }
}

private final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: GitProcessIdentity?
    private var cancelled = false
    func install(_ value: pid_t) {
        lock.lock(); defer { lock.unlock() }
        identity = GitProcessIdentity.read(value)
        if cancelled, let identity, GitProcessIdentity.read(identity.pid) == identity { kill(-identity.pid, SIGTERM) }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let identity, GitProcessIdentity.read(identity.pid) == identity { kill(-identity.pid, SIGTERM) }
    }
    func finish() { lock.lock(); identity = nil; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public struct NativeGitExecutor: GitCommandExecutor {
    public var isAvailable: Bool { Self.executable != nil }
    private static let executable: String? = {
        let resolver = NativeGitExecutor(timeout: 5, outputLimit: 4096)
        let result = try? resolver.run(["-p"], cancellation: CommandCancellation(), context: nil,
                                       executable: "/usr/bin/xcode-select", gitOptions: false)
        let directory = result?.status == 0 ? result?.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return availableGit(developerDirectory: directory, path: ProcessInfo.processInfo.environment["PATH"] ?? "",
                            isExecutable: FileManager.default.isExecutableFile(atPath:))
    }()
    // Apple's /usr/bin/git stub may prompt to install developer tools. Opening a folder stays passive.
    static func availableGit(developerDirectory: String?, path: String, isExecutable: (String) -> Bool) -> String? {
        var candidates: [String] = []
        if let directory = developerDirectory, directory.hasPrefix("/"), !directory.contains("\0") {
            candidates.append(directory + "/usr/bin/git")
        }
        candidates += path.split(separator: ":").prefix(64).map { String($0) + "/git" }
        candidates += ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first { candidate in
            guard candidate.hasPrefix("/"), !candidate.contains("\0"), isExecutable(candidate) else { return false }
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            return resolved != "/usr/bin/git" && resolved != "/bin/git"
        }
    }
    public let timeout: TimeInterval
    public let outputLimit: Int
    public init(timeout: TimeInterval = 120, outputLimit: Int = 1_048_576) {
        self.timeout = timeout; self.outputLimit = outputLimit
    }
    public func execute(_ arguments: [String]) async throws -> GitResult { try await execute(arguments, context: nil) }
    public func execute(_ arguments: [String], context: GitExecutionContext) async throws -> GitResult { try await execute(arguments, context: Optional(context)) }
    private func execute(_ arguments: [String], context: GitExecutionContext?) async throws -> GitResult {
        let cancellation = CommandCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached {
                guard let executable = Self.executable else {
                    throw LaunchError.invalid("Git is not installed. You can keep using shells. Install Git separately to use repository features, then reopen Spookky.")
                }
                return try run(arguments, cancellation: cancellation, context: context, executable: executable)
            }.value
        } onCancel: { cancellation.cancel() }
    }
    private func run(_ arguments: [String], cancellation: CommandCancellation, context: GitExecutionContext?, executable: String, gitOptions: Bool = true) throws -> GitResult {
        if cancellation.isCancelled { throw CancellationError() }
        guard outputLimit > 0, outputLimit <= 8_388_608, timeout > 0,
              !arguments.contains(where: { $0.contains("\0") }) else { throw LaunchError.invalid("Invalid Git command limits or arguments.") }
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw POSIXError(.EMFILE) }
        guard pipe(&err) == 0 else { close(out[0]); close(out[1]); throw POSIXError(.EMFILE) }
        var writersOpen = true
        defer { close(out[0]); close(err[0]); if writersOpen { close(out[1]); close(err[1]) } }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
        for fd in out + err { posix_spawn_file_actions_addclose(&actions, fd) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | (context == nil ? 0 : POSIX_SPAWN_START_SUSPENDED)
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        let options = gitOptions ? ["-c", "core.hooksPath=/dev/null", "-c", "protocol.ext.allow=never"] : []
        let argv = ([executable] + options + arguments).map { strdup($0) }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_SSH_COMMAND"] = environment["GIT_SSH_COMMAND"] ?? "ssh -o BatchMode=yes"
        let env = environment.map { strdup($0.key + "=" + $0.value) }
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        if let context { try GitExecutionJournal.record(context, identity: nil, finished: false) }
        var pid: pid_t = 0
        let result = (argv + [nil]).withUnsafeBufferPointer { a in
            (env + [nil]).withUnsafeBufferPointer { e in
                posix_spawn(&pid, executable, &actions, &attributes, a.baseAddress!, e.baseAddress!)
            }
        }
        close(out[1]); close(err[1]); writersOpen = false
        guard result == 0 else {
            if let context { try? GitExecutionJournal.record(context, identity: nil, finished: true) }
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        let identity = GitProcessIdentity.read(pid)
        if let context {
            do {
                guard let identity else { throw LaunchError.ownershipMismatch }
                try GitExecutionJournal.record(context, identity: identity, finished: false)
                kill(pid, SIGCONT)
            } catch {
                kill(-pid, SIGKILL); var status: Int32 = 0; waitpid(pid, &status, 0)
                throw error
            }
        }
        cancellation.install(pid)
        defer { cancellation.finish() }
        for fd in [out[0], err[0]] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        var stdout = Data(), stderr = Data(), truncated = false, status: Int32 = 0
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(timeout)
        var closed = Set<Int32>()
        var termination: Date?
        var timedOut = false
        var closedPipePolls = 0
        func drain(_ fd: Int32, _ data: inout Data) {
            for _ in 0..<32 {
                let n = read(fd, &buffer, buffer.count)
                if n == 0 { closed.insert(fd); return }
                if n < 0 { return }
                let remaining = max(0, outputLimit - data.count)
                data.append(contentsOf: buffer.prefix(min(n, remaining)))
                if n > remaining { truncated = true }
            }
        }
        while true {
            drain(out[0], &stdout); drain(err[0], &stderr)
            if waitpid(pid, &status, WNOHANG) == pid { cancellation.finish(); break }
            if cancellation.isCancelled || Date() >= deadline {
                if termination == nil {
                    timedOut = !cancellation.isCancelled
                    kill(-pid, SIGTERM); termination = Date()
                } else if Date().timeIntervalSince(termination!) > 0.2 { kill(-pid, SIGKILL) }
            }
            var descriptors = [pollfd(fd: closed.contains(out[0]) ? -1 : out[0], events: Int16(POLLIN), revents: 0), pollfd(fd: closed.contains(err[0]) ? -1 : err[0], events: Int16(POLLIN), revents: 0)]
            // A child can close its pipes just before it becomes waitable. Avoid a full
            // 20 ms delay for that exit race, then back off for children that keep running.
            if closed.count == 2 { closedPipePolls += 1 }
            _ = poll(&descriptors, 2, closed.count == 2 && closedPipePolls <= 5 ? 1 : 20)
        }
        drain(out[0], &stdout); drain(err[0], &stderr)
        if let context { try GitExecutionJournal.record(context, identity: identity, finished: true) }
        if cancellation.isCancelled { kill(-pid, SIGKILL); throw CancellationError() }
        if timedOut { kill(-pid, SIGKILL); throw LaunchError.command("Git timed out. Inspect the retained destination before retrying.") }
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return GitResult(status: code, error: String(decoding: stderr, as: UTF8.self), truncated: truncated, outputData: stdout)
    }
}

public actor GitScheduler {
    public static let shared = GitScheduler()
    private var reads = 0
    private var writes = Set<String>()
    private var destinations = Set<String>()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    private func wait() async { await withCheckedContinuation { waiters.append($0) } }
    private func wake() { let current = waiters; waiters = []; current.forEach { $0.resume() } }
    public func read<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while reads >= 2 { await wait(); try Task.checkCancellation() }
        try Task.checkCancellation(); reads += 1
        defer { reads -= 1; wake() }
        return try await body()
    }
    public func write<T: Sendable>(repository: String, _ body: @Sendable () async throws -> T) async throws -> T {
        while writes.contains(repository) { await wait(); try Task.checkCancellation() }
        try Task.checkCancellation(); writes.insert(repository)
        defer { writes.remove(repository); wake() }
        return try await body()
    }
    public func destination<T: Sendable>(_ path: String, _ body: @Sendable () async throws -> T) async throws -> T {
        while destinations.contains(path) { await wait(); try Task.checkCancellation() }
        try Task.checkCancellation(); destinations.insert(path)
        defer { destinations.remove(path); wake() }
        return try await body()
    }
}
