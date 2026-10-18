import Foundation
import SpookkyCore

public enum ProviderResumeRoute: Equatable, Sendable {
    /// The native provider decides whether its saved conversation can be opened.
    case providerArbitrated
    /// Diagnostic provider metadata. These PIDs are not Spookky bindings or Stop targets.
    case interactiveOwner(processIDs: [Int32])
    case backgroundOwner
    case unknown
}

public struct ProviderOwnershipAssessment: Equatable, Sendable {
    public let route: ProviderResumeRoute
    public let explanation: String
    public let nativeAttachID: String?
    public var canInvokeNativeResume: Bool { route == .providerArbitrated }
    public var canContinue: Bool {
        canInvokeNativeResume || (route == .backgroundOwner && nativeAttachID.map(ProviderContinuationCapabilities.validAttachID) == true)
    }

    public init(route: ProviderResumeRoute, explanation: String, nativeAttachID: String? = nil) {
        self.route = route; self.explanation = explanation; self.nativeAttachID = nativeAttachID
    }

    public func continuationSpec(capabilities: ProviderContinuationCapabilities, sessionID: String,
                                 executable: LaunchSpec) throws -> LaunchSpec {
        guard capabilities.provider == executable.tool, executable.arguments.isEmpty,
              sessionID.utf8.count == 36, UUID(uuidString: sessionID) != nil else {
            throw LaunchError.invalid("An exact provider conversation and unwrapped executable are required.")
        }
        switch route {
        case .providerArbitrated:
            return try capabilities.resumeSpec(sessionID: sessionID, originalDirectory: executable.directory,
                                               executable: executable.executable, environment: executable.environment)
        case .backgroundOwner:
            guard let nativeAttachID else { throw LaunchError.invalid(explanation) }
            return try capabilities.attachSpec(attachID: nativeAttachID, originalDirectory: executable.directory,
                                               executable: executable.executable, environment: executable.environment)
        case .interactiveOwner, .unknown:
            throw LaunchError.invalid(explanation)
        }
    }
}

public enum ProviderOwnershipCheck {
    public static func assess(_ executable: LaunchSpec, sessionID: String) async -> ProviderOwnershipAssessment {
        guard validID(sessionID, provider: executable.tool), executable.arguments.isEmpty else {
            return unknown("An exact provider session ID and an unwrapped provider executable are required.")
        }
        do {
            let capabilities = try await ProviderContinuationCapabilities.inspect(executable)
            return await assess(executable, sessionID: sessionID, capabilities: capabilities)
        } catch {
            return unknown("The provider's installed resume interface could not be checked. Retry or check its installation.")
        }
    }

    public static func assess(_ executable: LaunchSpec, sessionID: String,
                              capabilities: ProviderContinuationCapabilities) async -> ProviderOwnershipAssessment {
        guard validID(sessionID, provider: executable.tool), executable.arguments.isEmpty,
              capabilities.provider == executable.tool, capabilities.exactResume else {
            return unknown("The installed provider does not advertise exact-ID resume. Check its installed help.")
        }
        switch executable.tool {
        case .codex:
            return ProviderOwnershipAssessment(route: .providerArbitrated,
                explanation: "Open this exact saved conversation with native Codex resume. Codex controls access to its conversation and reports a conflicting writer in its terminal.")
        case .claude:
            guard capabilities.ownershipReporting else {
                return claudeFallback("This Claude CLI does not advertise per-session ownership reporting.")
            }
            return await Task.detached {
                var environment = ProcessInfo.processInfo.environment
                environment.merge(executable.environment) { _, supplied in supplied }
                do {
                    let result = try ProcessRunner.run(executable.executable, ["agents", "--json"], timeout: 3,
                                                       outputLimit: 262_145, environment: environment)
                    guard result.status == 0 else { return claudeFallback("Claude could not report per-session ownership.") }
                    return claudeAssessment(json: Data(result.output.utf8), sessionID: sessionID,
                                            supportsAttach: capabilities.backgroundAttach)
                } catch { return claudeFallback("Claude could not report per-session ownership.") }
            }.value
        case .shell:
            return unknown("A shell does not have a provider conversation to resume.")
        }
    }

    public static func claudeAssessment(json: Data, sessionID: String, supportsAttach: Bool = true) -> ProviderOwnershipAssessment {
        struct Row: Decodable {
            let kind: String
            let sessionId: String?
            let id: String?
            let pid: Int32?
            let state: String?
        }
        guard validID(sessionID, provider: .claude) else {
            return unknown("An exact Claude conversation UUID is required.")
        }
        guard json.count <= 262_144, let rows = try? JSONDecoder().decode([Row].self, from: json), rows.count <= 1_024 else {
            return claudeFallback("Claude returned unsupported ownership metadata.")
        }
        let matching = rows.filter { $0.sessionId?.lowercased() == sessionID.lowercased() }
        let interactive = matching.filter { $0.kind == "interactive" }.compactMap { row -> Int32? in
            guard let pid = row.pid, pid > 0 else { return nil }
            return pid
        }
        if !interactive.isEmpty {
            return ProviderOwnershipAssessment(route: .interactiveOwner(processIDs: Array(Set(interactive)).sorted()),
                explanation: "This conversation is open in another Claude terminal. Return there and close or release it before resuming here.")
        }
        let background = matching.filter { $0.kind == "background" && (($0.pid ?? 0) > 0 || ["working", "blocked", "running", "idle"].contains($0.state ?? "")) }
        if !background.isEmpty {
            let ids = Set(background.compactMap { $0.id }.filter(ProviderContinuationCapabilities.validAttachID))
            if supportsAttach, ids.count == 1, let id = ids.first,
               background.allSatisfy({ $0.id == id }) {
                return ProviderOwnershipAssessment(route: .backgroundOwner,
                    explanation: "Attach to this conversation's existing Claude background session.", nativeAttachID: id)
            }
            return ProviderOwnershipAssessment(route: .backgroundOwner,
                explanation: "Claude reports this conversation in a background session, but its exact attach route is unavailable. Open it through Claude's native agent view.")
        }
        return claudeFallback("Claude did not report an active owner for this conversation.")
    }

    private static func validID(_ id: String, provider: SessionTool) -> Bool {
        switch provider {
        case .codex, .claude: id.utf8.count == 36 && UUID(uuidString: id) != nil
        case .shell: false
        }
    }
    private static func claudeFallback(_ reason: String) -> ProviderOwnershipAssessment {
        ProviderOwnershipAssessment(route: .providerArbitrated,
            explanation: reason + " Open its exact saved ID with ordinary native resume. This does not establish exclusive cross-app ownership.")
    }
    private static func unknown(_ reason: String) -> ProviderOwnershipAssessment {
        ProviderOwnershipAssessment(route: .unknown, explanation: reason)
    }
}
