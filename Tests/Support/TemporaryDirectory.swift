import Foundation

public enum TestDirectories {
    public static func make(prefix: String, parent: URL = URL(fileURLWithPath: "/tmp")) throws -> URL {
        let root = parent.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
}
