import Foundation

public enum AutomaticWorkspaceTitle: String, Codable, Sendable {
    case friendly, prompt, legacy
}

public enum WorkspaceNaming {
    private static let adjectives = ["Quiet", "Amber", "Silver", "Soft", "Misty", "Gentle", "Bright", "Calm"]
    private static let nouns = ["Maple", "Fox", "Pine", "Lantern", "Willow", "River", "Cedar", "Meadow"]
    private static let friendlyNames = adjectives.flatMap { adjective in nouns.map { adjective + " " + $0 } }

    public static func friendly(excluding titles: [String]) -> String {
        let used = Set(titles.map { $0.lowercased() })
        let available = friendlyNames.filter { !used.contains($0.lowercased()) }
        if let title = available.randomElement() { return title }
        var suffix = 2
        while used.contains("quiet maple \(suffix)") { suffix += 1 }
        return "Quiet Maple \(suffix)"
    }

    public static func promptTitle(_ prompt: String) -> String? {
        var title = "", words = 0, space = false
        for character in prompt {
            if character.isNewline {
                if !title.isEmpty { break }
                continue
            }
            if character.isWhitespace {
                if !title.isEmpty { space = true }
                continue
            }
            if title.isEmpty || space {
                guard words < 6 else { break }
                if space { title.append(" ") }
                words += 1
            }
            guard title.count < 48 else { break }
            title.append(character)
            space = false
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    public static func isGeneric(_ title: String) -> Bool {
        let title = title.lowercased()
        return title == "new workspace" || (title.count == 18 && title.hasPrefix("workspace-") &&
            title.suffix(8).allSatisfy { "0123456789abcdef".contains($0) })
    }

    public static func defaultBranch(workspaceID: UUID) -> String {
        "spookky/workspace-" + workspaceID.uuidString.prefix(8).lowercased()
    }

    public static func isGeneratedBranch(_ branch: String?, workspaceID: UUID) -> Bool {
        branch == defaultBranch(workspaceID: workspaceID)
    }
}
