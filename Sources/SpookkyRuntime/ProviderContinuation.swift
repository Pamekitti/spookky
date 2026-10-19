import Foundation
import SpookkyCore

/// Instructions only. Provider commands must be entered by the user after protecting CLI input.
public struct ProviderContinuationGuide: Equatable, Sendable {
    public let desktop: String
    public let remote: String
    public let returnToTerminal: String
}

public struct ProviderContinuationCapabilities: Equatable, Sendable {
    public let provider: SessionTool
    public let version: String
    public let desktopCommand: String?
    public let remoteCommand: String?
    public let exactResume: Bool
    public let ownershipReporting: Bool
    public let backgroundAttach: Bool
    private let codexDirectoryFlag: String?

    public init(provider: SessionTool, version: String, help: String, resumeHelp: String = "", remoteHelp: String = "",
                agentsHelp: String = "", attachHelp: String = "") {
        self.provider = provider
        self.version = String(version.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        codexDirectoryFlag = Self.advertises("--cd", in: resumeHelp) ? "--cd" : Self.advertises("-C", in: resumeHelp) ? "-C" : nil
        switch provider {
        case .codex:
            exactResume = resumeHelp.range(of: "[\\[<]SESSION[_-]?ID[\\]>]", options: [.regularExpression, .caseInsensitive]) != nil
            desktopCommand = exactResume && Self.advertises("app", in: help) ? "/app" : nil
            remoteCommand = Self.advertises("pair", in: remoteHelp) && Self.advertises("start", in: remoteHelp) ? "codex remote-control" : nil
            ownershipReporting = false; backgroundAttach = false
        case .claude:
            exactResume = Self.advertises("--resume", in: help)
            desktopCommand = exactResume && Self.advertises("--desktop", in: help) ? "/desktop" : nil
            remoteCommand = Self.advertises("--remote-control", in: help) ? "/remote-control" : nil
            ownershipReporting = Self.advertises("--json", in: agentsHelp)
            backgroundAttach = attachHelp.range(of: "attach\\s+<id(?:\\|name)?>", options: .regularExpression) != nil
        case .shell:
            exactResume = false; desktopCommand = nil; remoteCommand = nil
            ownershipReporting = false; backgroundAttach = false
        }
    }

    public static func advertises(_ token: String, in help: String) -> Bool {
        help.range(of: "(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: token) + "(?![A-Za-z0-9_-])",
                   options: .regularExpression) != nil
    }

    public static func provider(for tab: WorkspaceTab) -> SessionTool? {
        guard let binding = tab.binding else { return nil }
        let tool = tab.activity?.attached == true ? tab.activity!.provider : binding.tool
        return tool == .shell ? nil : tool
    }

    public static func inspect(_ spec: LaunchSpec) async throws -> Self {
        guard spec.tool != .shell, spec.arguments.isEmpty else {
            throw LaunchError.invalid("Choose an unwrapped Codex or Claude Code executable.")
        }
        return try await ProviderCapabilityCache.shared.inspect(spec)
    }

    public func guide(sessionID: String? = nil, directory: String, hasLiveProvider: Bool = true, hasOwnedBinding: Bool = true) throws -> ProviderContinuationGuide {
        if let sessionID {
            guard sessionID.utf8.count == 36 && UUID(uuidString: sessionID) != nil else { throw LaunchError.invalid("An exact provider session UUID is required.") }
        }
        guard directory.hasPrefix("/"), !directory.contains("\0") else { throw LaunchError.invalid("The original session folder is required.") }
        let desktop: String
        if !hasLiveProvider {
            if let sessionID, provider == .claude, desktopCommand != nil {
                desktop = "This saved conversation has no verified live Claude prompt in Spookky. After releasing its existing owner, use " +
                    ShellCommand.render(["claude", "--desktop", "--resume", sessionID]) + " from the original folder. Claude owns eligibility and refusal prompts. This panel has not launched a process or transferred ownership."
            } else if sessionID != nil, desktopCommand != nil {
                desktop = "This saved conversation has no verified live Codex prompt in Spookky. Use provider-native exact-ID resume in its original folder when ownership permits, then enter /app at an empty Codex prompt. This panel has not launched a process or transferred ownership."
            } else {
                desktop = "No verified live provider prompt or supported saved Desktop route is available. Check the primary conversation's state. This panel does not start or retry an agent."
            }
        } else if let desktopCommand {
            desktop = "Save any unsent CLI input first. At an empty provider prompt, enter " + desktopCommand + ". Follow the provider's prompts. Your primary conversation and supporting views stay in Spookky. " +
                (provider == .claude ? "Claude saves the conversation and exits its CLI when the transfer succeeds." :
                 "Codex opens the same saved chat in its desktop app. Keep using the provider's shared server; a terminal exit does not prove server ownership was released.")
        } else {
            desktop = "Desktop continuation is unavailable in this CLI. Check the provider's installed help."
        }
        let remote: String
        if !hasLiveProvider {
            remote = "Remote Control needs a live provider process or server on the original host. No remote route has been enabled for this saved entry. Restore it through the provider's supported ownership flow, then follow its Remote Control consent prompts. Keep that host awake and reachable."
        } else if let remoteCommand {
            remote = provider == .claude ?
                "At an empty Claude prompt, enter " + remoteCommand + ". Account and organization eligibility are checked by Claude. Review its consent and permission prompts. Use the URL or QR code it provides. Keep this Mac awake and the original process running. Return to this primary conversation in Spookky to continue locally." :
                "Codex exposes " + remoteCommand + " and pairing through its shared local server. Configure it in a separate terminal using the provider's instructions and eligibility checks. This does not transfer the selected conversation or prove it is attached to that server. Keep the original host awake and reachable."
        } else { remote = "Remote Control is unavailable in this CLI." }
        var returning = hasOwnedBinding
            ? "Return to this workspace and use Reconnect to check its owned primary binding and reattach a surviving process. Reconnect never starts an agent or sends a prompt. "
            : "No surviving primary binding has been verified for this saved entry. This panel does not launch or resume a process. "
        if exactResume {
            returning += "For saved history, Spookky checks available provider ownership information before native resume or attach. A hidden window or stopped terminal is not proof of release. "
            if let sessionID {
                let arguments = [provider == .codex ? "codex" : "claude"] +
                    (try nativeResumeArguments(sessionID: sessionID, originalDirectory: directory))
                returning += "In a terminal in the original folder, run " + ShellCommand.render(arguments) + ". "
            } else { returning += "Use the provider's /status to record its exact session ID and original folder before leaving. Resume that ID from the original folder. " }
            returning += "Saved resume reloads provider history. Claude resume does not establish exclusive cross-app ownership when reporting is unavailable. Unsent input and the old terminal viewport belong to the original process."
        }
        return ProviderContinuationGuide(desktop: desktop, remote: remote, returnToTerminal: returning)
    }

    /// Claude's native launcher refuses sessions still open in a terminal. Codex requires its in-session /app command.
    public func desktopSpec(sessionID: String, originalDirectory: String, executable: String,
                            environment: [String: String] = [:]) throws -> LaunchSpec {
        guard provider == .claude, desktopCommand != nil,
              sessionID.utf8.count == 36, UUID(uuidString: sessionID) != nil else {
            throw LaunchError.invalid("Use the provider's in-session Desktop command for this conversation.")
        }
        return try LaunchSpec(tool: provider, executable: executable,
            arguments: ["--desktop", "--resume", sessionID], directory: originalDirectory, environment: environment)
    }

    /// A command description for history UI. The caller must establish provider ownership before launching it.
    public func resumeSpec(sessionID: String, originalDirectory: String, executable: String,
                           environment: [String: String] = [:]) throws -> LaunchSpec {
        guard exactResume, sessionID.utf8.count == 36 && UUID(uuidString: sessionID) != nil else {
            throw LaunchError.invalid("This provider does not advertise exact-ID resume.")
        }
        let arguments = try nativeResumeArguments(sessionID: sessionID, originalDirectory: originalDirectory)
        return try LaunchSpec(tool: provider, executable: executable, arguments: arguments,
            directory: originalDirectory, environment: environment)
    }

    private func nativeResumeArguments(sessionID: String, originalDirectory: String) throws -> [String] {
        provider == .codex ? ["resume", sessionID] + (codexDirectoryFlag.map { [$0, originalDirectory] } ?? []) :
            try Self.resumeArguments(provider: provider, sessionID: sessionID, originalDirectory: originalDirectory)
    }

    public func attachSpec(attachID: String, originalDirectory: String, executable: String,
                           environment: [String: String] = [:]) throws -> LaunchSpec {
        guard provider == .claude, backgroundAttach, Self.validAttachID(attachID) else {
            throw LaunchError.invalid("This CLI does not advertise an exact background-session attach route.")
        }
        return try LaunchSpec(tool: provider, executable: executable, arguments: ["attach", attachID],
                              directory: originalDirectory, environment: environment)
    }

    public static func validAttachID(_ id: String) -> Bool {
        id.utf8.count <= 128 && id.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]*\\z", options: .regularExpression) != nil
    }

    public static func resumeArguments(provider: SessionTool, sessionID: String, originalDirectory: String) throws -> [String] {
        guard sessionID.utf8.count == 36, UUID(uuidString: sessionID) != nil else {
            throw LaunchError.invalid("An exact provider session UUID is required.")
        }
        switch provider {
        case .codex: return ["resume", sessionID, "--cd", originalDirectory]
        case .claude: return ["--resume", sessionID]
        case .shell: throw LaunchError.invalid("Choose a Codex or Claude Code session.")
        }
    }
}

private actor ProviderCapabilityCache {
    static let shared = ProviderCapabilityCache()
    private struct Key: Hashable {
        let executable: String
        let provider: String
        let version: String
        let fileIdentity: String
        let environment: Int
    }
    private var values: [Key: ProviderContinuationCapabilities] = [:]
    private var order: [Key] = []

    func inspect(_ spec: LaunchSpec) async throws -> ProviderContinuationCapabilities {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(spec.environment) { _, supplied in supplied }
        let probeEnvironment = environment
        func probe(_ arguments: [String]) async throws -> String {
            try await Task.detached {
                let result = try ProcessRunner.run(spec.executable, arguments, timeout: 3, outputLimit: 65_536,
                                                   environment: probeEnvironment)
                guard result.status == 0 else { throw LaunchError.invalid("The provider capability check failed. Check its installed help.") }
                return String((result.output + "\n" + result.error).prefix(65_536))
            }.value
        }
        let version = (try? await probe(["--version"])) ?? "Unknown"
        try Task.checkCancellation()
        let file = (try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: spec.executable).resolvingSymlinksInPath().path)) ?? [:]
        let modified = (file[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
        let identity = [file[.systemFileNumber], file[.size], modified].map { String(describing: $0) }.joined(separator: ":")
        var hasher = Hasher()
        for key in environment.keys.sorted() { hasher.combine(key); hasher.combine(environment[key]) }
        let key = Key(executable: spec.executable, provider: spec.tool.rawValue, version: version,
                      fileIdentity: identity, environment: hasher.finalize())
        if let cached = values[key] { return cached }
        let help = try await probe(["--help"])
        let resume = spec.tool == .codex ? (try? await probe(["resume", "--help"])) ?? "" : ""
        let remote = spec.tool == .codex ? (try? await probe(["remote-control", "--help"])) ?? "" : ""
        let agents = spec.tool == .claude && ProviderContinuationCapabilities.advertises("agents", in: help) ?
            (try? await probe(["agents", "--help"])) ?? "" : ""
        let attach = spec.tool == .claude && ProviderContinuationCapabilities.advertises("attach", in: help) ?
            (try? await probe(["attach", "--help"])) ?? "" : ""
        try Task.checkCancellation()
        let value = ProviderContinuationCapabilities(provider: spec.tool, version: version, help: help,
            resumeHelp: resume, remoteHelp: remote, agentsHelp: agents, attachHelp: attach)
        if values[key] == nil { order.append(key) }
        values[key] = value
        while order.count > 32 { values.removeValue(forKey: order.removeFirst()) }
        return value
    }
}
