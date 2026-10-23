import AppKit
protocol TerminalInputTracing: AnyObject {
    func record(_ stage: String, event: NSEvent?, text: String?, fields: [String: Any])
}
extension TerminalInputTracing {
    func record(_ stage: String, event: NSEvent? = nil, text: String? = nil, fields: [String: Any] = [:]) {
        record(stage, event: event, text: text, fields: fields)
    }
}
