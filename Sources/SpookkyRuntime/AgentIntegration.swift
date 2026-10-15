import Darwin
import Foundation
import SpookkyCore

public struct AgentTerminalContext: Codable, Sendable {
    public let bindingID: UUID
    public let secret: UUID
    public let root: String
    public let helper: String
    public var socket: String { root + "/activity.sock" }
    public var bin: String { root + "/agent-bin" }
    public var path: String { root + "/agent-terminal-" + bindingID.uuidString + ".json" }
    public var activePath: String { root + "/agent-active-" + bindingID.uuidString + ".json" }
    public init(bindingID: UUID, secret: UUID = UUID(), root: String, helper: String) {
        self.bindingID = bindingID; self.secret = secret; self.root = root; self.helper = helper
    }
}

public struct AgentInvocation: Codable, Sendable {
    public let id: UUID
    public let context: AgentTerminalContext
    public let provider: SessionTool
    public let startedAt: TimeInterval
    public var path: String { context.root + "/agent-invocation-" + id.uuidString + ".json" }
    public init(context: AgentTerminalContext, provider: SessionTool) {
        id = UUID(); self.context = context; self.provider = provider; startedAt = Date().timeIntervalSince1970
    }
    public func event(_ kind: AgentEventKind) -> AgentEvent {
        AgentEvent(bindingID: context.bindingID, invocationID: id, secret: context.secret, provider: provider, kind: kind)
    }
}

public enum AgentIntegration {
    public static func read<T: Decodable>(_ type: T.Type, path: String, limit: Int = 16_384) throws -> T {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= limit else { throw POSIXError(.EACCES) }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw LaunchError.invalid("Activity record is too large.") }
        return try JSONDecoder().decode(type, from: data)
    }

    public static func preferences(root: String) -> AgentNotificationPreferences {
        (try? read(AgentNotificationPreferences.self, path: root + "/agent-preferences.json")) ?? AgentNotificationPreferences()
    }

    public static func prepare(_ spec: LaunchSpec, root: URL, helper: String) throws -> LaunchSpec {
        try PrivateFiles.directory(root)
        let contextPath = root.appendingPathComponent("agent-terminal-" + spec.operationID.uuidString + ".json").path
        let saved = try? read(AgentTerminalContext.self, path: contextPath)
        let context = saved.flatMap { $0.bindingID == spec.operationID && $0.root == root.path && $0.helper == helper ? $0 : nil } ??
            AgentTerminalContext(bindingID: spec.operationID, root: root.path, helper: helper)
        try PrivateFiles.write(context, to: URL(fileURLWithPath: context.path))
        let bin = URL(fileURLWithPath: context.bin)
        try PrivateFiles.directory(bin)
        for provider in [SessionTool.codex, .claude] {
            let script = "#!/bin/sh\nexec " + ShellCommand.render([helper, "--agent-run", provider.rawValue, "--"]) + " \"$@\"\n"
            let path = bin.appendingPathComponent(provider.rawValue)
            if (try? String(contentsOf: path, encoding: .utf8)) != script {
                try script.write(to: path, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            }
        }
        var environment = spec.environment
        environment["SPOOKKY_ACTIVITY_CONTEXT"] = context.path
        environment["PATH"] = context.bin + ":" + (environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        if spec.tool == .shell {
            try AgentShellIntegration.prepare(executable: spec.executable, arguments: spec.arguments, root: root, environment: &environment)
            return try LaunchSpec(operationID: spec.operationID, tool: spec.tool, executable: spec.executable,
                                  arguments: spec.arguments, directory: spec.directory, environment: environment)
        }
        return try LaunchSpec(operationID: spec.operationID, tool: spec.tool, executable: helper,
                              arguments: ["--agent-run", spec.tool.rawValue, "--executable", spec.executable, "--"] + spec.arguments,
                              directory: spec.directory, environment: environment)
    }

    public static func hookArguments(provider: SessionTool, invocation: AgentInvocation, original: [String]) throws -> [String] {
        let callback = [invocation.context.helper, "--agent-hook", invocation.path]
        var definitions: [String: [[String: Any]]] = [:]
        let events = provider == .codex
            ? ["SessionStart", "SessionEnd", "UserPromptSubmit", "PostToolUse", "PermissionRequest", "PreToolUse", "Stop", "Interrupt", "SubagentStart", "SubagentStop"]
            : ["SessionStart", "SessionEnd", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "PreToolUse", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "Notification", "Elicitation", "ElicitationResult"]
        for event in events {
            let hook: [String: Any] = provider == .claude
                ? ["type": "command", "command": callback[0], "args": Array(callback.dropFirst()), "timeout": 1]
                : ["type": "command", "command": ShellCommand.render(callback), "timeout": 1]
            var entry: [String: Any] = ["hooks": [hook]]
            if event == "PreToolUse" { entry["matcher"] = provider == .codex ? "^request_user_input$" : "^(AskUserQuestion|ExitPlanMode)$" }
            if event == "Notification" { entry["matcher"] = "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input" }
            definitions[event] = [entry]
        }
        if provider == .claude {
            let data = try JSONSerialization.data(withJSONObject: ["hooks": definitions], options: [.sortedKeys])
            return ["--settings", String(decoding: data, as: UTF8.self)] + original
        }
        // JSON strings are valid TOML basic strings; serialize the nested arrays as TOML inline tables.
        func toml(_ value: Any) throws -> String {
            if let dictionary = value as? [String: Any] {
                return "{" + (try dictionary.keys.sorted().map { try $0 + "=" + toml(dictionary[$0]!) }).joined(separator: ",") + "}"
            }
            if let array = value as? [Any] { return "[" + (try array.map(toml)).joined(separator: ",") + "]" }
            return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
        var prefix = [String]()
        if !original.prefix(while: { $0 != "--" }).contains("--dangerously-bypass-hook-trust") { prefix.append("--dangerously-bypass-hook-trust") }
        for event in definitions.keys.sorted() { prefix += ["-c", "hooks." + event + "=" + (try toml(definitions[event]!))] }
        return prefix + original
    }

    public static func hooksDisabled(provider: SessionTool, arguments: [String]) -> Bool {
        let flags = Array(arguments.prefix(while: { $0 != "--" }))
        if provider == .claude { return flags.contains("--bare") || flags.contains("--safe-mode") || flags.contains { $0.contains("\"disableAllHooks\":true") || $0.contains("\"disableAllHooks\": true") } }
        for (index, value) in flags.enumerated() {
            if value == "--disable", flags.indices.contains(index + 1), flags[index + 1] == "hooks" { return true }
            if value.contains("features.hooks=false") || value.hasPrefix("hooks.") || value.hasPrefix("hooks=") { return true }
        }
        return false
    }

    public static func realExecutable(_ provider: SessionTool, context: AgentTerminalContext, explicit: String? = nil) throws -> String {
        if let explicit, FileManager.default.isExecutableFile(atPath: explicit) { return explicit }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            guard directory.hasPrefix("/"), URL(fileURLWithPath: directory).standardizedFileURL.path != context.bin else { continue }
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(provider.rawValue)
            guard candidate.resolvingSymlinksInPath().deletingLastPathComponent().path != context.bin,
                  FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            return candidate.path
        }
        throw LaunchError.invalid(provider.displayName + " was not found on PATH.")
    }

    public static func supported(provider: SessionTool, executable: String, root: String) -> Bool {
        struct Capability: Codable { let signature: String; let supported: Bool }
        let attributes = try? FileManager.default.attributesOfItem(atPath: executable)
        let signature = "hooks-v1:" + executable + String(describing: attributes?[.modificationDate]) + String(describing: attributes?[.size])
        let cache = URL(fileURLWithPath: root + "/agent-capability-" + provider.rawValue + ".json")
        if let saved = try? read(Capability.self, path: cache.path), saved.signature == signature { return saved.supported }
        let help = try? ProcessRunner.run(executable, ["--help"], timeout: 3, outputLimit: 65_536)
        let version = try? ProcessRunner.run(executable, ["--version"], timeout: 3, outputLimit: 4096)
        let text = version?.output ?? ""
        let range = text.range(of: "[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression)
        let minimum = provider == .claude ? "2.1.296" : "0.162.1"
        let compatible = range.map { String(text[$0]).compare(minimum, options: .numeric) != .orderedAscending } ?? false
        let supported = compatible && help?.status == 0 && (provider == .claude ? help!.output.contains("--settings") : help!.output.contains("--dangerously-bypass-hook-trust"))
        try? PrivateFiles.write(Capability(signature: signature, supported: supported), to: cache)
        return supported
    }
}
