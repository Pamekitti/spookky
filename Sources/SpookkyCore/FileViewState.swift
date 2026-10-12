import Foundation

public struct FileViewState: Codable, Equatable, Sendable {
    public var sidebar = false
    public var changes = false
    public var againstBranch = false
    public var reference: String?
    public var selectedPath: String?
    public var selectedGroup: String?
    public var expanded: [String] = []
    public var query = ""
    public var preview = false
    public var maximized = false
    public var splitDiff = false
    public var fraction = 0.5
    public var scroll = 0.0
    public init() {}
    public var isValid: Bool {
        fraction.isFinite && (0.2...0.8).contains(fraction) && scroll.isFinite && scroll >= 0 && expanded.count <= 1_000 &&
        expanded.allSatisfy(Self.safePath) && (selectedPath.map(Self.safePath) ?? true) && query.utf8.count <= 4_096
    }
    private static func safePath(_ value: String) -> Bool { !value.hasPrefix("/") && !value.contains("\0") && !value.split(separator: "/").contains("..") }
}
