import Foundation

public enum MarkdownDocument {
    public static func html(_ source: String) throws -> String {
        let document = try AttributedString(markdown: source, options: .init(interpretedSyntax: .full))
        var output = "", previous: [(id: Int, open: String, close: String)] = []
        for run in document.runs {
            let components = Array(run.presentationIntent?.components.reversed() ?? [])
            var frames: [(id: Int, open: String, close: String)] = []
            var headerRow = false
            for component in components {
                let tag: String
                switch component.kind {
                case .paragraph: tag = "p"
                case .header(let level): tag = "h\(min(6, max(1, level)))"
                case .unorderedList: tag = "ul"
                case .orderedList: tag = "ol"
                case .listItem: tag = "li"
                case .blockQuote: tag = "blockquote"
                case .codeBlock: tag = "pre"
                case .table: tag = "table"
                case .tableHeaderRow: tag = "tr"; headerRow = true
                case .tableRow: tag = "tr"
                case .tableCell: tag = headerRow ? "th" : "td"
                case .thematicBreak: tag = "div"
                default: tag = "div"
                }
                frames.append((component.identity, "<\(tag)>", "</\(tag)>"))
            }
            var common = 0
            while common < min(previous.count, frames.count), previous[common].id == frames[common].id { common += 1 }
            output += previous.dropFirst(common).reversed().map(\.close).joined()
            output += frames.dropFirst(common).map(\.open).joined()
            var text = escape(String(document[run.range].characters))
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { text = "<code>" + text + "</code>" }
                if intent.contains(.stronglyEmphasized) { text = "<strong>" + text + "</strong>" }
                if intent.contains(.emphasized) { text = "<em>" + text + "</em>" }
                if intent.contains(.strikethrough) { text = "<del>" + text + "</del>" }
            }
            if let url = run.link, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                text = "<a href=\"" + escape(url.absoluteString) + "\">" + text + "</a>"
            }
            output += text; previous = frames
        }
        output += previous.reversed().map(\.close).joined()
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Markdown preview</title>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>:root{color-scheme:light dark}body{font:14px -apple-system,system-ui;line-height:1.6;margin:0 auto;padding:24px;max-width:80ch;overflow-wrap:anywhere}h1,h2,h3{line-height:1.25}pre,code{font-family:ui-monospace,monospace}pre{padding:16px;overflow:auto;background:light-dark(#f2f2f2,#222);border-radius:8px;white-space:pre}table{border-collapse:collapse;width:100%}th,td{padding:8px 12px;border:1px solid light-dark(#ccc,#555);text-align:left}blockquote{margin-left:0;padding-left:16px;border-left:3px solid #888}a{color:light-dark(#0759b5,#72aaff)}</style>
        </head><body>\(output)</body></html>
        """
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
