import Foundation

/// The launchd user agent that runs `refresh --auto` (design section 18, "Auto-refresh"), as plist text. Pure: it builds a
/// string. Nothing here writes the file, loads it or runs `launchctl`; the owner does, with the commands
/// `refresh --print-agent` prints.
enum AgentPlist {
    static let label = "io.github.dividedby.sideload.refresh"
    /// launchd's interval between runs; missed ones coalesce into one on wake.
    static let interval = 1800

    /// `logs` is the sideload home's `logs/`; `sideloadHome` is set only when the home is not the default, so the agent's
    /// process finds the same one. No `KeepAlive`: a failed run is not retried before the next interval.
    static func render(binary: String, logs: String, sideloadHome: String?) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
            #"<plist version="1.0">"#,
            "<dict>",
        ]
        // Keys in the order `plutil` writes them (sorted), so the text is stable.
        if let sideloadHome {
            lines += ["\t<key>EnvironmentVariables</key>", "\t<dict>", "\t\t<key>SIDELOAD_HOME</key>"]
            lines += ["\t\t" + string(sideloadHome), "\t</dict>"]
        }
        lines += ["\t<key>Label</key>", "\t" + string(label)]
        lines += ["\t<key>LimitLoadToSessionType</key>", "\t" + string("Aqua")]
        lines += ["\t<key>LowPriorityIO</key>", "\t<true/>"]
        lines += ["\t<key>ProcessType</key>", "\t" + string("Background")]
        lines += ["\t<key>ProgramArguments</key>", "\t<array>"]
        lines += [binary, "refresh", "--auto"].map { "\t\t" + string($0) }
        lines += ["\t</array>"]
        lines += ["\t<key>RunAtLoad</key>", "\t<false/>"]
        lines += ["\t<key>StandardErrorPath</key>", "\t" + string(logs + "/launchd-refresh.err")]
        lines += ["\t<key>StandardOutPath</key>", "\t" + string("/dev/null")]
        lines += ["\t<key>StartInterval</key>", "\t<integer>\(interval)</integer>"]
        lines += ["</dict>", "</plist>", ""]
        return lines.joined(separator: "\n")
    }

    private static func string(_ value: String) -> String { "<string>\(escape(value))</string>" }

    /// XML text escaping. A control character cannot be written in XML 1.0 at all, so `printAgent` refuses a path with one.
    static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }

    /// The word as a shell argument: left bare when it is made of safe characters, else single-quoted.
    static func shellQuoted(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_@%+=:,./-".contains($0)) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

extension RefreshCommand {
    /// `refresh --print-agent [--binary <abs path>]`: prints the agent's plist, where to put it and the commands the owner
    /// runs to load, start and stop it (design section 18). No lock, no subprocess, no file is written and no device is
    /// read: agents run it freely; the printed `launchctl` commands are the owner's (Ask the owner first).
    public static func printAgent(_ services: Services, binary: String?) -> Envelope {
        let user = services.localUser.homeDirectory.isEmpty ? NSHomeDirectory() : services.localUser.homeDirectory
        let bin = binary ?? user + "/.local/bin/sideload"
        guard bin.hasPrefix("/"), !bin.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            return .fail(
                command, code: "USAGE", message: "--binary must be an absolute path without control characters.",
                fix: "Pass the full path of the installed sideload binary, e.g. --binary \(user)/.local/bin/sideload.")
        }

        let home = services.home
        let isDefaultHome = home.home == Paths.resolveHome(environment: [:], homeDirectory: user).home
        let plist = AgentPlist.render(binary: bin, logs: home.logs, sideloadHome: isDefaultHome ? nil : home.home)
        let agents = user + "/Library/LaunchAgents"
        let path = agents + "/" + AgentPlist.label + ".plist"
        let quoted = AgentPlist.shellQuoted
        let target = "gui/$(id -u)"

        // The plist goes in with a quoted here-document, so nothing in it is expanded by the shell. launchd needs the
        // log folder to exist; it does not make it.
        let install: [JSONValue] = [
            .string("mkdir -p \(quoted(agents)) \(quoted(home.logs))"),
            .string("cat > \(quoted(path)) <<'SIDELOAD_PLIST_END'\n\(plist)SIDELOAD_PLIST_END"),
            .string("/usr/bin/plutil -lint \(quoted(path))"),
            .string("launchctl bootstrap \(target) \(quoted(path))"),
            .string("launchctl kickstart -k \(target)/\(AgentPlist.label)"),
        ]
        // The first stops it at once and keeps the agent loaded; `rm` of that file resumes. The second unloads it.
        let stop: [JSONValue] = [
            .string("touch \(quoted(home.refreshDisabled))"),
            .string("launchctl bootout \(target)/\(AgentPlist.label)"),
        ]
        return Envelope(
            ok: true, command: command,
            data: [
                "label": .string(AgentPlist.label), "path": .string(path), "plist": .string(plist),
                "install": .array(install), "stop": .array(stop),
            ],
            keepsUserPaths: true)
    }
}
