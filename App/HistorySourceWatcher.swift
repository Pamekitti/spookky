import Foundation
import CoreServices
import Darwin

private final class HistoryWatchContext: @unchecked Sendable {
    weak var owner: HistorySourceWatcher?
    @MainActor init(owner: HistorySourceWatcher) { self.owner = owner }
}

/// One recursive metadata event stream, independent of the number of saved sessions.
@MainActor final class HistorySourceWatcher {
    var onChange: (() -> Void)?
    private var stream: FSEventStreamRef?
    private var pending: Task<Void, Never>?
    private var roots: [String] = []

    func start(roots: [String]) {
        stop(); self.roots = roots.map { path in
            guard let resolved = realpath(path, nil) else { return path }
            defer { free(resolved) }; return String(cString: resolved)
        }
        guard !roots.isEmpty else { return }
        let box = HistoryWatchContext(owner: self)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil, release: { pointer in
                if let pointer { Unmanaged<HistoryWatchContext>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, pointer, _, pathsPointer, _, _ in
            guard let pointer else { return }
            let box = Unmanaged<HistoryWatchContext>.fromOpaque(pointer).takeUnretainedValue()
            let paths = unsafeBitCast(pathsPointer, to: NSArray.self) as? [String] ?? []
            Task { @MainActor in box.owner?.changed(paths: paths) }
        }
        guard let created = FSEventStreamCreate(nil, callback, &context, self.roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)) else {
            Unmanaged<HistoryWatchContext>.fromOpaque(context.info!).release()
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
        if !FSEventStreamStart(created) { stop() }
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
        pending?.cancel(); pending = nil
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
