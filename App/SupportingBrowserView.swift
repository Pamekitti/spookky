import AppKit
import WebKit
import SpookkyCore
import SpookkyFiles

@MainActor final class SupportingBrowserView: NSView, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let webView: WKWebView
    let address = ChromeTextField()
    private let status = SpookkyStyle.label( "")
    private let toolbar = NSStackView()
    private var observations: [NSKeyValueObservation] = []
    private var externalURL: URL?
    private let update: (SupportingTarget, String?) -> Void
    private var lastMetadata = ""
    private var disposed = false
    private var failureMessage: String?
    private var stopRequested = false
    private(set) var navigationStarted = false
    private lazy var back = ActionButton("", symbol: "chevron.left", help: "Back") { [weak self] in self?.webView.goBack() }
    private lazy var forward = ActionButton("", symbol: "chevron.right", help: "Forward") { [weak self] in self?.webView.goForward() }
    private lazy var reload = ActionButton("", symbol: "arrow.clockwise", help: "Reload or stop loading") { [weak self] in self?.reloadOrStop() }
    private lazy var external = ActionButton("Open externally", help: "Open this address in its default application") { [weak self] in
        if let url = self?.externalURL { NSWorkspace.shared.open(url) }
    }
    init(address initial: String, websiteData: WKWebsiteDataStore, update: @escaping (SupportingTarget, String?) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteData
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.update = update
        super.init(frame: .zero)
        DisplayMetrics.registerRoot(self)
        webView.pageZoom = DisplayMetrics.preferences.zoom
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.setAccessibilityLabel("Browser page")
        address.font = .systemFont(ofSize: SpookkyStyle.points(13))
        address.placeholderString = "Address or localhost URL"; address.delegate = self
        address.target = self; address.action = #selector(navigateFromAddress)
        address.setAccessibilityLabel("Browser address")
        address.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: SpookkyStyle.points(11)); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail; status.setAccessibilityLabel("Browser status")
        toolbar.orientation = .horizontal; toolbar.spacing = SpookkyStyle.points(4)
        [back, forward, reload, address].forEach { toolbar.addArrangedSubview($0) }
        [toolbar, webView, status, external].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        [back, forward, reload].forEach { $0.widthAnchor.constraint(equalToConstant: 26).displayScaled().isActive = true }
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        external.isHidden = true
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6).displayScaled(), toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6).displayScaled(),
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 5).displayScaled(), toolbar.heightAnchor.constraint(equalToConstant: 28).displayScaled(),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).displayScaled(), status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5).displayScaled(),
            status.trailingAnchor.constraint(lessThanOrEqualTo: external.leadingAnchor, constant: -4).displayScaled(),
            external.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6).displayScaled(), external.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 5).displayScaled(), webView.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -5).displayScaled()
        ])
        observations = [webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor [weak self] in self?.metadataChanged() } },
                        webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor [weak self] in self?.metadataChanged() } },
                        webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor [weak self] in self?.refreshControls() } },
                        webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor [weak self] in self?.refreshControls() } },
                        webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor [weak self] in self?.refreshControls() } }]
        navigate(initial)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { focusAddress(); return true }
    func focusAddress() { window?.makeFirstResponder(address); address.selectText(nil) }
    func containsFocus(in window: NSWindow) -> Bool {
        guard let view = window.firstResponder as? NSView else { return false }
        if let editor = view as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSView { return control.isDescendant(of: self) }
        return view === self || view.isDescendant(of: self)
    }
    @objc private func navigateFromAddress() { navigate(address.stringValue) }
    func navigate(_ input: String) {
        externalURL = nil; external.isHidden = true; failureMessage = nil; stopRequested = false; navigationStarted = false
        switch BrowserAddress.parse(input) {
        case .page(let url):
            address.stringValue = url.absoluteString; status.stringValue = "Loading…"
            webView.load(URLRequest(url: url))
        case .external(let url):
            address.stringValue = input; offerExternal(url)
        case .invalid: status.stringValue = "Enter an HTTP(S) address or about:blank."
        }
    }
    func reloadOrStop() {
        if webView.isLoading && !stopRequested { stopRequested = true; failureMessage = "Stopped"; webView.stopLoading(); refreshControls() }
        else { stopRequested = false; failureMessage = nil; webView.reload() }
    }
    private func metadataChanged() {
        guard !disposed, let url = webView.url else { return }
        // Never replace a partially typed address or move a page form's first responder.
        if address.currentEditor() == nil { address.stringValue = url.absoluteString }
        let title = String((webView.title?.isEmpty == false ? webView.title! : url.host ?? "Browser").prefix(512))
        let metadata = url.absoluteString + "\0" + title
        if metadata != lastMetadata { lastMetadata = metadata; update(.browser(url: url.absoluteString), title) }
    }
    private func refreshControls() {
        guard !disposed else { return }
        back.isEnabled = webView.canGoBack; forward.isEnabled = webView.canGoForward
        reload.image = NSImage(systemSymbolName: webView.isLoading && !stopRequested ? "xmark" : "arrow.clockwise", accessibilityDescription: nil)
        reload.toolTip = webView.isLoading && !stopRequested ? "Stop loading" : "Reload page"
        reload.setAccessibilityLabel(webView.isLoading && !stopRequested ? "Stop loading" : "Reload page")
        if externalURL == nil { status.stringValue = failureMessage ?? (webView.isLoading ? "Loading…" : "Ready") }
    }
    private func offerExternal(_ url: URL) {
        externalURL = url; external.isHidden = false
        status.stringValue = "This address opens in another application."
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        switch BrowserAddress.parse(url.absoluteString) {
        case .page:
            if action.targetFrame == nil { decisionHandler(.cancel); webView.load(action.request) }
            else { decisionHandler(.allow) }
        case .external(let url): offerExternal(url); decisionHandler(.cancel)
        case .invalid: status.stringValue = "This address cannot be displayed."; decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationStarted = true
        if stopRequested { webView.stopLoading(); refreshControls(); return }
        failureMessage = nil; externalURL = nil; external.isHidden = true; refreshControls()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { metadataChanged(); refreshControls() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure(error) }
    private func failure(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { failureMessage = "Could not load page: " + error.localizedDescription; status.stringValue = failureMessage! }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failureMessage = "Page process ended. Reload to reopen; unsent page input may be unavailable."; status.stringValue = failureMessage! }
    func dispose() {
        disposed = true; observations.forEach { $0.invalidate() }; observations.removeAll()
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
    }
}
