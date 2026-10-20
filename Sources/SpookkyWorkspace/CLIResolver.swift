import Foundation
import SpookkyCore
import SpookkyRuntime

public struct CLIResolver: ExecutableResolver {
    private let environment: [String: String]
    private let homeDirectory: URL
    private let standardDirectories: [String]

    public init() {
        self.init(environment: ProcessInfo.processInfo.environment,
                  homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    init(environment: [String: String], homeDirectory: URL,
         standardDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.standardDirectories = standardDirectories
    }

    public func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try await Task.detached {
            var directories = pathDirectories(environment["PATH"] ?? "")
            let common = [homeDirectory.appendingPathComponent(".local/bin").path] + standardDirectories
            let executable: String
            if tool == .shell {
                executable = environment["SHELL"] ?? "/bin/zsh"
            } else if let inherited = find(tool.rawValue, in: directories) {
                executable = inherited
            } else {
                directories += loginDirectories()
                let candidates = directories + common + nodeDirectories()
                guard let found = find(tool.rawValue, in: candidates) else {
                    throw LaunchError.invalid(tool.displayName + " was not found. Check its installation in Terminal, then retry. Your draft is retained.")
                }
                executable = found
            }
            // Keep the installation's bin path, even when the CLI is a symlink to a script.
            let executableDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
            var seen: Set<String> = []
            let path = ([executableDirectory] + directories + common).filter { seen.insert($0).inserted }.joined(separator: ":")
            return try LaunchSpec(tool: tool, executable: executable, arguments: tool == .shell ? ["-l"] : [],
                                  directory: directory, environment: ["PATH": path],
                                  initialPrompt: tool == .shell ? nil : prompt)
        }.value
    }

    private func pathDirectories(_ path: String) -> [String] {
        path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    }

    private func find(_ name: String, in directories: [String]) -> String? {
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: candidate.path),
                  (try? candidate.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard !isSpookkyWrapper(candidate, tool: name) else { continue }
            return candidate.path
        }
        return nil
    }

    private func isSpookkyWrapper(_ url: URL, tool: String) -> Bool {
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 <= 4096 }) == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), let script = String(data: data, encoding: .utf8) else { return false }
        let normalized = script.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
        return normalized.hasPrefix("#!/bin/sh\nexec ") && normalized.contains("'--agent-run' '" + tool + "' '--'") && normalized.hasSuffix(" \"$@\"\n")
    }

    private func loginDirectories() -> [String] {
        var loginEnvironment = environment
        loginEnvironment["HOME"] = homeDirectory.path
        // Startup messages must not become part of an executable path.
        let script = #"builtin printf '\000SPOOKKY_LOGIN_PATH\000%s\000' "$PATH""#
        guard let result = try? ProcessRunner.run("/bin/zsh", ["-l", "-c", script], timeout: 3,
                                                  outputLimit: 16_384, environment: loginEnvironment),
              result.status == 0 else { return [] }
        let fields = result.output.components(separatedBy: "\0")
        guard let marker = fields.lastIndex(of: "SPOOKKY_LOGIN_PATH"), fields.indices.contains(marker + 1) else { return [] }
        return pathDirectories(fields[marker + 1])
    }

    private func nodeDirectories() -> [String] {
        let nvm: URL
        if let configured = environment["NVM_DIR"], configured.hasPrefix("/") {
            nvm = URL(fileURLWithPath: configured)
        } else { nvm = homeDirectory.appendingPathComponent(".nvm") }
        let versions = nvm.appendingPathComponent("versions/node")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) else { return [] }
        return entries.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }.map { $0.appendingPathComponent("bin").path }
    }
}
