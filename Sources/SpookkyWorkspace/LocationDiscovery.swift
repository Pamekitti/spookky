import Foundation
import SpookkyCore
import SpookkyGit

public enum LocationDiscovery {
    public static func discover(_ url: URL) async throws -> WorkspaceLocation {
        try await GitRepository().discover(url)
    }
}
