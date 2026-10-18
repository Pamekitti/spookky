import Foundation
import SpookkyCore

public enum ProviderResumeRoute: Equatable, Sendable {
    /// The native provider arbitrates at launch. This does not assert that an owner has exited.
    case providerArbitrated
    /// Diagnostic provider metadata. These PIDs are not Spookky bindings or Stop targets.
    case interactiveOwner(processIDs: [Int32])
    case backgroundOwner
    case unknown
}

public struct ProviderOwnershipAssessment: Equatable, Sendable {
    public let route: ProviderResumeRoute
    public let explanation: String
    public var canInvokeNativeResume: Bool { route == .providerArbitrated }

    public init(route: ProviderResumeRoute, explanation: String) {
        self.route = route; self.explanation = explanation
    }
}

public enum ProviderOwnershipCheck {
    public static func assess(_ executable: LaunchSpec, sessionID: String) async -> ProviderOwnershipAssessment {
        guard validID(sessionID, provider: executable.tool), executable.arguments.isEmpty else {
            return unknown("An exact provider session ID and an unwrapped provider executable are required.")
        }
        return await Task.detached {
            var environment = ProcessInfo.processInfo.environment
            environment.merge(executable.environment) { _, supplied in supplied }
            func run(_ arguments: [String]) throws -> String {
                let result = try ProcessRunner.run(executable.executable, arguments, timeout: 3, outputLimit: 262_144, environment: environment)
                guard result.status == 0 else { throw LaunchError.invalid("Provider ownership check failed.") }
                return result.output
            }
            do {
                let version = try run(["--version"])
                switch executable.tool {
                case .codex:
                    // Competing-server rejection and same-server TUI attach are verified for this build.
                    guard version.trimmingCharacters(in: .whitespacesAndNewlines) == "codex-cli 0.162.1" else {
                        return unknown("Writer arbitration has not been verified for this Codex version. Use its native continuation controls.")
                    }
                    let help = try run(["resume", "--help"])
                    guard help.contains("[SESSION_ID]"), help.contains("--remote"), help.contains("--cd") else {
                        return unknown("The installed Codex resume interface is unsupported. Use its native continuation controls.")
                    }
                    return ProviderOwnershipAssessment(route: .providerArbitrated,
                        explanation: "Invoke exact-ID Codex resume without a prompt. Codex rejoins a conversation on the same server or refuses an independent active writer. Other Codex processes do not block this route. This does not prove ownership release.")
                case .claude:
                    guard version.trimmingCharacters(in: .whitespacesAndNewlines) == "2.1.302 (Claude Code)" else {
                        return unknown("Per-session ownership reporting has not been verified for this Claude Code version. Use its native continuation controls.")
                    }
                    return claudeAssessment(json: Data(try run(["agents", "--json"]).utf8), sessionID: sessionID)
                case .shell:
                    return unknown("A shell does not have a provider conversation to resume.")
                }
            } catch {
                return unknown("The provider could not report ownership. Return to its existing session or use its native continuation controls.")
            }
        }.value
    }

    public static func claudeAssessment(json: Data, sessionID: String) -> ProviderOwnershipAssessment {
        struct Row: Decodable {
            let kind: String
            let sessionId: String?
            let pid: Int32?
            let state: String?
        }
        guard validID(sessionID, provider: .claude), json.count <= 262_144,
              let rows = try? JSONDecoder().decode([Row].self, from: json), rows.count <= 1_024 else {
            return unknown("Claude Code returned unsupported ownership metadata. Use its native continuation controls.")
        }
        let matching = rows.filter { $0.sessionId?.lowercased() == sessionID.lowercased() }
        let interactive = matching.filter { $0.kind == "interactive" }.compactMap { row -> Int32? in
            guard let pid = row.pid, pid > 0 else { return nil }
            return pid
        }
        if !interactive.isEmpty {
            return ProviderOwnershipAssessment(route: .interactiveOwner(processIDs: Array(Set(interactive)).sorted()),
                explanation: "Claude Code reports this exact conversation open in a terminal. Return to that terminal and release it there before saved resume here.")
        }
        if matching.contains(where: { $0.kind == "background" && (($0.pid ?? 0) > 0 || ["working", "blocked"].contains($0.state ?? "")) }) {
            return ProviderOwnershipAssessment(route: .backgroundOwner,
                explanation: "Claude Code reports this exact conversation in a background session. Use claude agents and its native attach control. Spookky has not transferred ownership. Per-invocation --settings can prevent the provider's automatic attach route.")
        }
        // The supported list is positive evidence only. Ordinary --resume admitted a second
        // foreground TUI for the same UUID in the disposable competing-client check.
        return unknown("Claude Code did not report an active owner for this conversation. That snapshot does not prove release or prevent a race. Confirm the original owner has released it before using provider-native exact-ID resume.")
    }

    private static func validID(_ id: String, provider: SessionTool) -> Bool {
        switch provider {
        case .codex, .claude: id.utf8.count == 36 && UUID(uuidString: id) != nil
        case .shell: false
        }
    }
    private static func unknown(_ reason: String) -> ProviderOwnershipAssessment {
        ProviderOwnershipAssessment(route: .unknown, explanation: reason)
    }
}
