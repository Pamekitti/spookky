import Foundation
import Darwin

/// One recursive metadata event stream, independent of the number of saved sessions.
@MainActor final class HistorySourceWatcher {
    var onChange: (() -> Void)?
    private let watcher = WorkspaceFileWatcher()
    private var startup: Task<Void, Never>?
    private var generation = UUID()
    private var pending: Task<Void, Never>?
    private var roots: [String] = []

    func start(roots: [String]) {
        stop(); let token = generation
        startup = Task { [weak self] in
            let resolved = await Task.detached {
                roots.map { path in
                    guard let resolved = realpath(path, nil) else { return path }
                    defer { free(resolved) }; return String(cString: resolved)
                }
            }.value
            guard let self, !Task.isCancelled, generation == token else { return }
            self.roots = resolved
            watcher.onPaths = { [weak self] in self?.changed(paths: $0) }
            watcher.watch(resolved)
        }
    }
    private func changed(paths: [String]) {
        guard paths.contains(where: { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            if roots.dropFirst().contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return true }
            guard let codex = roots.first else { return false }
            return path.hasPrefix(codex + "/sessions/") || path == codex + "/sessions" ||
                name == "session_index.jsonl" || name.hasPrefix("state_") && name.contains(".sqlite") && !name.hasSuffix("-shm")
        }) else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }; self?.onChange?()
        }
    }
    func stop() {
        generation = UUID(); startup?.cancel(); startup = nil
        pending?.cancel(); pending = nil; roots = []
        watcher.stop()
    }
}
