import Foundation

/// Accept Ghostty's normalized export, not arbitrary executable/window configuration.
public struct GhosttyAppearance: Codable, Equatable, Sendable {
    public let configuration: String
    public let fontSize: Double
    public let dependencies: [String]
    private enum CodingKeys: String, CodingKey { case configuration, fontSize, dependencies }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let text = try values.decode(String.self, forKey: .configuration)
        let size = try values.decode(Double.self, forKey: .fontSize)
        guard text.utf8.count <= 262144, size.isFinite, size > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .configuration, in: values, debugDescription: "Invalid cached appearance")
        }
        let sanitized = GhosttyAppearance(export: text)
        configuration = sanitized.configuration; fontSize = size
        dependencies = Array((try values.decodeIfPresent([String].self, forKey: .dependencies) ?? []).prefix(64))
    }
    public init(export: String) {
        var lines: [String] = [], dependencies: [String] = [], fontSize = 13.0
        let keys: Set<String> = ["background", "foreground", "palette", "bold-color", "background-opacity",
            "cursor-color", "cursor-opacity", "cursor-style", "cursor-style-blink", "cursor-text",
            "selection-background", "selection-foreground", "selection-invert-fg-bg",
            "window-padding-x", "window-padding-y", "window-padding-balance", "window-padding-color",
            "alpha-blending", "minimum-contrast", "colorspace"]
        for line in export.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# spookky-watch=") { dependencies.append(String(line.dropFirst("# spookky-watch=".count))); continue }
            guard let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if key == "config-file" { dependencies.append(value.hasPrefix("?") ? String(value.dropFirst()) : value) }
            if key == "theme", value.hasPrefix("/") { dependencies.append(value) }
            if key == "font-size" { if let size = Double(value), size.isFinite, size > 0 { fontSize = size }; continue }
            if keys.contains(key) || key.hasPrefix("font-") || key.hasPrefix("adjust-") { lines.append(String(line)) }
        }
        self.configuration = lines.joined(separator: "\n")
        self.fontSize = fontSize; self.dependencies = dependencies
    }
    public func configuration(preferences: DisplayPreferences) -> String {
        configuration + "\nfont-size = \(preferences.terminalFontSize(base: fontSize))\n"
    }
}

public struct GhosttyAppearanceProfile: Codable, Equatable, Sendable {
    public let light: GhosttyAppearance
    public let dark: GhosttyAppearance
    public init(light: GhosttyAppearance, dark: GhosttyAppearance) { self.light = light; self.dark = dark }
    public var dependencies: [String] { Array(Set(light.dependencies + dark.dependencies)).sorted() }
}
