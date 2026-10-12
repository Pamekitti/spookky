import Foundation
import CryptoKit
import Highlighter

public enum SyntaxRole: String, Sendable { case keyword, comment, string, number, function, type, variable }
public struct SyntaxSpan: Sendable, Equatable {
    public let range: NSRange
    public let role: SyntaxRole
}
public struct SyntaxLine: Sendable {
    public let text: String
    public var spans: [SyntaxSpan]
}
public struct SyntaxDocument: Sendable {
    public let language: String
    public let lines: [SyntaxLine]
    public var cost: Int { lines.reduce(0) { $0 + $1.text.utf8.count * 2 + $1.spans.count * 48 + 96 } }
}
public enum SyntaxFailure: LocalizedError {
    case limit, unavailable
    public var errorDescription: String? {
        switch self {
        case .limit: return "Syntax colors are unavailable for this preview's size. Plain text remains available."
        case .unavailable: return "Syntax colors are unavailable. Plain text remains available."
        }
    }
}

/// Highlighter and its JavaScript context are used serially by this actor.
public actor SyntaxHighlighter {
    private var engine: Highlighter?
    private var cache: [(key: String, document: SyntaxDocument)] = []
    public var retainedBytes: Int { cache.reduce(0) { $0 + $1.document.cost } }
    public func clearCache() { cache.removeAll() }
    public init() {}
    public static func language(path: String, text: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch (name as NSString).pathExtension {
        case "swift": return "swift"
        case "py", "pyw": return "python"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "mts", "cts", "tsx": return "typescript"
        case "rs": return "rust"
        case "go": return "go"
        case "sh", "bash", "zsh": return "bash"
        case "json", "jsonc": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "ini"
        case "html", "htm": return "xml"
        case "css": return "css"
        case "sql": return "sql"
        case "md", "markdown": return "markdown"
        default: break
        }
        if [".bashrc", ".bash_profile", ".zshrc", ".zprofile"].contains(name) { return "bash" }
        let first = text.prefix(256).split(separator: "\n").first.map(String.init) ?? ""
        guard first.hasPrefix("#!") else { return nil }
        let words = first.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map { (String($0) as NSString).lastPathComponent }
        if words.contains(where: { $0 == "python" || $0.hasPrefix("python3") }) { return "python" }
        if words.contains("node") { return "javascript" }
        return words.contains(where: { ["sh", "bash", "zsh"].contains($0) }) ? "bash" : nil
    }
    public func highlight(_ source: String, path: String) throws -> SyntaxDocument? {
        try Task.checkCancellation()
        guard let language = Self.language(path: path, text: source) else { return nil }
        guard source.utf8.count <= 2 * 1024 * 1024 else { throw SyntaxFailure.limit }
        let texts = source.components(separatedBy: "\n")
        guard texts.count <= 20_000 else { throw SyntaxFailure.limit }
        let key = language + ":" + SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        if let index = cache.firstIndex(where: { $0.key == key }) {
            let value = cache.remove(at: index); cache.append(value); return value.document
        }
        if engine == nil {
            guard let value = Highlighter(), value.setTheme("atom-one-dark", withFont: "Menlo-Regular", ofSize: 12) else { throw SyntaxFailure.unavailable }
            value.ignoreIllegals = true; engine = value
        }
        guard let tokens = engine?.tokenRanges(source, language: language, limit: 100_000) else { throw SyntaxFailure.unavailable }
        try Task.checkCancellation()
        var lines = texts.map { SyntaxLine(text: $0, spans: []) }
        var starts = [0]
        for text in texts.dropLast() { starts.append(starts.last! + text.utf16.count + 1) }
        var lineIndex = 0
        for token in tokens {
            try Task.checkCancellation()
            guard let location = token["location"] as? Int, let length = token["length"] as? Int,
                  let scopes = token["scopes"] as? [String], let role = scopes.reversed().compactMap(Self.role).first else { continue }
            let end = location + length
            while lineIndex + 1 < starts.count && starts[lineIndex + 1] <= location { lineIndex += 1 }
            var index = lineIndex
            while index < lines.count && starts[index] < end {
                let lower = max(location, starts[index]), upper = min(end, starts[index] + lines[index].text.utf16.count)
                if upper > lower { lines[index].spans.append(SyntaxSpan(range: NSRange(location: lower - starts[index], length: upper - lower), role: role)) }
                index += 1
            }
        }
        let document = SyntaxDocument(language: language, lines: lines)
        if document.cost <= 16 * 1024 * 1024 {
            cache.append((key, document))
            while cache.count > 3 || retainedBytes > 16 * 1024 * 1024 { cache.removeFirst() }
        }
        return document
    }
    private static func role(_ scope: String) -> SyntaxRole? {
        switch scope.split(separator: ".").first.map(String.init) {
        case "keyword", "selector-tag": return .keyword
        case "comment", "quote": return .comment
        case "string", "regexp", "symbol", "bullet": return .string
        case "number", "literal": return .number
        case "title": return scope.contains("class") ? .type : .function
        case "type", "built_in", "attr", "attribute": return .type
        case "variable", "tag", "name": return .variable
        case "section", "strong": return .function
        default: return nil
        }
    }
}
