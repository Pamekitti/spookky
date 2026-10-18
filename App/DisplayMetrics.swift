import AppKit
import WebKit
import PDFKit
import SpookkyCore

/// Scale native layout and typography, never the rendered workspace bitmap.
@MainActor enum DisplayMetrics {
    static var preferences = DisplayPreferences()
    static let roots = NSHashTable<NSView>.weakObjects()
    static func registerRoot(_ view: NSView) { roots.add(view) }
    static let constraints = NSMapTable<NSLayoutConstraint, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    static func points(_ value: CGFloat) -> CGFloat { value * preferences.zoom }
    static func registerBase(_ base: CGFloat, for constraint: NSLayoutConstraint) {
        constraints.setObject(NSNumber(value: Double(base)), forKey: constraint); constraint.constant = points(base)
    }
    static func register(_ constraint: NSLayoutConstraint, alreadyScaled: Bool) {
        let base = constraint.constant / (alreadyScaled ? preferences.zoom : 1)
        constraints.setObject(NSNumber(value: Double(base)), forKey: constraint)
        constraint.constant = points(base)
    }
    static func apply(_ next: DisplayPreferences, to root: NSView?) {
        let ratio = next.zoom / preferences.zoom
        preferences = next
        for constraint in constraints.keyEnumerator().allObjects.compactMap({ $0 as? NSLayoutConstraint }) {
            if let base = constraints.object(forKey: constraint) { constraint.constant = points(base.doubleValue) }
        }
        if let root { registerRoot(root) }
        let candidates = roots.allObjects
        for view in candidates where !candidates.contains(where: { $0 !== view && view.isDescendant(of: $0) }) { update(view, ratio: ratio) }
    }
    static func update(_ view: NSView, ratio: Double) {
        if let web = view as? WKWebView { web.pageZoom = preferences.zoom; return }
        if let pdf = view as? PDFView {
            let anchor = pdf.currentDestination
            pdf.autoScales = false; pdf.scaleFactor *= ratio
            if let anchor { pdf.go(to: anchor) }
            return
        }
        if let button = view as? ActionButton { button.contentInset *= ratio }
        if let control = view as? NSControl, let font = control.font {
            control.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * ratio)
        }
        if let text = view as? NSTextView, let storage = text.textStorage {
            let selection = text.selectedRanges
            let typingFont = text.typingAttributes[.font] as? NSFont
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let font = value as? NSFont, let scaled = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * ratio) {
                    storage.addAttribute(.font, value: scaled, range: range)
                }
            }
            storage.endEditing()
            if storage.length == 0, let font = text.font { text.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * ratio) }
            if let typingFont, let scaled = NSFont(descriptor: typingFont.fontDescriptor, size: typingFont.pointSize * ratio) { text.typingAttributes[.font] = scaled }
            text.selectedRanges = selection
            text.textContainerInset = NSSize(width: text.textContainerInset.width * ratio, height: text.textContainerInset.height * ratio)
        }
        if let stack = view as? NSStackView {
            stack.spacing *= ratio
            let e = stack.edgeInsets
            stack.edgeInsets = NSEdgeInsets(top: e.top * ratio, left: e.left * ratio, bottom: e.bottom * ratio, right: e.right * ratio)
        }
        if let table = view as? NSTableView { table.rowHeight *= ratio }
        view.subviews.forEach { update($0, ratio: ratio) }
        view.invalidateIntrinsicContentSize(); view.needsLayout = true; view.needsDisplay = true
    }
}

extension NSLayoutConstraint {
    @MainActor func displayScaled(alreadyScaled: Bool = false) -> Self {
        DisplayMetrics.register(self, alreadyScaled: alreadyScaled); return self
    }
}
