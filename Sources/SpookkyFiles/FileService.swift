import Foundation
import Darwin

public enum FileKind: String, Sendable { case directory, repository, regular, symlink, special, unsupported }
public struct FileEntry: Sendable, Equatable, Identifiable {
    public let path: String
    public let kind: FileKind
    public let size: Int64
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public init(path: String, kind: FileKind, size: Int64 = 0) { self.path = path; self.kind = kind; self.size = size }
}
public struct FileListing: Sendable {
    public var entries: [FileEntry]
    public var incomplete: Bool
    public var visited: Int
}
public struct FilePreview: Sendable {
    public let text: String
    public let notice: String?
    public let limited: Bool
    public init(text: String = "", notice: String? = nil, limited: Bool = false) { self.text = text; self.notice = notice; self.limited = limited }
}
public enum FileAccessError: LocalizedError {
    case unsafePath, system(String)
    public var errorDescription: String? {
        switch self { case .unsafePath: return "This path cannot be read safely inside the workspace."
        case .system(let message): return message }
    }
}

/// Descriptor-relative traversal prevents a replaced parent symlink from escaping the selected root.
public actor FileService {
    public static let previewBytes = 2 * 1024 * 1024
    public static let previewLines = 20_000
    public static let metadataBytes = 16 * 1024 * 1024
    public init() {}
    private func openPath(root: String, path: String, flags: Int32) throws -> Int32 {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains("\0"), !parts.contains(".."), !parts.contains(".git") else { throw FileAccessError.unsafePath }
        var fd = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw systemError() }
        let components = parts.filter { !$0.isEmpty && $0 != "." }
        for (index, part) in components.enumerated() {
            let next = openat(fd, String(part), (index == components.count - 1 ? flags : O_RDONLY | O_DIRECTORY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            close(fd); fd = next
            guard fd >= 0 else { throw systemError() }
        }
        return fd
    }
    private func systemError() -> FileAccessError { .system(String(cString: strerror(errno))) }
    public func list(root: String, path: String = "") throws -> FileListing {
        try Task.checkCancellation()
        let fd = try openPath(root: root, path: path, flags: O_RDONLY | O_DIRECTORY)
        guard let directory = fdopendir(fd) else { close(fd); throw systemError() }
        defer { closedir(directory) }
        var entries: [FileEntry] = [], bytes = 0, incomplete = false
        while let pointer = readdir(directory) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &pointer.pointee.d_name) { value in
                value.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }
            guard let name else { incomplete = true; continue }
            if name == "." || name == ".." || name == ".git" { continue }
            let relative = path.isEmpty ? name : path + "/" + name
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { incomplete = true; continue }
            let mode = info.st_mode & S_IFMT
            var kind: FileKind = mode == S_IFDIR ? .directory : mode == S_IFREG ? .regular : mode == S_IFLNK ? .symlink : .special
            if kind == .directory {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child >= 0 { var gitInfo = stat(); if fstatat(child, ".git", &gitInfo, AT_SYMLINK_NOFOLLOW) == 0 { kind = .repository }; close(child) }
            }
            bytes += relative.utf8.count * 2 + 256
            if bytes > Self.metadataBytes { incomplete = true; break }
            entries.append(FileEntry(path: relative, kind: kind, size: info.st_size))
        }
        entries.sort {
            let lhs = $0.kind == .directory || $0.kind == .repository, rhs = $1.kind == .directory || $1.kind == .repository
            return lhs != rhs ? lhs : $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return FileListing(entries: entries, incomplete: incomplete, visited: entries.count)
    }
    public func search(root: String, query: String, visitLimit: Int = 50_000, matchLimit: Int = 1_000) throws -> FileListing {
        var pending = [""], matches: [FileEntry] = [], visited = 0, incomplete = false, retained = 0
        while let directory = pending.popLast() {
            if !directory.isEmpty { retained -= directory.utf8.count * 2 + 64 }
            try Task.checkCancellation()
            let listing: FileListing
            do { listing = try list(root: root, path: directory) } catch is CancellationError { throw CancellationError() } catch { incomplete = true; continue }
            incomplete = incomplete || listing.incomplete
            for entry in listing.entries {
                try Task.checkCancellation(); visited += 1
                if entry.path.localizedCaseInsensitiveContains(query) { matches.append(entry) }
                if entry.kind == .directory { pending.append(entry.path); retained += entry.path.utf8.count * 2 + 64 }
                if visited >= visitLimit || matches.count >= matchLimit || retained > Self.metadataBytes / 2 {
                    return FileListing(entries: matches, incomplete: true, visited: visited)
                }
            }
        }
        return FileListing(entries: matches, incomplete: incomplete, visited: visited)
    }
    public func preview(root: String, path: String) throws -> FilePreview {
        try Task.checkCancellation()
        // Inspect the final component without following it, including when it is a symlink.
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".git", name != "..", !path.hasPrefix("/"), !path.contains("\0") else { throw FileAccessError.unsafePath }
        let directory = try openPath(root: root, path: parent, flags: O_RDONLY | O_DIRECTORY)
        defer { close(directory) }
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw systemError() }
        if info.st_mode & S_IFMT == S_IFLNK {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlinkat(directory, name, &buffer, buffer.count - 1)
            guard count >= 0 else { throw systemError() }
            return FilePreview(notice: "Symbolic link → " + String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return FilePreview(notice: "This entry is not a regular file. Text preview is unavailable.") }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw systemError() }; defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG else { throw FileAccessError.unsafePath }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 32_768)
        while data.count <= Self.previewBytes {
            try Task.checkCancellation()
            let count = read(fd, &buffer, min(buffer.count, Self.previewBytes + 1 - data.count))
            if count == 0 { break }; guard count > 0 else { if errno == EINTR { continue }; throw systemError() }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, opened.st_size == after.st_size,
              opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw FileAccessError.system("The file changed while reading. Refresh to inspect its latest content.")
        }
        return Self.decode(data)
    }
    public nonisolated static func decode(_ data: Data) -> FilePreview {
        let byteLimited = data.count > previewBytes
        var bounded = Data(data.prefix(previewBytes))
        if bounded.contains(0) { return FilePreview(notice: "Binary file. Text preview is unavailable.") }
        var text = String(data: bounded, encoding: .utf8)
        if text == nil && byteLimited {
            for _ in 0..<3 { if !bounded.isEmpty { bounded.removeLast() }; text = String(data: bounded, encoding: .utf8); if text != nil { break } }
        }
        guard let text else { return FilePreview(notice: "Unsupported text encoding. Open this file in an editor.") }
        let lines = text.split(separator: "\n", maxSplits: previewLines, omittingEmptySubsequences: false)
        let limited = byteLimited || lines.count > previewLines
        return FilePreview(text: lines.prefix(previewLines).joined(separator: "\n"), notice: limited ? "Preview limited to 2 MiB or 20,000 lines. Open in an editor for the full file." : nil, limited: limited)
    }
}
