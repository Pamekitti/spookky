import AppKit
import WebKit
import PDFKit
import ImageIO
import SpookkyFiles

@MainActor final class SupportingArtifactView: NSView, WKNavigationDelegate {
    private let path: String
    private let status = ChromeTextField(wrappingLabelWithString: "Loading artifact…")
    private let content = NSView()
    private var task: Task<Void, Never>?
    private var webView: WKWebView?
    private var externalURL: URL?
    private lazy var external = ActionButton("Open externally", help: "Open artifact in its default application") { [weak self] in
        guard let self else { return }
        NSWorkspace.shared.open(externalURL ?? URL(fileURLWithPath: path))
    }
    init(path: String) {
        self.path = path
        super.init(frame: .zero)
        DisplayMetrics.registerRoot(self)
        [status, content, external].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        status.font = .systemFont(ofSize: SpookkyStyle.points(11)); status.textColor = .secondaryLabelColor
        status.setAccessibilityLabel("Artifact status")
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).displayScaled(), status.topAnchor.constraint(equalTo: topAnchor, constant: 6).displayScaled(),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).displayScaled(),
            external.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).displayScaled(), external.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6).displayScaled(),
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 6).displayScaled(), content.bottomAnchor.constraint(equalTo: external.topAnchor, constant: -6).displayScaled()
        ])
        task = Task { [weak self] in
            do {
                let payload = try await Task.detached(priority: .userInitiated) { try ArtifactPreviewPolicy.read(path: path) }.value
                guard !Task.isCancelled, let self else { return }
                try await display(payload)
            } catch { guard !Task.isCancelled else { return }; self?.status.stringValue = error.localizedDescription }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    private func install(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: content.leadingAnchor), view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     view.topAnchor.constraint(equalTo: content.topAnchor), view.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
    }
    private func display(_ payload: ArtifactPayload) async throws {
        status.stringValue = payload.url.lastPathComponent
        switch payload.kind {
        case .text, .markdown:
            let preview = FileService.decode(payload.data)
            guard preview.notice == nil || !preview.text.isEmpty else { status.stringValue = preview.notice ?? "Text unavailable"; return }
            let text = NSTextView()
            text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
            text.font = .monospacedSystemFont(ofSize: SpookkyStyle.points(12), weight: .regular); text.textColor = .labelColor
            text.textContainerInset = NSSize(width: 12, height: 10)
            text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.textContainer?.widthTracksTextView = true
            // Native text treats HTML, script, and link strings as data; no Markdown web bridge.
            text.string = preview.text
            text.setAccessibilityLabel(payload.kind == .markdown ? "Markdown artifact, read only" : "Text artifact, read only")
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = text; scroll.drawsBackground = false
            install(scroll)
            if let notice = preview.notice { status.stringValue += " · " + notice }
        case .image:
            guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil),
                  let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, Double(width) * Double(height) <= 40_000_000,
                  let image = NSImage(data: payload.data) else { status.stringValue = "Image unavailable or exceeds 40 million pixels."; return }
            let view = ArtifactImageView(image: image)
            view.setAccessibilityLabel("Image artifact: " + payload.url.lastPathComponent); install(view)
        case .pdf:
            guard let document = PDFDocument(data: payload.data) else { status.stringValue = "This PDF could not be read."; return }
            let view = PDFView(); view.autoScales = true; view.document = document
            view.setAccessibilityLabel("PDF artifact: " + payload.url.lastPathComponent); install(view)
            content.layoutSubtreeIfNeeded(); view.autoScales = false; view.scaleFactor = view.scaleFactorForSizeToFit * DisplayMetrics.preferences.zoom
        case .html:
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#
            let blocker = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "spookky-local-artifact-no-network", encodedContentRuleList: rules)
            guard !Task.isCancelled else { return }
            if let blocker { configuration.userContentController.add(blocker) }
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.pageZoom = DisplayMetrics.preferences.zoom
            webView = view
            view.navigationDelegate = self; view.setAccessibilityLabel("Local HTML artifact, isolated inline scripts")
            install(view)
            view.loadHTMLString(try ArtifactPreviewPolicy.sandboxedHTML(payload.data), baseURL: nil)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank", action.targetFrame != nil { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        if case .page = BrowserAddress.parse(url.absoluteString) { externalURL = url; status.stringValue = "Use Open externally to follow this link." }
        else if case .external = BrowserAddress.parse(url.absoluteString) { externalURL = url; status.stringValue = "Use Open externally to follow this link." }
        else { status.stringValue = "This link is unavailable in the local preview." }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status.stringValue = "Could not preview HTML: " + error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { status.stringValue = "HTML preview process ended. Close and reopen this tab to retry." }
    func dispose() { task?.cancel(); task = nil; webView?.stopLoading(); webView?.navigationDelegate = nil }
}

@MainActor private final class ArtifactImageView: NSScrollView {
    private let picture = NSImageView()
    private let canvas = NSView()
    private let image: NSImage
    init(image: NSImage) {
        self.image = image; super.init(frame: .zero)
        picture.image = image; picture.imageScaling = .scaleProportionallyUpOrDown
        canvas.addSubview(picture); documentView = canvas; hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true; drawsBackground = false
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    override func layout() {
        super.layout()
        let fit = min(contentSize.width / max(1, image.size.width), contentSize.height / max(1, image.size.height))
        let size = NSSize(width: max(contentSize.width, image.size.width * fit * DisplayMetrics.preferences.zoom),
                          height: max(contentSize.height, image.size.height * fit * DisplayMetrics.preferences.zoom))
        let pictureSize = NSSize(width: image.size.width * fit * DisplayMetrics.preferences.zoom, height: image.size.height * fit * DisplayMetrics.preferences.zoom)
        picture.frame = NSRect(x: (size.width - pictureSize.width) / 2, y: (size.height - pictureSize.height) / 2, width: pictureSize.width, height: pictureSize.height)
        if canvas.frame.size != size {
            let old = canvas.frame.size
            let center = NSPoint(x: contentView.bounds.midX / max(1, old.width), y: contentView.bounds.midY / max(1, old.height))
            canvas.setFrameSize(size)
            if old.width > 0 && old.height > 0 {
                contentView.scroll(to: NSPoint(x: max(0, min(size.width - contentSize.width, center.x * size.width - contentSize.width / 2)),
                                               y: max(0, min(size.height - contentSize.height, center.y * size.height - contentSize.height / 2))))
                reflectScrolledClipView(contentView)
            }
        }
    }
}
