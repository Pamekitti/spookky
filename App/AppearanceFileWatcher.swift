import Foundation
import Darwin

/// Watch a bounded set of configuration files, including atomic replacement.
@MainActor final class AppearanceFileWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var paths: [String] = []
    private struct Snapshot: Equatable, Sendable {
        var files: [String: String]
        var parents: [String: String]
        var watchedPaths: Set<String>
    }
    private var observed: Snapshot?
    private var pending: Task<Void, Never>?
    private var generation = 0
    private var firstEvent: TimeInterval?
    var onChange: (() -> Void)?
    nonisolated private static func snapshot(_ paths: [String]) -> Snapshot {
        let files = Set(paths.flatMap { [$0, URL(fileURLWithPath: $0).resolvingSymlinksInPath().path] })
        var parents: [String: String] = [:]
        for path in files {
            var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" { directory.deleteLastPathComponent() }
            var value = stat()
            parents[directory.path] = stat(directory.path, &value) == 0 ? "\(value.st_dev):\(value.st_ino)" : "missing"
        }
        let signatures = Dictionary(uniqueKeysWithValues: files.map { path in
            var value = stat()
            let signature = lstat(path, &value) == 0 ? "\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec)" : "missing"
            return (path, signature)
        })
        return Snapshot(files: signatures, parents: parents, watchedPaths: files.union(parents.keys))
    }
    @discardableResult func watch(_ next: [String], force: Bool = false) async -> Bool {
        let next = Array(Set(next.prefix(64).map { URL(fileURLWithPath: $0).standardizedFileURL.path })).sorted()
        guard force || next != paths else { return false }
        generation += 1; let current = generation
        let prepared = await Task.detached(priority: .utility) {
            let snapshot = Self.snapshot(next)
            return (snapshot, snapshot.watchedPaths.compactMap { path -> Int32? in let fd = open(path, O_EVTONLY); return fd >= 0 ? fd : nil })
        }.value
        guard current == generation else { prepared.1.forEach { close($0) }; return false }
        sources.forEach { $0.cancel() }; sources.removeAll()
        paths = next; observed = prepared.0
        for fd in prepared.1 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
            source.setEventHandler { [weak self] in self?.changed() }
            source.setCancelHandler { close(fd) }; source.resume(); sources.append(source)
        }
        return true
    }
    private func changed() {
        let now = ProcessInfo.processInfo.systemUptime
        if firstEvent == nil { firstEvent = now }
        let delay = min(0.25, max(0, 1 - (now - firstEvent!)))
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            firstEvent = nil
            let paths = paths, current = generation
            let next = await Task.detached(priority: .utility) { Self.snapshot(paths) }.value
            guard current == generation, next != observed, !Task.isCancelled else { return }
            let filesChanged = next.files != observed?.files
            // Rebind when a missing parent appears, without parsing on unrelated directory writes.
            _ = await watch(paths, force: true)
            if filesChanged { onChange?() }
        }
    }
    func stop() { generation += 1; pending?.cancel(); pending = nil; sources.forEach { $0.cancel() }; sources.removeAll(); paths = [] }
}
