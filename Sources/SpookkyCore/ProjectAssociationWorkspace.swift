import Foundation

extension Workspace {
    public var currentProjectAssociation: ProviderProjectAssociation? {
        guard conversationOwnershipAmbiguous != true, let conversationID, let primary = primaryTerminal,
              let result = primary.projectAssociation, result.conversationID == conversationID,
              primary.activity?.provider == conversationID.provider,
              primary.activity?.sessionID == conversationID.sessionID else { return nil }
        return result
    }
}

extension Workspace {
    func acceptsProjectAssociation(_ result: ProviderProjectAssociation, primaryTerminalID: UUID,
                                   invocationID: UUID, operationID: UUID) -> Bool {
        guard conversationOwnershipAmbiguous != true, conversationID == result.conversationID,
              self.primaryTerminalID == primaryTerminalID, let primary = primaryTerminal,
              primary.launch?.operationID == operationID, primary.activity?.invocationID == invocationID,
              primary.activity?.provider == result.provider, primary.activity?.sessionID == result.sessionID else { return false }
        return true
    }
}
