import Foundation

public enum ConversationLinks {
    public static func target(for url: URL, scopePath: String) -> SupportingTarget? {
        guard url.absoluteString.utf8.count <= 16_384 else { return nil }
        switch url.scheme?.lowercased() {
        case "http", "https":
            guard url.host?.isEmpty == false else { return nil }
            return .browser(url: url.absoluteString)
        case "file":
            guard url.host == nil || url.host == "" || url.host == "localhost",
                  !url.path.contains("\0"), scopePath.hasPrefix("/"), !scopePath.contains("\0") else { return nil }
            let path = url.standardizedFileURL.path
            let artifacts: Set<String> = ["html", "htm", "md", "markdown", "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tif", "tiff", "bmp"]
            if artifacts.contains(url.pathExtension.lowercased()) { return .artifact(path: path) }
            let root = URL(fileURLWithPath: scopePath).standardizedFileURL.path
            let prefix = root == "/" ? "/" : root + "/"
            guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
            return .file(path: String(path.dropFirst(prefix.count)))
        default:
            return nil
        }
    }
}
