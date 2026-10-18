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

    public init(provider: SessionTool, version: String, help: String, resumeHelp: String = "", remoteHelp: String = "") {
        self.provider = provider
        self.version = String(version.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        let number = version.range(of: "[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression).map { String(version[$0]) }
        func atLeast(_ minimum: String) -> Bool {
            number.map { $0.compare(minimum, options: .numeric) != .orderedAscending } ?? false
        }
        switch provider {
        case .codex:
            exactResume = atLeast("0.162.1") && resumeHelp.contains("[SESSION_ID]") && resumeHelp.contains("--cd")
            desktopCommand = exactResume && help.contains("app") ? "/app" : nil
            remoteCommand = atLeast("0.162.1") && remoteHelp.contains("pair") && remoteHelp.contains("start") ? "codex remote-control" : nil
        case .claude:
            exactResume = atLeast("2.1.296") && help.contains("--resume")
            desktopCommand = exactResume && help.contains("--desktop") ? "/desktop" : nil
            remoteCommand = atLeast("2.1.296") && help.contains("--remote-control") ? "/remote-control" : nil
        case .shell:
            exactResume = false; desktopCommand = nil; remoteCommand = nil
        }
    }

    public static func provider(for tab: WorkspaceTab) -> SessionTool? {
        guard let binding = tab.binding else { return nil }
        let tool = tab.activity?.attached == true ? tab.activity!.provider : binding.tool
        return tool == .shell ? nil : tool
    }

    public static func inspect(_ spec: LaunchSpec) async throws -> Self {
        guard spec.tool != .shell else { throw LaunchError.invalid("Choose a Codex or Claude Code session.") }
        return try await Task.detached {
            var environment = ProcessInfo.processInfo.environment
            environment.merge(spec.environment) { _, new in new }
            func probe(_ arguments: [String]) throws -> String {
                let result = try ProcessRunner.run(spec.executable, arguments, timeout: 3, outputLimit: 65_536, environment: environment)
                guard result.status == 0 else { throw LaunchError.invalid("Provider capability check failed. Use the provider's own help in its terminal.") }
                return result.output
            }
            let version = try probe(["--version"])
            let help = try probe(["--help"])
            let resume = spec.tool == .codex ? (try? probe(["resume", "--help"])) ?? "" : ""
            let remote = spec.tool == .codex ? (try? probe(["remote-control", "--help"])) ?? "" : ""
            return Self(provider: spec.tool, version: version, help: help, resumeHelp: resume, remoteHelp: remote)
        }.value
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
            desktop = "Desktop continuation is unavailable for this CLI version. Check the provider's installed help."
        }
        let remote: String
        if !hasLiveProvider {
            remote = "Remote Control needs a live provider process or server on the original host. No remote route has been enabled for this saved entry. Restore it through the provider's supported ownership flow, then follow its Remote Control consent prompts. Keep that host awake and reachable."
        } else if let remoteCommand {
            remote = provider == .claude ?
                "At an empty Claude prompt, enter " + remoteCommand + ". Account and organization eligibility are checked by Claude. Review its consent and permission prompts. Use the URL or QR code it provides. Keep this Mac awake and the original process running. Return to this primary conversation in Spookky to continue locally." :
                "Codex exposes " + remoteCommand + " and pairing through its shared local server. Configure it in a separate terminal using the provider's instructions and eligibility checks. This does not transfer the selected conversation or prove it is attached to that server. Keep the original host awake and reachable."
        } else { remote = "Remote Control is unavailable for this CLI version." }
        var returning = hasOwnedBinding
            ? "Return to this workspace and use Reconnect to check its owned primary binding and reattach a surviving process. Reconnect never starts an agent or sends a prompt. "
            : "No surviving primary binding has been verified for this saved entry. This panel does not launch or resume a process. "
        if exactResume {
            returning += "For saved history, finish work and release the conversation in the other surface first. A hidden window or stopped terminal is not proof of release. "
            if let sessionID {
                let arguments = [provider == .codex ? "codex" : "claude"] +
                    (try Self.resumeArguments(provider: provider, sessionID: sessionID, originalDirectory: directory))
                returning += "In a terminal in the original folder, run " + ShellCommand.render(arguments) + ". "
            } else { returning += "Use the provider's /status to record its exact session ID and original folder before leaving. Resume that ID from the original folder. " }
            returning += "Saved resume reloads provider history. Do not start another writer while ownership is unknown. Unsent input and the old terminal viewport belong to the original process."
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
            throw LaunchError.invalid("This provider does not support a verified exact-ID resume.")
        }
        return try LaunchSpec(tool: provider, executable: executable,
            arguments: Self.resumeArguments(provider: provider, sessionID: sessionID, originalDirectory: originalDirectory),
            directory: originalDirectory, environment: environment)
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
