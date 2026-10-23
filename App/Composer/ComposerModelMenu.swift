import AppKit
import SpookkyCore
import SpookkyWorkspace

@MainActor final class ComposerModelMenu: NSObject {
    private let footer: NSStackView
    private let fullAccessToggle = NSSwitch()
    private var presentationKey = ""
    var onEffort: ((String?) -> Void)?
    var onFullAccess: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    init(footer: NSStackView) { self.footer = footer }
    func update(tool: SessionTool?, selection: AgentModelSelection, efforts: [String], fullAccess: Bool) {
        let key = (tool?.rawValue ?? "") + "|" + (selection.model ?? "") + "|" + (selection.effort ?? "") + "|" + efforts.joined(separator: ",") + "|" + String(fullAccess)
        guard key != presentationKey else { return }; presentationKey = key
        let focusedTitle = (footer.window?.firstResponder as? NSButton)?.title
        for view in footer.arrangedSubviews { footer.removeArrangedSubview(view); view.removeFromSuperview() }
        footer.isHidden = false
        let separator = NSBox(); separator.boxType = .separator
        footer.addArrangedSubview(separator); separator.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        if !efforts.isEmpty {
            let label = SpookkyStyle.label("Reasoning effort")
            label.font = .systemFont(ofSize: SpookkyStyle.points(11)); label.textColor = SpookkyPalette.secondary
            footer.addArrangedSubview(label)
            let values: [String?] = [nil] + efforts.map(Optional.some)
            for offset in stride(from: 0, to: values.count, by: 3) {
                let row = NSStackView(); row.spacing = SpookkyStyle.points(4); row.distribution = .fillEqually
                for value in values[offset..<min(offset + 3, values.count)] {
                    let button = ActionButton(value?.capitalized ?? "Default effort", action: {})
                    button.selected = value == selection.effort
                    button.setAccessibilityValue(button.selected ? "Selected" : "Not selected")
                    button.handler = { [weak self] in
                        self?.onEffort?(value)
                    }
                    button.onCancel = { [weak self] in self?.onCancel?() }
                    row.addArrangedSubview(button)
                    if button.title == focusedTitle { DispatchQueue.main.async { [weak button] in button?.window?.makeFirstResponder(button) } }
                }
                footer.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
            }
        }
        let accessRow = NSStackView(); accessRow.alignment = .centerY
        let accessLabel = SpookkyStyle.label("Full access")
        accessRow.addArrangedSubview(accessLabel)
        let spacer = NSView(); accessRow.addArrangedSubview(spacer)
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        fullAccessToggle.state = fullAccess ? .on : .off
        fullAccessToggle.target = self; fullAccessToggle.action = #selector(toggleFullAccess)
        fullAccessToggle.setAccessibilityLabel("Full access for " + (tool?.displayName ?? "agent"))
        accessRow.addArrangedSubview(fullAccessToggle)
        footer.addArrangedSubview(accessRow); accessRow.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        if fullAccess {
            let detail = SpookkyStyle.label(tool == .codex ? "No approvals or sandbox" : "Permission prompts skipped")
            detail.font = .systemFont(ofSize: SpookkyStyle.points(11)); detail.textColor = SpookkyPalette.warning
            footer.addArrangedSubview(detail)
        }
    }
    @objc private func toggleFullAccess() { onFullAccess?(fullAccessToggle.state == .on) }
}
