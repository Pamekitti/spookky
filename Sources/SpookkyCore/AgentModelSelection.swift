import Foundation

public struct AgentModelSelection: Codable, Equatable, Sendable {
    public var model: String?
    public var effort: String?
    public var displayName: String?

    public init(model: String? = nil, effort: String? = nil, displayName: String? = nil) {
        self.model = model
        self.effort = effort
        self.displayName = displayName
    }

    public var isValid: Bool {
        [model, effort, displayName].compactMap { $0 }.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
    }
}
