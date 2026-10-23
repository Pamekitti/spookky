import AppKit
import ImageIO
import SpookkyCore
import SpookkyGit
import SpookkySyntax
import SpookkyWorkspace
import UniformTypeIdentifiers

final class PromptTextView: NSTextView {
    private let draftUndoManager: UndoManager = { let manager = UndoManager(); manager.levelsOfUndo = 50; return manager }()
    override var undoManager: UndoManager? { draftUndoManager }
    var onFocusChange: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onCompletionKey: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), onCompletionKey?(event) == true { return }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if [36, 76].contains(event.keyCode), !hasMarkedText(), let onSubmit {
            if modifiers.isEmpty || modifiers == .command {
                if !event.isARepeat { onSubmit() }
                return
            }
            if modifiers == .shift { insertNewlineIgnoringFieldEditor(nil); return }
        }
        super.keyDown(with: event)
    }
    var onPasteImage: ((Data) -> Void)?
    var imagePasteboard: NSPasteboard = .general
    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if let type = imagePasteboard.availableType(from: [.png, .tiff]), let data = imagePasteboard.data(forType: type) {
            onPasteImage?(data)
        } else { super.paste(sender) }
    }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), imagePasteboard.availableType(from: [.png, .tiff]) != nil { return isEditable }
        return super.validateUserInterfaceItem(item)
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); onFocusChange?(); return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); onFocusChange?(); return result }
    override var string: String { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            NSAttributedString(string: "What would you like to work on?", attributes: [.font: font ?? NSFont.systemFont(ofSize: SpookkyStyle.points(14)), .foregroundColor: SpookkyPalette.secondary])
                .draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height))
        }
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
}
