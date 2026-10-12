import CryptoKit
import Foundation
import SpookkyCore

struct ViewportGrid {
    struct Line { let digest: String; let start: Int; let fragments: [Int] }
    private static let hexDigits = Array("0123456789abcdef".utf8)
    let lines: [Line]
    init?(physical: String, joined: String) {
        guard physical.utf8.count < 8_388_608, joined.utf8.count < 8_388_608 else { return nil }
        func rows(_ value: String) -> [String] {
            var result = value.components(separatedBy: "\n")
            if result.last == "" { result.removeLast() }
            return result.map { String($0.filter { !$0.isWhitespace }) }
        }
        let fragments = rows(physical)
        var index = 0, mapped: [Line] = []
        for text in rows(joined) {
            let start = index
            var accumulated = "", sizes: [Int] = []
            repeat {
                guard index < fragments.count else { return nil }
                let fragment = fragments[index]; accumulated += fragment
                sizes.append(fragment.count); index += 1
                guard text.hasPrefix(accumulated) else { return nil }
            } while accumulated != text
            var digest = [UInt8]()
            digest.reserveCapacity(64)
            for byte in SHA256.hash(data: Data(text.utf8)) {
                digest.append(Self.hexDigits[Int(byte >> 4)])
                digest.append(Self.hexDigits[Int(byte & 0x0f)])
            }
            mapped.append(Line(digest: String(decoding: digest, as: UTF8.self), start: start, fragments: sizes))
        }
        guard index == fragments.count else { return nil }
        lines = mapped
    }
    func anchor(at row: Int) -> ViewportAnchor? {
        guard let index = lines.firstIndex(where: { row >= $0.start && row < $0.start + $0.fragments.count }) else { return nil }
        let line = lines[index]
        return ViewportAnchor(digest: line.digest, logicalLine: index,
            contentOffset: line.fragments.prefix(row - line.start).reduce(0, +))
    }
    func row(for anchor: ViewportAnchor) -> Int? {
        let matches = lines.indices.filter { lines[$0].digest == anchor.digest }
        guard let index = matches.min(by: { abs($0 - anchor.logicalLine) < abs($1 - anchor.logicalLine) }) else { return nil }
        let line = lines[index]
        var count = 0
        for (offset, size) in line.fragments.enumerated() {
            if count + size > anchor.contentOffset { return line.start + offset }
            count += size
        }
        return line.start + line.fragments.count - 1
    }
}
