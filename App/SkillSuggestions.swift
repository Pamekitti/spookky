import Foundation
import SpookkyCore

struct SkillSuggestion: Equatable, Sendable {
    let name: String
    let description: String
    let source: String
}

enum SkillSuggestions {
    static func load(tool: SessionTool, directory: String) -> [SkillSuggestion] {
        guard tool != .shell else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        var roots: [(URL, String)] = []
        if tool == .codex {
            roots += [(home.appendingPathComponent(".codex/skills"), "Codex"),
                      (home.appendingPathComponent(".codex/skills/.system"), "Codex")]
            roots += codexPluginRoots(home: home)
            roots.append((home.appendingPathComponent(".agents/skills"), "Local"))
        } else {
            roots.append((home.appendingPathComponent(".claude/skills"), "Claude"))
        }
        for ancestor in ancestors(of: folder) {
            roots.append((ancestor.appendingPathComponent(tool == .codex ? ".codex/skills" : ".claude/skills"), "Project"))
            if tool == .codex { roots.append((ancestor.appendingPathComponent(".agents/skills"), "Project")) }
        }
        var found: [String: SkillSuggestion] = [:]
        for (root, source) in roots {
            for skill in children(of: root) where found.count < 600 {
                let manifest = skill.appendingPathComponent("SKILL.md")
                guard let content = manifestText(manifest),
                      let item = parse(content, fallback: skill.lastPathComponent, source: source) else { continue }
                found[item.name.lowercased()] = found[item.name.lowercased()] ?? item
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func matches(_ skills: [SkillSuggestion], query: String) -> [SkillSuggestion] {
        let query = query.lowercased()
        return skills.filter { query.isEmpty || $0.name.lowercased().contains(query) }
            .sorted { left, right in
                let leftStarts = left.name.lowercased().hasPrefix(query)
                let rightStarts = right.name.lowercased().hasPrefix(query)
                if leftStarts != rightStarts { return leftStarts }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }.prefix(6).map { $0 }
    }

    private static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    private static func ancestors(of folder: URL) -> [URL] {
        var result: [URL] = []
        var current = folder.standardizedFileURL
        for _ in 0..<12 {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return result
    }

    private static func manifestText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parse(_ content: String, fallback: String, source: String) -> SkillSuggestion? {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return nil }
        var name = fallback
        var description = ""
        for line in lines.dropFirst().prefix(40) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { break }
            if line.hasPrefix("name:") { name = value(line.dropFirst(5)) }
            if line.hasPrefix("description:") { description = value(line.dropFirst(12)) }
        }
        guard !name.isEmpty, name.count < 100, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return SkillSuggestion(name: name, description: description, source: source)
    }

    private static func value(_ text: Substring) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2 && (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func codexPluginRoots(home: URL) -> [(URL, String)] {
        let config = home.appendingPathComponent(".codex/config.toml")
        guard let content = try? String(contentsOf: config, encoding: .utf8) else { return [] }
        let cache = home.appendingPathComponent(".codex/plugins/cache")
        var plugin: String?
        var enabled: [String] = []
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[plugins.\"") && line.hasSuffix("\"]") {
                plugin = String(line.dropFirst(10).dropLast(2))
            } else if line.hasPrefix("[") {
                plugin = nil
            } else if line == "enabled = true", let plugin {
                enabled.append(plugin)
            }
        }
        var roots: [(URL, String)] = []
        for identifier in enabled {
            let pieces = identifier.split(separator: "@", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let versions = cache.appendingPathComponent(pieces[1]).appendingPathComponent(pieces[0])
            guard let latest = children(of: versions).sorted(by: {
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
            }).first else { continue }
            roots.append((latest.appendingPathComponent("skills"), pieces[0]))
        }
        return roots
    }
}
