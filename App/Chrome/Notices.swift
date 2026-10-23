import AppKit
import ImageIO
import SpookkyCore
import SpookkyGit
import SpookkySyntax
import SpookkyWorkspace
import UniformTypeIdentifiers

@MainActor final class ProviderStartupNoticeView: NSStackView {
    private let message = ChromeTextField(wrappingLabelWithString: "")
    init(focus: @escaping () -> Void, details: @escaping () -> Void) {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = SpookkyStyle.points(6)
        edgeInsets = NSEdgeInsets(top: SpookkyStyle.points(8), left: SpookkyStyle.points(8), bottom: SpookkyStyle.points(8), right: SpookkyStyle.points(8))
        message.font = .systemFont(ofSize: SpookkyStyle.points(11)); message.textColor = SpookkyPalette.secondary
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(message)
        let actions = NSStackView(views: [ActionButton("Focus terminal", height: SpookkyStyle.points(24), action: focus),
                                        ActionButton("Details", height: SpookkyStyle.points(24), action: details)])
        actions.spacing = SpookkyStyle.points(8); addArrangedSubview(actions)
        message.widthAnchor.constraint(equalTo: widthAnchor, constant: -16).displayScaled().isActive = true
        setContentHuggingPriority(.required, for: .vertical)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    func update(message value: String?) {
        guard message.stringValue != (value ?? "") || isHidden != (value == nil) else { return }
        message.stringValue = value ?? ""; message.setAccessibilityLabel(value ?? "")
        isHidden = value == nil
    }
}

@MainActor final class AppErrorNoticeView: NSStackView {
    private let heading = ChromeTextField(wrappingLabelWithString: "")
    private let details = ChromeTextField(wrappingLabelWithString: "")
    private let detailButton = ActionButton("Details", height: SpookkyStyle.points(24), action: {})
    private let retryButton = ActionButton("Retry", height: SpookkyStyle.points(24), action: {})
    private let localButton = ActionButton("Use Local checkout", height: SpookkyStyle.points(24), action: {})
    private let dismissButton = ActionButton("Dismiss", height: SpookkyStyle.points(24), action: {})
    private var noticeID: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical; alignment = .leading; spacing = SpookkyStyle.points(6)
        edgeInsets = NSEdgeInsets(top: SpookkyStyle.points(10), left: SpookkyStyle.points(12), bottom: SpookkyStyle.points(10), right: SpookkyStyle.points(12))
        heading.font = .systemFont(ofSize: SpookkyStyle.points(12), weight: .medium)
        heading.textColor = SpookkyPalette.warning
        details.font = .monospacedSystemFont(ofSize: SpookkyStyle.points(11), weight: .regular)
        details.textColor = SpookkyPalette.secondary; details.maximumNumberOfLines = 10
        let recovery = NSStackView(views: [retryButton, localButton])
        let secondary = NSStackView(views: [detailButton, dismissButton])
        recovery.spacing = SpookkyStyle.points(8); secondary.spacing = SpookkyStyle.points(8)
        addArrangedSubview(heading); addArrangedSubview(details)
        addArrangedSubview(recovery); addArrangedSubview(secondary)
        heading.widthAnchor.constraint(equalTo: widthAnchor, constant: -24).displayScaled().isActive = true
        details.widthAnchor.constraint(equalTo: widthAnchor, constant: -24).displayScaled().isActive = true
        detailButton.handler = { [weak self] in
            guard let self else { return }; details.isHidden.toggle()
            detailButton.title = details.isHidden ? "Details" : "Hide details"
        }
        details.isHidden = true; isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("Use init") }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: SpookkyStyle.cornerRadius, yRadius: SpookkyStyle.cornerRadius)
        SpookkyPalette.raised.setFill(); path.fill()
        SpookkyPalette.border.setStroke(); path.lineWidth = 1; path.stroke()
        super.draw(dirtyRect)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    func update(id: String?, title: String = "", detail: String = "", canRetry: Bool = false,
                canUseLocal: Bool = false, retry: (() -> Void)? = nil, useLocal: (() -> Void)? = nil, dismiss: (() -> Void)? = nil) {
        if noticeID != id { noticeID = id; details.isHidden = true; detailButton.title = "Details" }
        isHidden = id == nil
        guard id != nil else { return }
        heading.stringValue = title; heading.setAccessibilityLabel(title)
        details.stringValue = String(detail.prefix(8_192)); details.toolTip = detail
        retryButton.isHidden = !canRetry; retryButton.handler = retry
        localButton.isHidden = !canUseLocal; localButton.handler = useLocal
        dismissButton.isHidden = dismiss == nil; dismissButton.handler = dismiss
        detailButton.isHidden = detail.isEmpty
    }
}
