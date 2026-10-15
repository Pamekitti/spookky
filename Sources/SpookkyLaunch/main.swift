import Darwin
import Foundation
import SpookkyCore
import SpookkyRuntime

nonisolated(unsafe) private var agentChildPID: pid_t = 0

private func execute(_ executable: String, _ arguments: [String]) -> Never {
    let strings = ([executable] + arguments).map { strdup($0) }
    var pointers = strings + [nil]
    _ = pointers.withUnsafeMutableBufferPointer { execv(executable, $0.baseAddress!) }
    strings.forEach { free($0) }
    fputs("Spookky could not execute the CLI.\n", stderr)
    exit(127)
}

private func agentHook(_ path: String) {
    guard let invocation = try? AgentIntegration.read(AgentInvocation.self, path: path), path == invocation.path else { return }
    var data = Data()
    while let chunk = try? FileHandle.standardInput.read(upToCount: min(65_536, 1_048_577 - data.count)), !chunk.isEmpty {
        data.append(chunk)
        if data.count > 1_048_576 { return }
    }
    guard let event = AgentHookPayload.event(data: data, provider: invocation.provider, bindingID: invocation.context.bindingID,
                                            invocationID: invocation.id, secret: invocation.context.secret) else { return }
    AgentActivitySocket.send(event, socket: invocation.context.socket)
}

private func runAgent(_ arguments: [String]) throws -> Never {
    guard let first = arguments.first, let provider = SessionTool(rawValue: first), provider != .shell,
          let contextPath = ProcessInfo.processInfo.environment["SPOOKKY_ACTIVITY_CONTEXT"] else {
        throw LaunchError.invalid("An app-owned terminal context is required.")
    }
    let context = try AgentIntegration.read(AgentTerminalContext.self, path: contextPath)
    guard context.path == contextPath else { throw LaunchError.ownershipMismatch }
    var index = 1
    var explicit: String?
    if arguments.indices.contains(index), arguments[index] == "--executable" {
        guard arguments.indices.contains(index + 1) else { throw LaunchError.invalid("Missing executable.") }
        explicit = arguments[index + 1]; index += 2
    }
    guard arguments.indices.contains(index), arguments[index] == "--" else { throw LaunchError.invalid("Missing argument boundary.") }
    let original = Array(arguments.dropFirst(index + 1))
    let executable = try AgentIntegration.realExecutable(provider, context: context, explicit: explicit)
    // Nested CLI calls belong to the outer terminal agent. Native subagent hooks have their own IDs.
    if ProcessInfo.processInfo.environment["SPOOKKY_AGENT_OWNER"] != nil { execute(executable, original) }
    let enabled = AgentIntegration.preferences(root: context.root).enabled(provider) && !AgentIntegration.hooksDisabled(provider: provider, arguments: original)
    if !enabled {
        setenv("SPOOKKY_AGENT_OWNER", UUID().uuidString, 1)
        execute(executable, original)
    }
    let invocation = AgentInvocation(context: context, provider: provider)
    do {
        try PrivateFiles.write(invocation, to: URL(fileURLWithPath: invocation.path))
        try PrivateFiles.write(invocation, to: URL(fileURLWithPath: context.activePath))
    } catch {
        setenv("SPOOKKY_AGENT_OWNER", invocation.id.uuidString, 1)
        execute(executable, original)
    }
    let supported = enabled && AgentIntegration.supported(provider: provider, executable: executable, root: context.root)
    var final = original
    setenv("SPOOKKY_AGENT_OWNER", invocation.id.uuidString, 1)
    if supported {
        final = try AgentIntegration.hookArguments(provider: provider, invocation: invocation, original: original)
    }
    // A provider hook must confirm attachment. Process presence alone is unknown activity.
    AgentActivitySocket.send(invocation.event(.unsupported), socket: context.socket)
    let strings = ([executable] + final).map { strdup($0) }
    defer { strings.forEach { free($0) } }
    var pointers = strings + [nil]
    var child: pid_t = 0
    let error = pointers.withUnsafeMutableBufferPointer { posix_spawn(&child, executable, nil, nil, $0.baseAddress!, environ) }
    guard error == 0 else { throw POSIXError(.init(rawValue: error) ?? .EIO) }
    agentChildPID = child
    signal(SIGINT, SIG_IGN); signal(SIGQUIT, SIG_IGN)
    signal(SIGTERM) { value in if agentChildPID > 0 { _ = kill(agentChildPID, value) } }
    signal(SIGHUP) { value in if agentChildPID > 0 { _ = kill(agentChildPID, value) } }
    var result: Int32 = 0
    while waitpid(child, &result, 0) < 0 { if errno != EINTR { throw POSIXError(.ECHILD) } }
    agentChildPID = 0
    let code = (result & 0x7f) == 0 ? (result >> 8) & 0xff : 128 + (result & 0x7f)
    if code != 0 { AgentActivitySocket.send(invocation.event(code >= 128 ? .interrupted : .failed), socket: context.socket) }
    AgentActivitySocket.send(invocation.event(.detached), socket: context.socket)
    try? FileManager.default.removeItem(atPath: invocation.path)
    exit(code)
}

umask(0o077)
if CommandLine.arguments == [CommandLine.arguments[0], "--agent-hook-current"] {
    if let contextPath = ProcessInfo.processInfo.environment["SPOOKKY_ACTIVITY_CONTEXT"],
       let owner = ProcessInfo.processInfo.environment["SPOOKKY_AGENT_OWNER"],
       let context = try? AgentIntegration.read(AgentTerminalContext.self, path: contextPath), context.path == contextPath,
       let invocation = try? AgentIntegration.read(AgentInvocation.self, path: context.activePath),
       invocation.context.bindingID == context.bindingID, invocation.context.secret == context.secret,
       invocation.context.root == context.root, invocation.id.uuidString == owner {
        agentHook(invocation.path)
    }
    exit(0)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--agent-hook" {
    agentHook(CommandLine.arguments[2]); exit(0)
}
do {
    if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--agent-run" {
        try runAgent(Array(CommandLine.arguments.dropFirst(2)))
    }
    guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--request" else {
        throw LaunchError.invalid("Usage: spookky-launch --request private-request.json")
    }
    let path = CommandLine.arguments[2]
    var status = stat()
    guard lstat(path, &status) == 0, status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFREG,
          status.st_mode & 0o077 == 0, status.st_size <= 1_048_576 else {
        throw LaunchError.invalid("Launch request is not a private regular file.")
    }
    let request = try JSONDecoder().decode(HelperRequest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    guard unlink(path) == 0 else { throw POSIXError(.EIO) }
    let spec = request.spec
    let folderProbe = spec.environment["SPOOKKY_M0_FOLDER_PROBE"] == "1"
    if folderProbe { FileHandle.standardError.write(Data("SPOOKKY_FOLDER_CHDIR_BEGIN\n".utf8)) }
    guard chdir(spec.directory) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .ENOENT) }
    if folderProbe { FileHandle.standardError.write(Data("SPOOKKY_FOLDER_CHDIR_END\n".utf8)) }
    for (key, value) in spec.environment { setenv(key, value, 1) }
    let resultURL = URL(fileURLWithPath: request.resultPath)
    try PrivateFiles.write(ExecutionReceipt(operationID: spec.operationID, processID: getpid(), state: "executing"), to: resultURL)
    let arguments = ([spec.executable] + spec.arguments).map { strdup($0) }
    defer { arguments.forEach { free($0) } }
    var pointers = arguments + [nil]
    _ = pointers.withUnsafeMutableBufferPointer { pointer in
        execv(spec.executable, pointer.baseAddress!)
    }
    let failure = errno
    try? PrivateFiles.write(ExecutionReceipt(operationID: spec.operationID, processID: getpid(), state: "execFailed", errorNumber: failure), to: resultURL)
    throw POSIXError(.init(rawValue: failure) ?? .EIO)
} catch {
    FileHandle.standardError.write(Data(("Spookky launch failed: \(error.localizedDescription)\n").utf8))
    exit(127)
}
