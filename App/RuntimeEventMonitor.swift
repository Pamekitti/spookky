import Foundation
import Darwin

@MainActor final class RuntimeEventMonitor {
    let eventFile: URL
    private var rootSource: DispatchSourceFileSystemObject?
    private var eventSource: DispatchSourceFileSystemObject?
    private var eventIdentity: UInt64?
    private var lastModification: Date?
    private var socketExists = false
    private let root: URL
    private let socket: URL
    var onChange: (() -> Void)?

    init(root: URL) throws {
        self.root = root
        eventFile = root.appendingPathComponent("runtime-event")
        socket = root.appendingPathComponent("socket")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try watchEventFile()
        lastModification = modification()
        socketExists = FileManager.default.fileExists(atPath: socket.path)
        rootSource = try watch(root)
    }
    private func watch(_ url: URL) throws -> DispatchSourceFileSystemObject {
        let descriptor = open(url.path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .attrib, .delete, .rename], queue: .main)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in Task { @MainActor in self?.changed() } }
        source.resume()
        return source
    }
    private func identity() -> UInt64? {
        var info = stat()
        guard lstat(eventFile.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return UInt64(info.st_ino)
    }
    private func watchEventFile() throws {
        if !FileManager.default.fileExists(atPath: eventFile.path) {
            guard FileManager.default.createFile(atPath: eventFile.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        let replacement = try watch(eventFile)
        eventSource?.cancel(); eventSource = replacement; eventIdentity = identity()
    }
    private func modification() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: eventFile.path)[.modificationDate]) as? Date
    }
    private func changed() {
        let replaced = identity() != eventIdentity
        if replaced {
            do { try watchEventFile() }
            catch { eventSource?.cancel(); eventSource = nil; eventIdentity = nil }
        }
        let current = modification(), exists = FileManager.default.fileExists(atPath: socket.path)
        guard replaced || current != lastModification || exists != socketExists else { return }
        lastModification = current; socketExists = exists; onChange?()
    }
    deinit { rootSource?.cancel(); eventSource?.cancel() }
}
