import AppKit
import SpookkyCore

final class FixtureInputTrace: TerminalInputTracing {
    private let queue = DispatchQueue(label: "dev.spookky.m0.input-fixture")
    private let output: URL
    private var count = 0

    init(output: URL) { self.output = output }

    func record(_ stage: String, event: NSEvent? = nil, text: String? = nil, fields: [String: Any] = [:]) {
        guard count < 1024 else { return }
        count += 1
        var record = fields
        record["index"] = count
        record["stage"] = stage
        record["uptime_seconds"] = ProcessInfo.processInfo.systemUptime
        if let event {
            record["keycode"] = event.keyCode
            record["event_modifiers"] = event.modifierFlags.rawValue
            if event.type == .keyDown || event.type == .keyUp { record["repeat"] = event.isARepeat }
        }
        if let text {
            record["text"] = String(text.prefix(256))
            record["text_utf8_bytes"] = text.utf8.count
        }
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        queue.async { [output] in
            if !FileManager.default.fileExists(atPath: output.path) {
                FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: output) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
