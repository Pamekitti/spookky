import Foundation
import SpookkyCore

enum AgentShellIntegration {
    static func prepare(executable: String, arguments: [String], root: URL, environment: inout [String: String]) throws {
        guard URL(fileURLWithPath: executable).lastPathComponent == "zsh", !arguments.contains("-f") else { return }
        let folder = root.appendingPathComponent("agent-zsh")
        try PrivateFiles.directory(folder)
        let inherited = environment["ZDOTDIR"] ?? ProcessInfo.processInfo.environment["ZDOTDIR"]
        environment["SPOOKKY_USER_ZDOTDIR"] = inherited ?? ""
        environment["SPOOKKY_ZDOTDIR_SET"] = inherited == nil ? "0" : "1"
        environment["SPOOKKY_AGENT_BIN"] = root.appendingPathComponent("agent-bin").path
        environment["ZDOTDIR"] = folder.path
        for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            let continueStartup = name == ".zshenv" || name == ".zprofile" ? "[[ -o interactive || -o login ]]" : (name == ".zshrc" ? "[[ -o login ]]" : "false")
            // User startup files see their own ZDOTDIR. Only startup dispatch uses the private folder.
            let script = """
            if [[ ${SPOOKKY_ZDOTDIR_SET:-0} == 1 ]]; then
              export ZDOTDIR="$SPOOKKY_USER_ZDOTDIR"
            else
              unset ZDOTDIR
            fi
            if [[ -r "${ZDOTDIR:-$HOME}/\(name)" ]]; then
              source "${ZDOTDIR:-$HOME}/\(name)"
            fi
            if (( ${+ZDOTDIR} )); then
              export SPOOKKY_USER_ZDOTDIR="$ZDOTDIR" SPOOKKY_ZDOTDIR_SET=1
            else
              export SPOOKKY_USER_ZDOTDIR='' SPOOKKY_ZDOTDIR_SET=0
            fi
            if \(continueStartup); then
              export ZDOTDIR=\(ShellCommand.render([folder.path]))
            elif [[ -o interactive ]]; then
              _spookky_activity_path() {
                if [[ -d "$SPOOKKY_AGENT_BIN" ]]; then
                  path=("$SPOOKKY_AGENT_BIN" ${path:#"$SPOOKKY_AGENT_BIN"})
                  export PATH
                fi
              }
              _spookky_activity_path
              precmd_functions=(${precmd_functions:#_spookky_activity_path} _spookky_activity_path)
            fi
            """ + "\n"
            let path = folder.appendingPathComponent(name)
            if (try? String(contentsOf: path, encoding: .utf8)) != script {
                try script.write(to: path, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
        }
    }
}
