import Foundation

public struct DisplayPreferences: Codable, Equatable, Sendable {
    public static let zoomLevels: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    public var zoom: Double = 1
    public var sidebarWidth: Double = 232
    public var terminalFontAdjustment: Double = 0
    public init() {}
    private enum CodingKeys: String, CodingKey { case zoom, sidebarWidth, terminalFontAdjustment }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        zoom = try values.decodeIfPresent(Double.self, forKey: .zoom) ?? 1
        sidebarWidth = try values.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 232
        terminalFontAdjustment = try values.decodeIfPresent(Double.self, forKey: .terminalFontAdjustment) ?? 0
        normalize()
    }
    public mutating func normalize() {
        if !zoom.isFinite { zoom = 1 }
        zoom = Self.zoomLevels.min { abs($0 - zoom) < abs($1 - zoom) } ?? 1
        if !sidebarWidth.isFinite { sidebarWidth = 232 }
        sidebarWidth = min(600, max(200, sidebarWidth))
        if !terminalFontAdjustment.isFinite { terminalFontAdjustment = 0 }
        terminalFontAdjustment = min(20, max(-8, terminalFontAdjustment))
    }
    public mutating func stepZoom(_ direction: Int) {
        normalize()
        let index = Self.zoomLevels.firstIndex(of: zoom) ?? 2
        zoom = Self.zoomLevels[min(Self.zoomLevels.count - 1, max(0, index + direction))]
    }
    public func sidebarPoints(available: Double) -> Double {
        min(sidebarWidth * zoom, max(0, available - 320))
    }
    public func terminalFontSize(base: Double) -> Double { max(6, base + terminalFontAdjustment) * zoom }
}
