import Foundation

extension WorkspaceLocation {
    // Discovery canonicalizes these paths off the UI thread. Never group by display name or remote URL.
    public var projectAssociationKey: ProjectAssociationKey {
        if let common = commonRepository ?? checkoutIdentity {
            return ProjectAssociationKey(kind: .repository, path: common)
        }
        return ProjectAssociationKey(kind: .folder, path: scopePath)
    }
}
