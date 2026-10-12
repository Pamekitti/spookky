import Foundation

public enum SessionTool: String, Codable, Sendable {
    case shell, codex, claude

    public var displayName: String {
        switch self { case .shell: "Terminal"; case .codex: "Codex"; case .claude: "Claude Code" }
    }
}

public enum LaunchError: Error, LocalizedError, Sendable {
    case invalid(String)
    case command(String)
    case ownershipMismatch
    case uncertainLaunch
    case folderUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .command(let message): message
        case .ownershipMismatch: "Session ownership could not be verified. No process was stopped."
        case .uncertainLaunch: "A previous launch may have run. Inspect the session before starting again."
        case .folderUnavailable(let path): "Launch folder is unavailable: " + path
        }
    }
}

public struct LaunchSpec: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let tool: SessionTool
    public let executable: String
    public let arguments: [String]
    public let directory: String
    public let environment: [String: String]

    public init(operationID: UUID = UUID(), tool: SessionTool, executable: String,
                arguments: [String] = [], directory: String,
                environment: [String: String] = [:], initialPrompt: String? = nil) throws {
        guard executable.hasPrefix("/"), directory.hasPrefix("/") else {
            throw LaunchError.invalid("Executable and directory must be absolute paths.")
        }
        guard tool != .shell || initialPrompt == nil else {
            throw LaunchError.invalid("A shell launch cannot receive an agent prompt.")
        }
        let finalArguments = arguments + (initialPrompt.map { ["--", $0] } ?? [])
        guard !([executable, directory] + finalArguments).contains(where: { $0.contains("\0") }),
              !environment.contains(where: { $0.key.contains("=") || $0.key.contains("\0") || $0.value.contains("\0") }) else {
            throw LaunchError.invalid("Launch values contain an invalid null byte or environment key.")
        }
        self.operationID = operationID
        self.tool = tool
        self.executable = executable
        self.arguments = finalArguments
        self.directory = directory
        self.environment = environment
    }
}

public struct SessionBinding: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let token: UUID
    public let name: String
    public let tool: SessionTool
    public let directory: String
    public var phase: LaunchPhase

    public init(spec: LaunchSpec, token: UUID = UUID(), phase: LaunchPhase = .intent) {
        id = spec.operationID
        self.token = token
        name = "spookky-" + spec.operationID.uuidString.lowercased()
        tool = spec.tool
        directory = spec.directory
        self.phase = phase
    }
}

public enum LaunchPhase: String, Codable, Sendable {
    case intent, starting, attachedRuntime, ended, unavailable, closed
}

public struct SessionObservation: Sendable {
    public let binding: SessionBinding
    public let processID: Int32
    public let dead: Bool
    public let exitCode: Int?
    public let clients: Int
    public let currentDirectory: String?

    public init(binding: SessionBinding, processID: Int32, dead: Bool, exitCode: Int?, clients: Int, currentDirectory: String? = nil) {
        self.binding = binding
        self.processID = processID
        self.dead = dead
        self.exitCode = exitCode
        self.clients = clients
        self.currentDirectory = currentDirectory
    }
}

public struct HelperRequest: Codable, Sendable {
    public let spec: LaunchSpec
    public let resultPath: String
    public init(spec: LaunchSpec, resultPath: String) {
        self.spec = spec
        self.resultPath = resultPath
    }
}

public struct ExecutionReceipt: Codable, Sendable {
    public let operationID: UUID
    public let processID: Int32
    public let state: String
    public let errorNumber: Int32?
    public init(operationID: UUID, processID: Int32, state: String, errorNumber: Int32? = nil) {
        self.operationID = operationID
        self.processID = processID
        self.state = state
        self.errorNumber = errorNumber
    }
}

public protocol SessionRuntime: Sendable {
    func create(_ spec: LaunchSpec) async throws -> SessionBinding
    func inspect(_ binding: SessionBinding) async throws -> SessionObservation?
    func list() async throws -> [SessionBinding]
    func attachmentArguments(_ binding: SessionBinding) async throws -> [String]
    func terminate(_ binding: SessionBinding) async throws
}
public struct SessionViewport: Codable, Equatable, Sendable {
    public let historySize: Int
    public let scrollOffset: Int
    public let anchor: ViewportAnchor?
    public init(historySize: Int, scrollOffset: Int, anchor: ViewportAnchor? = nil) {
        self.historySize = historySize; self.scrollOffset = scrollOffset; self.anchor = anchor
    }
}
public struct ViewportAnchor: Codable, Equatable, Sendable {
    public let digest: String
    public let logicalLine: Int
    public let contentOffset: Int
    public var isValid: Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
            (0...10000).contains(logicalLine) && (0...10_485_760).contains(contentOffset)
    }
    public init(digest: String, logicalLine: Int, contentOffset: Int) {
        self.digest = digest; self.logicalLine = logicalLine; self.contentOffset = contentOffset
    }
}
public protocol SessionViewportRuntime: SessionRuntime {
    func viewport(_ binding: SessionBinding) async throws -> SessionViewport?
    func restoreViewport(_ viewport: SessionViewport, binding: SessionBinding, columns: Int, rows: Int) async throws
}
