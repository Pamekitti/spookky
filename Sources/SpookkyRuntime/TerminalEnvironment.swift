import Foundation

public enum TerminalEnvironment {
    public static func nativePTY(inherited: [String: String], overrides: [String: String]) -> [String: String] {
        var values = inherited
        // Launchers may suppress color for captured output. This process owns a real terminal.
        for key in ["NO_COLOR", "CLICOLOR", "CLICOLOR_FORCE", "FORCE_COLOR"] { values.removeValue(forKey: key) }
        let terminal = values["TERM"] ?? ""
        if terminal.isEmpty || terminal == "dumb" {
            values["TERM"] = values["TMUX"] == nil ? "xterm-ghostty" : "tmux-256color"
        }
        values["COLORTERM"] = "truecolor"
        return values.merging(overrides) { _, explicit in explicit }
    }
}
