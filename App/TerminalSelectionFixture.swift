import AppKit
import GhosttyKit
import SpookkyCore
import SpookkyRuntime

@MainActor enum TerminalSelectionFixture {
    static func run(view: TerminalHostView, binding: SessionBinding, runtime: any SessionRuntime, root: URL) async throws {
        guard let window = view.window, let surface = view.surface else { throw LaunchError.invalid("Selection fixture is unavailable.") }
        let marker = "SPOOKKY_SELECTION_MARKER"
        defer { view.engine.clipboard.clearContents() }
        view.insertText("printf '\\033[2J\\033[H'; printf '\(marker)\\n'", replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { throw LaunchError.invalid("Selection fixture Enter is unavailable.") }
        view.keyDown(with: enter)
        for _ in 0..<100 {
            if view.visibleText().hasPrefix(marker) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard view.visibleText().hasPrefix(marker) else { throw LaunchError.invalid("Selection marker did not appear.") }
        let before = try await runtime.inspect(binding)
        let size = ghostty_surface_size(surface)
        let scale = window.backingScaleFactor
        let cellWidth = Double(size.cell_width_px) / scale
        var region = ghostty_selection_s()
        region.top_left.tag = GHOSTTY_POINT_VIEWPORT; region.top_left.coord = GHOSTTY_POINT_COORD_EXACT
        region.bottom_right.tag = GHOSTTY_POINT_VIEWPORT; region.bottom_right.coord = GHOSTTY_POINT_COORD_EXACT
        region.bottom_right.x = UInt32(marker.count - 1)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, region, &text) else { throw LaunchError.invalid("Selection text geometry is unavailable.") }
        let origin = NSPoint(x: text.tl_px_x, y: text.tl_px_y)
        ghostty_surface_free_text(surface, &text)
        func event(_ type: NSEvent.EventType, column: Double) throws -> NSEvent {
            let point = view.convert(NSPoint(x: origin.x + cellWidth * column, y: origin.y), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { throw LaunchError.invalid("Selection fixture mouse event is unavailable.") }
            return event
        }
        let started = ContinuousClock.now
        view.mouseDown(with: try event(.leftMouseDown, column: 0.1))
        view.mouseDragged(with: try event(.leftMouseDragged, column: Double(marker.count) - 0.1))
        view.mouseUp(with: try event(.leftMouseUp, column: Double(marker.count) - 0.1))
        view.copy(nil)
        var selected = ""
        for _ in 0..<100 {
            var text = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &text) {
                if let pointer = text.text { selected = String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: Int(text.text_len)), as: UTF8.self) }
                ghostty_surface_free_text(surface, &text)
            }
            if selected == marker { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let latency = started.duration(to: .now)
        try await Task.sleep(for: .milliseconds(100))
        var retained = ghostty_text_s()
        let retainsSelection = ghostty_surface_read_selection(surface, &retained)
        if retainsSelection { ghostty_surface_free_text(surface, &retained) }
        let after = try await runtime.inspect(binding)
        let checks = ["exact_native_selection": selected == marker, "highlight_retained_after_release": retainsSelection,
            "copy_matches_selection": view.engine.clipboard.string(forType: .string) == marker,
            "process_unchanged": before?.processID == after?.processID, "no_tmux_copy_mode": try await (runtime as? any SessionViewportRuntime)?.viewport(binding) == nil]
        try PrivateFiles.write(checks, to: root.appendingPathComponent("selection-checks.json"))
        try PrivateFiles.write(["selection_ready_ms": Double(latency.components.seconds) * 1000 + Double(latency.components.attoseconds) / 1e15], to: root.appendingPathComponent("selection-timing.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Native selection regression failed: " + selected) }
    }
}
