import AppKit
import GhosttyKit
import SpookkyCore
import SpookkyRuntime

@MainActor extension TerminalSurfaceManager {
    func fixtureHistoryMarker(_ id: UUID) -> Int? {
        let prefix = "SPOOKKY_M1_FIXTURE_HISTORY_"
        guard let line = view(id)?.visibleText().split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }),
              let token = line.split(separator: " ").first else { return nil }
        return Int(token.dropFirst(prefix.count))
    }
    func scrollFixtureHistory(_ id: UUID, offset: Int? = 25, binding: SessionBinding?, runtime: any SessionRuntime) async throws {
        guard let owner = runtime as? any SessionViewportRuntime,
              let binding, let surface = view(id)?.surface else { throw LaunchError.invalid("Fixture terminal is unavailable.") }
        let size = ghostty_surface_size(surface)
        try await owner.restoreViewport(SessionViewport(historySize: 0, scrollOffset: 0), binding: binding, columns: Int(size.columns), rows: Int(size.rows))
        let baseline = try await owner.viewport(binding)
        let distance = offset ?? max(1, (baseline?.historySize ?? 0) / 2)
        try await owner.restoreViewport(SessionViewport(historySize: baseline?.historySize ?? 0, scrollOffset: distance), binding: binding, columns: Int(size.columns), rows: Int(size.rows))
        await captureViewport(id)
    }
}
