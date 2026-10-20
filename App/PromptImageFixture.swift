import AppKit
import SpookkyCore
import SpookkyWorkspace

struct ComposerFixtureModels: ProviderModelDiscovering {
    func models(for tool: SessionTool, directory: String, refresh: Bool) async -> ProviderModels {
        if tool == .codex {
            return ProviderModels(models: [ProviderModel(id: "fixture-sol", name: "Sol fixture", efforts: ["low", "high"])])
        }
        return ProviderModels(models: [ProviderModel(id: "sonnet", name: "Sonnet"), ProviderModel(id: "opus", name: "Opus")], efforts: ["low", "high"])
    }
}

@MainActor enum PromptImageFixture {
    static func run(composer: LaunchComposerView, window: NSWindow, root: URL,
                    draft: () -> TerminalDraft, changeTool: (SessionTool) -> Void) async throws {
        var checks: [String: Bool] = [:]
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(50))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        composer.prompt.imagePasteboard = pasteboard
        defer { composer.prompt.imagePasteboard = .general }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 96,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let blue = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1)
        let orange = NSColor(deviceRed: 1, green: 0.5, blue: 0.1, alpha: 1)
        for y in 0..<96 { for x in 0..<128 { bitmap.setColor(x < 64 ? blue : orange, atX: x, y: y) } }
        let png = bitmap.representation(using: .png, properties: [:])!
        let text = composer.prompt.string
        var errors: [String] = []
        composer.onError = { errors.append($0) }

        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }

        func paste(_ data: Data, type: NSPasteboard.PasteboardType) async throws {
            pasteboard.clearContents(); pasteboard.setData(data, forType: type)
            composer.focus()
            guard NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) else {
                throw LaunchError.invalid("Image paste did not reach the prompt editor.")
            }
            for _ in 0..<500 where composer.isImportingImage { try await Task.sleep(for: .milliseconds(10)) }
            guard !composer.isImportingImage else { throw LaunchError.invalid("Image paste did not finish.") }
        }
        try await paste(png, type: .png)
        checks["png_paste_reaches_draft"] = draft().images.count == 1
        checks["paste_preserves_prompt_text"] = composer.prompt.string == text
        let firstPreview = descendants(of: composer).compactMap { $0 as? NSImageView }.first
        if let path = draft().images.first {
            checks["saved_image_is_readable_png"] = (try Data(contentsOf: URL(fileURLWithPath: path))) == png
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            checks["saved_image_is_private"] = (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
        }
        changeTool(.claude)
        checks["provider_change_retains_images"] = draft().images.count == 1
        try await paste(bitmap.tiffRepresentation!, type: .tiff)
        checks["tiff_paste_adds_second_image"] = draft().images.count == 2
        checks["existing_preview_is_reused"] = firstPreview != nil && descendants(of: composer).contains { $0 === firstPreview }
        let saved = try JSONDecoder().decode(TerminalDraft.self, from: JSONEncoder().encode(draft()))
        checks["images_survive_draft_serialization"] = saved.images == draft().images

        window.setContentSize(NSSize(width: 650, height: 450))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        if let view = window.contentView, let capture = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: capture)
            try capture.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("prompt-images.png"))
        }
        let remove = descendants(of: composer).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Remove image 1" }
        let removedPath = draft().images.first
        remove?.performClick(nil)
        checks["remove_button_removes_one_image"] = remove != nil && draft().images.count == 1
        if let removedPath {
            for _ in 0..<100 where FileManager.default.fileExists(atPath: removedPath) { try await Task.sleep(for: .milliseconds(10)) }
            checks["removed_image_file_is_released"] = !FileManager.default.fileExists(atPath: removedPath)
        }
        let before = draft().images
        try await paste(Data("invalid image".utf8), type: .png)
        checks["invalid_image_preserves_draft_and_reports_error"] = draft().images == before && errors.count == 1
        checks["paste_keeps_prompt_focus"] = window.firstResponder === composer.prompt
        let bytes = try draft().images.reduce(0) { total, path in
            total + ((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0)
        }
        try PrivateFiles.write(["retained_image_bytes": bytes, "retained_image_count": draft().images.count],
            to: root.appendingPathComponent("prompt-image-resources.json"))
        try PrivateFiles.write(checks, to: root.appendingPathComponent("prompt-image-checks.json"))
        guard checks.values.allSatisfy({ $0 }) else {
            throw LaunchError.invalid("Prompt image checks failed: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", "))
        }
    }
}
