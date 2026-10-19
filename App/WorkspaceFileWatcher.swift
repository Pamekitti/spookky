import AppKit
import CoreServices

@MainActor final class WorkspaceFileWatcher {
    private let worker: Worker
    init(beforeRegistration: @escaping @Sendable () -> Void = {}) { worker = Worker(beforeRegistration: beforeRegistration) }
    private var generation = UUID()
    private var paths: [String] = []
    private var debounce: DispatchWorkItem?
    private var readiness: DispatchWorkItem?
    private var firstEvent: TimeInterval?
    private(set) var isWatching = false
    var onChange: (() -> Void)?
    var onIssue: ((String?) -> Void)?

    func watch(_ paths: [String]) {
        guard self.paths != paths else { return }
        stop(); self.paths = paths
        guard !paths.isEmpty else { return }
        let token = generation
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, generation == token, !isWatching else { return }
            onIssue?("File watching is taking too long. You can still browse files and use Refresh.")
        }
        readiness = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        worker.watch(paths, token: token) { [weak self] ready in
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == token else { return }
                if let ready {
                    readiness?.cancel(); readiness = nil; isWatching = ready
                    onIssue?(ready ? nil : "File watching is unavailable. Use Refresh to update files and changes.")
                } else { invalidate() }
            }
        }
    }
    private func invalidate() {
        let now = ProcessInfo.processInfo.systemUptime
        if firstEvent == nil { firstEvent = now }
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.firstEvent = nil; self?.onChange?() }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + min(0.25, max(0, 1 - (now - firstEvent!))), execute: item)
    }
    func stop() {
        generation = UUID(); paths = []; isWatching = false
        debounce?.cancel(); debounce = nil; firstEvent = nil
        readiness?.cancel(); readiness = nil
        worker.stop()
    }

    deinit { worker.stop() }

    // All FSEvents operations share one worker. Even a blocked filesystem registration
    // cannot block AppKit or start an unbounded number of replacement workers.
    private final class Worker: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dev.spookky.file-watcher", qos: .utility)
        private let lock = NSLock()
        private let beforeRegistration: @Sendable () -> Void
        init(beforeRegistration: @escaping @Sendable () -> Void) { self.beforeRegistration = beforeRegistration }
        private var requested = UUID()
        private var stream: FSEventStreamRef?
        private var change: (@Sendable (Bool?) -> Void)?
        private func request(_ token: UUID) { lock.lock(); requested = token; lock.unlock() }
        private func current(_ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return requested == token }
        func watch(_ paths: [String], token: UUID, change: @escaping @Sendable (Bool?) -> Void) {
            request(token)
            queue.async { [self] in
                guard current(token) else { return }
                releaseStream(); self.change = change
                beforeRegistration()
                guard current(token) else { return }
                var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
                let created = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
                    guard let info else { return }
                    Unmanaged<Worker>.fromOpaque(info).takeUnretainedValue().change?(nil)
                }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
                    FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
                stream = created
                guard current(token) else { releaseStream(); return }
                if let created {
                    FSEventStreamSetDispatchQueue(created, queue)
                    let started = FSEventStreamStart(created)
                    if !started { releaseStream() }
                    change(started)
                } else { change(false) }
            }
        }
        func stop() {
            request(UUID())
            queue.async { [self] in releaseStream() }
        }
        private func releaseStream() {
            if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
            stream = nil; change = nil
        }
        deinit { releaseStream() }
    }
}
