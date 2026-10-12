import AppKit
import CoreServices

final class WorkspaceFileWatcher {
    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?
    private var firstEvent: TimeInterval?
    private var paths: [String] = []
    var isWatching: Bool { stream != nil }
    var onChange: (() -> Void)?
    func watch(_ paths: [String]) {
        guard self.paths != paths else { return }; stop(); self.paths = paths
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<WorkspaceFileWatcher>.fromOpaque(info).takeUnretainedValue().invalidate()
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); FSEventStreamStart(stream) }
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
        debounce?.cancel(); debounce = nil; firstEvent = nil; paths = []
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }; stream = nil
    }
    deinit { stop() }
}
