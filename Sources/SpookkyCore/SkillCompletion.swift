import Foundation

public struct SkillCompletionToken: Equatable, Sendable {
    public let range: NSRange
    public let query: String

    public static func atCaret(in text: String, selection: NSRange) -> Self? {
        guard selection.length == 0 else { return nil }
        let value = text as NSString
        let caret = selection.location
        guard caret <= value.length else { return nil }
        var start = caret
        while start > 0 {
            let character = value.character(at: start - 1)
            guard (65...90).contains(character) || (97...122).contains(character) ||
                  (48...57).contains(character) || character == 45 || character == 95 else { break }
            start -= 1
        }
        guard start > 0 else { return nil }
        let marker = value.character(at: start - 1)
        guard marker == 36 || marker == 47 else { return nil }
        let markerIndex = start - 1
        if markerIndex > 0 {
            let before = value.character(at: markerIndex - 1)
            guard let scalar = UnicodeScalar(before), CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
        }
        if caret < value.length {
            let after = value.character(at: caret)
            guard let scalar = UnicodeScalar(after), CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
        }
        return Self(range: NSRange(location: markerIndex, length: caret - markerIndex),
                    query: value.substring(with: NSRange(location: start, length: caret - start)))
    }
}
