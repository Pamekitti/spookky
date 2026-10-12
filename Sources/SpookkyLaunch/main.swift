import Darwin
import Foundation
import SpookkyCore

umask(0o077)
do {
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
