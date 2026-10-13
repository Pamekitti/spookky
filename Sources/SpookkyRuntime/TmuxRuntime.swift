import Foundation
import SpookkyCore

public actor TmuxRuntime: SessionViewportRuntime, SessionMouseRuntime {
    public let executable: String
    public let root: URL
    public let socket: String
    private let helper: String
    private let config: String
    private var creating: Set<UUID> = []
    private static let eventHookNames = ["pane-died", "client-attached", "client-detached", "session-closed"]
    private let eventHook: String?
    private var eventsInstalled = false
    private let actionLog: URL?
    private var actions: [[String: String]] = []

    public init(executable: String, helper: String, root: URL, eventFile: URL? = nil, actionLog: URL? = nil) throws {
        self.executable = executable
        self.helper = helper
        self.root = root
        if let actionLog, actionLog.deletingLastPathComponent().standardizedFileURL.path != root.standardizedFileURL.path {
            throw LaunchError.invalid("Runtime action log must stay inside its owned fixture root.")
        }
        self.actionLog = actionLog
        if let actionLog, let handle = try? FileHandle(forReadingFrom: actionLog) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 65_536), let saved = try? JSONDecoder().decode([[String: String]].self, from: data) {
                actions = Array(saved.suffix(128))
            }
        }
        socket = root.appendingPathComponent("socket").path
        config = root.appendingPathComponent("tmux.conf").path
        guard socket.utf8.count < 100 else { throw LaunchError.invalid("Runtime socket path is too long.") }
        try PrivateFiles.directory(root)
        var configuration = """
        set -g status off
        set -g prefix None
        set -g prefix2 None
        unbind-key -a -T prefix
        bind-key -T root S-PageUp copy-mode -u
        set -g mouse on
        set -g extended-keys on
        set -g extended-keys-format csi-u
        set -g history-limit 5000
        set -g exit-empty on
        set -g default-terminal tmux-256color
        set -g remain-on-exit on
        set -g escape-time 0
        set -g allow-passthrough on
        set -g set-clipboard external
        """
        if let eventFile {
            guard eventFile.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                  !eventFile.path.contains("\n"), !eventFile.path.contains("\r") else { throw LaunchError.invalid("Runtime notification path is invalid.") }
            let notification = ShellCommand.render(["/usr/bin/touch", eventFile.path])
            let hook = ShellCommand.render(["run-shell", "-b", notification])
            eventHook = hook
            for name in Self.eventHookNames {
                configuration += "\nset-hook -g " + name + " " + ShellCommand.render([hook])
            }
        } else { eventHook = nil }
        try configuration.write(toFile: config, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config)
    }

    private func command(_ args: [String], outputLimit: Int = 1_048_576) async throws -> CommandResult {
        try await ProcessRunner.asyncRun(executable, ["-S", socket, "-f", config] + args, outputLimit: outputLimit)
    }

    private func receiptURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }

    public func list() async throws -> [SessionBinding] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .map { try JSONDecoder().decode(SessionBinding.self, from: Data(contentsOf: $0)) }
            .filter { $0.phase != .closed }
    }

    public func create(_ spec: LaunchSpec) async throws -> SessionBinding {
        guard !creating.contains(spec.operationID) else { throw LaunchError.uncertainLaunch }
        creating.insert(spec.operationID)
        defer { creating.remove(spec.operationID) }
        var binding: SessionBinding
        if FileManager.default.fileExists(atPath: receiptURL(spec.operationID).path) {
            binding = try JSONDecoder().decode(SessionBinding.self, from: Data(contentsOf: receiptURL(spec.operationID)))
            guard binding.phase != .closed else { throw LaunchError.uncertainLaunch }
            if try await inspect(binding) != nil { return binding }
            guard binding.phase == .intent else { throw LaunchError.uncertainLaunch }
        } else {
            binding = SessionBinding(spec: spec)
            try PrivateFiles.write(binding, to: receiptURL(binding.id))
        }
        guard FileManager.default.isExecutableFile(atPath: spec.executable),
              FileManager.default.isExecutableFile(atPath: helper) else {
            throw LaunchError.invalid("Launch executable or Spookky helper is missing.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: spec.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LaunchError.folderUnavailable(spec.directory)
        }
        let request = root.appendingPathComponent("request-" + binding.id.uuidString + ".json")
        let execution = root.appendingPathComponent("exec-" + binding.id.uuidString + ".json")
        try PrivateFiles.write(HelperRequest(spec: spec, resultPath: execution.path), to: request)
        binding.phase = .starting
        try PrivateFiles.write(binding, to: receiptURL(binding.id))
        let result = try await command(["new-session", "-d", "-s", binding.name, "-x", "120", "-y", "35",
                                        "-c", spec.directory, "-e", "SPOOKKY_M0_TOKEN=" + binding.token.uuidString,
                                        helper, "--request", request.path])
        guard result.status == 0 else {
            if try await inspect(binding) != nil { return binding }
            throw LaunchError.command(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        binding.phase = .attachedRuntime
        try PrivateFiles.write(binding, to: receiptURL(binding.id))
        return binding
    }

    public func inspect(_ binding: SessionBinding) async throws -> SessionObservation? {
        let info = try await command(["list-panes", "-t", "=" + binding.name,
                                      "-F", "#{SPOOKKY_M0_TOKEN}\t#{pane_pid}\t#{pane_dead}\t#{pane_dead_status}\t#{session_attached}\t#{pane_current_path}\tSPOOKKY_PATH_END"])
        guard info.status == 0 else {
            let message = info.error.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("no server running") || message.contains("no such file or directory") ||
                message.contains("No such file or directory") || message.contains("can't find session") || message.contains("can't find window") {
                return nil
            }
            throw LaunchError.command(message.isEmpty ? "Private runtime is unavailable." : message)
        }
        let output = info.output.hasSuffix("\n") ? String(info.output.dropLast()) : info.output
        let parts = output.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6, parts[5].hasSuffix("\tSPOOKKY_PATH_END"), let pid = Int32(parts[1]) else { throw LaunchError.command("Invalid runtime response.") }
        guard parts[0] == binding.token.uuidString else { throw LaunchError.ownershipMismatch }
        if let eventHook, !eventsInstalled {
            eventsInstalled = true
            do {
                var commands: [String] = []
                for name in Self.eventHookNames {
                    if !commands.isEmpty { commands.append(";") }
                    commands += ["set-hook", "-g", name, eventHook]
                }
                let result = try await command(commands)
                guard result.status == 0 else { throw LaunchError.command(result.error) }
            } catch { eventsInstalled = false; throw error }
            return try await inspect(binding)
        }
        let directory = String(parts[5].dropLast("\tSPOOKKY_PATH_END".count))
        return SessionObservation(binding: binding, processID: pid, dead: parts[2] == "1", exitCode: Int(parts[3]), clients: Int(parts[4]) ?? 0, currentDirectory: directory.hasPrefix("/") ? directory : nil)
    }

    public func attachmentArguments(_ binding: SessionBinding) async throws -> [String] {
        guard try await inspect(binding) != nil else { throw LaunchError.invalid("Session no longer exists.") }
        return ["-S", socket, "attach-session", "-t", "=" + binding.name]
    }

    public func applicationCapturesMouse(_ binding: SessionBinding) async throws -> Bool {
        let executable = executable, socket = socket, config = config
        let result = try await Task.detached {
            try ProcessRunner.run(executable, ["-S", socket, "-f", config, "list-panes", "-t", "=" + binding.name,
                "-F", "#{SPOOKKY_M0_TOKEN}|#{pane_in_mode}|#{mouse_any_flag}"], timeout: 0.15, outputLimit: 256)
        }.value
        guard result.status == 0 else { throw LaunchError.command(result.error) }
        let values = result.output.trimmingCharacters(in: .newlines).split(separator: "|", omittingEmptySubsequences: false)
        guard values.count == 3, ["0", "1"].contains(values[1]), ["0", "1"].contains(values[2]) else {
            throw LaunchError.command("Invalid terminal mouse state.")
        }
        guard values[0] == binding.token.uuidString else { throw LaunchError.ownershipMismatch }
        return values[1] == "0" && values[2] == "1"
    }

    public func terminate(_ binding: SessionBinding) async throws {
        if try await inspect(binding) != nil {
            if let actionLog {
                actions.append(["time": Date().ISO8601Format(), "action": "terminate", "id": binding.id.uuidString, "session": binding.name])
                actions = Array(actions.suffix(128))
                try PrivateFiles.write(actions, to: actionLog)
            }
            let result = try await command(["kill-session", "-t", "=" + binding.name])
            guard result.status == 0 else { throw LaunchError.command(result.error) }
        }
        var closed = binding
        closed.phase = .closed
        try PrivateFiles.write(closed, to: receiptURL(binding.id))
        for prefix in ["request-", "exec-"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(prefix + binding.id.uuidString + ".json"))
        }
    }
    public func viewport(_ binding: SessionBinding) async throws -> SessionViewport? {
        let result = try await command(["list-panes", "-t", "=" + binding.name, "-F",
            "#{SPOOKKY_M0_TOKEN}|#{pane_in_mode}|#{scroll_position}|#{history_size}"])
        guard result.status == 0 else { throw LaunchError.command(result.error) }
        let values = result.output.trimmingCharacters(in: .newlines).split(separator: "|", omittingEmptySubsequences: false)
        guard values.count == 4, values[0] == binding.token.uuidString else { throw LaunchError.ownershipMismatch }
        guard values[1] == "1", let offset = Int(values[2]), let history = Int(values[3]) else { return nil }
        if let snapshot = try await viewportGrid(binding) {
            guard snapshot.inMode else { return nil }
            return SessionViewport(historySize: snapshot.history, scrollOffset: snapshot.offset,
                anchor: snapshot.grid?.anchor(at: snapshot.history - snapshot.offset))
        }
        return SessionViewport(historySize: history, scrollOffset: offset)
    }
    private struct HistorySnapshot { let grid: ViewportGrid?; let history: Int; let offset: Int; let inMode: Bool }
    private func viewportGrid(_ binding: SessionBinding) async throws -> HistorySnapshot? {
        let target = "=" + binding.name + ":0.0"
        let separator = "SPOOKKY_HISTORY_BOUNDARY_" + UUID().uuidString
        let snapshot = try await command(["display-message", "-p", "-t", target,
            "#{SPOOKKY_M0_TOKEN}|#{pane_in_mode}|#{scroll_position}|#{pane_height}", ";",
            "capture-pane", "-p", "-M", "-S", "-", "-E", "-", "-t", target, ";",
            "display-message", "-p", separator, ";", "capture-pane", "-p", "-M", "-J", "-S", "-", "-E", "-", "-t", target], outputLimit: 8_388_608)
        guard snapshot.status == 0 else { throw LaunchError.command("Terminal history could not be observed.") }
        guard snapshot.output.utf8.count < 8_388_608, let headerEnd = snapshot.output.firstIndex(of: "\n") else { return nil }
        let header = snapshot.output[..<headerEnd].split(separator: "|", omittingEmptySubsequences: false)
        guard header.count == 4, header[0] == binding.token.uuidString, let rows = Int(header[3]), rows > 0 else { throw LaunchError.ownershipMismatch }
        let parts = snapshot.output[snapshot.output.index(after: headerEnd)...].components(separatedBy: separator + "\n")
        guard parts.count == 2 else { return nil }
        // Copy mode has a frozen backing grid. Live history size can grow independently.
        let physicalRows = parts[0].components(separatedBy: "\n").count - (parts[0].hasSuffix("\n") ? 1 : 0)
        let history = max(0, physicalRows - rows)
        return HistorySnapshot(grid: ViewportGrid(physical: parts[0], joined: parts[1]), history: history,
            offset: Int(header[2]) ?? 0, inMode: header[1] == "1")
    }
    public func restoreViewport(_ viewport: SessionViewport, binding: SessionBinding, columns: Int, rows: Int) async throws {
        guard (0...5000).contains(viewport.historySize), (0...5000).contains(viewport.scrollOffset), viewport.anchor?.isValid != false else {
            throw LaunchError.invalid("Saved terminal viewport is invalid.")
        }
        var history = viewport.historySize
        for _ in 0..<25 {
            try Task.checkCancellation()
            let result = try await command(["list-panes", "-t", "=" + binding.name, "-F",
                "#{SPOOKKY_M0_TOKEN}|#{pane_width}|#{pane_height}|#{history_size}"])
            let values = result.output.trimmingCharacters(in: .newlines).split(separator: "|")
            guard result.status == 0, values.count == 4, values[0] == binding.token.uuidString else { throw LaunchError.ownershipMismatch }
            history = Int(values[3]) ?? history
            if Int(values[1]) == columns, Int(values[2]) == rows { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let target = "=" + binding.name + ":0.0"
        try Task.checkCancellation()
        let frozen = try await command(["copy-mode", "-t", target])
        guard frozen.status == 0 else { throw LaunchError.command(frozen.error) }
        var offset = max(0, min(history, viewport.scrollOffset + history - viewport.historySize))
        if let anchor = viewport.anchor, let snapshot = try await viewportGrid(binding), let row = snapshot.grid?.row(for: anchor) {
            offset = max(0, min(snapshot.history, snapshot.history - row))
        }
        try Task.checkCancellation()
        var commands = ["send-keys", "-t", target, "-X", "history-bottom"]
        if offset > 0 {
            commands += [";", "send-keys", "-t", target, "-X", "-N", String(offset), "scroll-up"]
        }
        let result = try await command(commands)
        guard result.status == 0 else { throw LaunchError.command(result.error) }
    }
}
