import Foundation
import SpookkyCore
import ImageIO
import CoreGraphics

public enum GitHubOwner {
    public static func parse(remote: String) -> String? {
        let value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if value.hasPrefix("git@github.com:") {
            path = String(value.dropFirst("git@github.com:".count))
        } else {
            guard let url = URLComponents(string: value),
                  ["https", "ssh"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.lowercased() == "github.com", url.query == nil, url.fragment == nil else { return nil }
            path = String(url.path.drop(while: { $0 == "/" }))
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        let owner = String(parts[0])
        guard valid(owner) else { return nil }
        return owner.lowercased()
    }
    public static func valid(_ owner: String) -> Bool {
        !owner.isEmpty && owner.utf8.count <= 39 && owner.first != "-" && owner.last != "-" &&
            !owner.contains("--") && owner.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
}

extension GitRepository {
    public func githubOwner(_ location: WorkspaceLocation) async throws -> String? {
        guard location.isGit else { return nil }
        let result = try await command(location.scopePath, ["remote", "get-url", "origin"])
        guard result.status == 0, !result.truncated else { return nil }
        return GitHubOwner.parse(remote: result.output)
    }
}

public protocol AvatarDownloading: Sendable {
    func download(owner: String) async throws -> Data
}

public final class AvatarHTTPClient: NSObject, AvatarDownloading, URLSessionTaskDelegate, @unchecked Sendable {
    public static let maximumBytes = 512 * 1024
    private let session: URLSession
    public override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
        super.init()
    }
    public func download(owner: String) async throws -> Data {
        guard GitHubOwner.valid(owner) else { throw URLError(.badURL) }
        let url = URL(string: "https://github.com/" + owner + ".png?size=64")!
        let (bytes, response) = try await session.bytes(from: url, delegate: self)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.mimeType?.hasPrefix("image/") == true,
              response.expectedContentLength <= Self.maximumBytes else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let allowed = request.url?.scheme == "https" && ["github.com", "avatars.githubusercontent.com"].contains(request.url?.host ?? "")
        completionHandler(allowed ? request : nil)
    }
}

private actor AvatarDownloadGate {
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if active < 2 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }
}

public actor GitHubAvatarCache {
    private struct Entry { let data: Data; let date: Date }
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let diskLimit = 10 * 1024 * 1024
    private let directory: URL
    private let downloader: any AvatarDownloading
    private let gate = AvatarDownloadGate()
    private var memory: [String: Entry] = [:]
    private var order: [String] = []
    private var pending: [String: Task<Data?, Never>] = [:]
    private var failures: [String: Date] = [:]
    public init(directory: URL, downloader: any AvatarDownloading = AvatarHTTPClient()) {
        self.directory = directory; self.downloader = downloader
    }
    public func cached(_ owner: String) -> Data? {
        guard GitHubOwner.valid(owner) else { return nil }
        if let entry = memory[owner] { touch(owner); return entry.data }
        let file = directory.appendingPathComponent(owner + ".png")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= AvatarHTTPClient.maximumBytes, let raw = try? Data(contentsOf: file),
              let data = Self.thumbnail(raw) else { return nil }
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        remember(owner, data: data, date: date)
        return data
    }
    public func image(_ owner: String, now: Date = Date()) async -> Data? {
        guard GitHubOwner.valid(owner) else { return nil }
        let existing = cached(owner)
        if let entry = memory[owner], now.timeIntervalSince(entry.date) < Self.lifetime { return existing }
        if let failed = failures[owner], now.timeIntervalSince(failed) < 60 * 60 { return existing }
        if let task = pending[owner] { return await task.value ?? existing }
        let task = Task { [downloader, gate] in
            await gate.acquire()
            let result: Data?
            do { result = Self.thumbnail(try await downloader.download(owner: owner)) } catch { result = nil }
            await gate.release()
            return result
        }
        pending[owner] = task
        let result = await task.value
        pending[owner] = nil
        if let result {
            remember(owner, data: result, date: now); failures[owner] = nil
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(owner + ".png")
            try? result.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.modificationDate: now, .posixPermissions: 0o600], ofItemAtPath: file.path)
            trimDisk()
            return result
        }
        failures[owner] = now
        // Failure metadata is derived state too.
        if failures.count > 128, let oldest = failures.min(by: { $0.value < $1.value })?.key { failures[oldest] = nil }
        return existing
    }
    private func touch(_ owner: String) { order.removeAll { $0 == owner }; order.append(owner) }
    private func remember(_ owner: String, data: Data, date: Date) {
        memory[owner] = Entry(data: data, date: date); touch(owner)
        while order.count > 32 { memory[order.removeFirst()] = nil }
    }
    private func trimDisk() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.filter { $0.pathExtension == "png" }.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries where total > Self.diskLimit {
            do { try FileManager.default.removeItem(at: entry.0); total -= entry.1 } catch { }
        }
    }
    private static func thumbnail(_ data: Data) -> Data? {
        guard data.count <= AvatarHTTPClient.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
