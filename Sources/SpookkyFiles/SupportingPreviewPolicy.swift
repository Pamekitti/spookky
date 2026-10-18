import Foundation
import Darwin

public enum BrowserAddress: Equatable, Sendable {
    case page(URL), external(URL), invalid

    public static func parse(_ input: String) -> Self {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16_384,
              !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return .invalid }
        if text == "about:blank" { return .page(URL(string: text)!) }
        let local = text.range(of: #"^(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?([/?#]|$)"#, options: .regularExpression) != nil
        let hasScheme = text.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil
        let candidate = local ? "http://" + text : hasScheme ? text : "https://" + text
        guard let url = URL(string: candidate), url.absoluteString.utf8.count <= 16_384,
              let scheme = url.scheme?.lowercased() else { return .invalid }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return .invalid }
            return .page(url)
        }
        // Script and inline data URLs are never executable previews or external actions.
        guard !["javascript", "data", "blob", "about"].contains(scheme) else { return .invalid }
        return .external(url)
    }
}

public enum ArtifactKind: String, Sendable { case text, markdown, html, image, pdf }
public struct ArtifactPayload: Sendable {
    public let url: URL
    public let kind: ArtifactKind
    public let data: Data
}
public enum ArtifactPreviewError: LocalizedError {
    case unavailable, oversized, unsupported
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "This file is unavailable or is not a regular file."
        case .oversized: return "This file exceeds the preview size limit. Open it externally to view it."
        case .unsupported: return "This file format has no built-in preview."
        }
    }
}
public enum ArtifactPreviewPolicy {
    public static let mediaBytes = 20 * 1024 * 1024
    public static func kind(for url: URL) -> ArtifactKind? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return .markdown
        case "txt", "log", "json", "csv", "yaml", "yml", "xml", "swift", "py", "js", "css": return .text
        case "html", "htm": return .html
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp": return .image
        case "pdf": return .pdf
        default: return nil
        }
    }
    public static func read(path: String) throws -> ArtifactPayload {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ArtifactPreviewError.unavailable }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw ArtifactPreviewError.unavailable }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ArtifactPreviewError.unavailable }
        guard let kind = kind(for: url) else { throw ArtifactPreviewError.unsupported }
        let limit = kind == .image || kind == .pdf ? mediaBytes : FileService.previewBytes
        guard info.st_size <= limit else { throw ArtifactPreviewError.oversized }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 32_768)
        while data.count <= limit {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &bytes, min(bytes.count, limit + 1 - data.count))
            if count == 0 { break }
            guard count > 0 else { if errno == EINTR { continue }; throw ArtifactPreviewError.unavailable }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard data.count <= limit else { throw ArtifactPreviewError.oversized }
        return ArtifactPayload(url: url, kind: kind, data: data)
    }
    public static func sandboxedHTML(_ data: Data) throws -> String {
        guard let html = String(data: data, encoding: .utf8) else { throw ArtifactPreviewError.unsupported }
        let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; media-src data:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        return "<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"" + policy + "\"><meta charset=\"utf-8\">" + html
    }
}
