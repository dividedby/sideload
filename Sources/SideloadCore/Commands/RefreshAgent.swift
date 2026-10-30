import Foundation

/// The launchd user agents sideload prints plists for (design sections 11 and 18), as plist text. Pure: it builds a
/// string. Nothing here writes the file, loads it or runs `launchctl`; the owner does, with the commands
/// `refresh --print-agent` and `status --print-agent` print.
enum AgentPlist {
    /// When launchd starts the agent.
    enum Schedule: Equatable {
        /// Every `seconds`; missed runs coalesce into one on wake.
        case interval(seconds: Int)
        /// Every day at this local time.
        case daily(hour: Int, minute: Int)
    }

    /// What differs between the agents. `arguments` follow the binary.
    struct Agent: Equatable {
        var label: String
        var arguments: [String]
        var schedule: Schedule
        var runAtLoad: Bool
        /// The file in `logs/` that gets the agent's stderr.
        var errorFile: String
        /// Whether the agent has a kill-switch file (`refresh.disabled`) the stop commands can `touch`.
        var hasKillSwitch: Bool

        /// `refresh --auto` every 30 minutes (`StartInterval`); launchd coalesces missed runs.
        static let refresh = Agent(
            label: "io.github.dividedby.sideload.refresh", arguments: ["refresh", "--auto"], schedule: .interval(seconds: 1800),
            runAtLoad: false, errorFile: "launchd-refresh.err", hasKillSwitch: true)
        /// `status --notify` daily at 09:00, and once when it is loaded.
        static let status = Agent(
            label: "io.github.dividedby.sideload.status", arguments: ["status", "--notify"],
            schedule: .daily(hour: 9, minute: 0), runAtLoad: true, errorFile: "launchd-status.err", hasKillSwitch: false)
    }

    /// `logs` is the sideload home's `logs/`; `sideloadHome` is set only when the home is not the default, so the agent's
    /// process finds the same one. No `KeepAlive`: a failed run is not retried before the next one is due.
    static func render(_ agent: Agent, binary: String, logs: String, sideloadHome: String?) -> String {
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
        lines += ["\t<key>Label</key>", "\t" + string(agent.label)]
        lines += ["\t<key>LimitLoadToSessionType</key>", "\t" + string("Aqua")]
        lines += ["\t<key>LowPriorityIO</key>", "\t<true/>"]
        lines += ["\t<key>ProcessType</key>", "\t" + string("Background")]
        lines += ["\t<key>ProgramArguments</key>", "\t<array>"]
        lines += ([binary] + agent.arguments).map { "\t\t" + string($0) }
        lines += ["\t</array>"]
        lines += ["\t<key>RunAtLoad</key>", agent.runAtLoad ? "\t<true/>" : "\t<false/>"]
        lines += ["\t<key>StandardErrorPath</key>", "\t" + string(logs + "/" + agent.errorFile)]
        lines += ["\t<key>StandardOutPath</key>", "\t" + string("/dev/null")]
        switch agent.schedule {
        case .interval(let seconds):
            lines += ["\t<key>StartInterval</key>", "\t<integer>\(seconds)</integer>"]
        case .daily(let hour, let minute):
            lines += ["\t<key>StartCalendarInterval</key>", "\t<dict>"]
            lines += ["\t\t<key>Hour</key>", "\t\t<integer>\(hour)</integer>"]
            lines += ["\t\t<key>Minute</key>", "\t\t<integer>\(minute)</integer>"]
            lines += ["\t</dict>"]
        }
        lines += ["</dict>", "</plist>", ""]
        return lines.joined(separator: "\n")
    }

    private static func string(_ value: String) -> String { "<string>\(escape(value))</string>" }

    /// XML text escaping. A control character cannot be written in XML 1.0 at all, so `printAgent` refuses every path with one.
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

    static func hasControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// The word as a shell argument: left bare when it is made of safe characters, else single-quoted.
    static func shellQuoted(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_@%+=:,./-".contains($0)) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

extension AgentPlist {
    /// The envelope both `--print-agent` commands print: the plist, where to put it and the commands the owner runs to load,
    /// start and stop it. No lock, no subprocess, no file is written and no device is read: agents run it freely; the printed
    /// `launchctl` commands are the owner's (Ask the owner first). `command` is the CLI command, for the messages.
    static func printed(_ agent: Agent, command: String, _ services: Services, binary: String?) -> Envelope {
        let user = services.localUser.homeDirectory.isEmpty ? NSHomeDirectory() : services.localUser.homeDirectory
        let bin = binary ?? user + "/.local/bin/sideload"
        guard bin.hasPrefix("/"), !hasControlCharacter(bin) else {
            return .fail(
                command, code: "USAGE", message: "--binary must be an absolute path without control characters.",
                fix: "Pass the full path of the installed sideload binary, e.g. --binary \(user)/.local/bin/sideload.")
        }

        let home = services.home
        // The other paths come from SIDELOAD_HOME and the user's home: one with a control character could not go in the
        // plist, and a line break could end the printed here-document early.
        let paths = [user, home.home, home.logs] + (agent.hasKillSwitch ? [home.refreshDisabled] : [])
        guard !paths.contains(where: hasControlCharacter) else {
            return .fail(
                command, code: "PATH_UNSAFE",
                message: "The sideload home or the home folder path contains a control character, which a launchd plist cannot hold.",
                fix: "Use a home folder and a SIDELOAD_HOME without control characters, then run \(command) --print-agent again.")
        }
        let isDefaultHome = home.home == Paths.resolveHome(environment: [:], homeDirectory: user).home
        let plist = render(agent, binary: bin, logs: home.logs, sideloadHome: isDefaultHome ? nil : home.home)
        let agents = user + "/Library/LaunchAgents"
        let path = agents + "/" + agent.label + ".plist"
        let quoted = shellQuoted
        let target = "gui/$(id -u)"

        // The plist goes in with a quoted here-document, so nothing in it is expanded by the shell. launchd needs the
        // log folder to exist; it does not make it.
        let install: [JSONValue] = [
            .string("mkdir -p \(quoted(agents)) \(quoted(home.logs))"),
            .string("cat > \(quoted(path)) <<'SIDELOAD_PLIST_END'\n\(plist)SIDELOAD_PLIST_END"),
            .string("/usr/bin/plutil -lint \(quoted(path))"),
            .string("launchctl bootstrap \(target) \(quoted(path))"),
            .string("launchctl kickstart -k \(target)/\(agent.label)"),
        ]
        // With a kill switch, `touch` of that file stops the agent at once and keeps it loaded (`rm` resumes it); `bootout`
        // unloads it.
        let stop: [JSONValue] =
            (agent.hasKillSwitch ? [.string("touch \(quoted(home.refreshDisabled))")] : [])
            + [.string("launchctl bootout \(target)/\(agent.label)")]
        return Envelope(
            ok: true, command: command,
            data: [
                "label": .string(agent.label), "path": .string(path), "plist": .string(plist),
                "install": .array(install), "stop": .array(stop),
            ],
            keepsUserPaths: true)
    }
}

extension RefreshCommand {
    /// `refresh --print-agent [--binary <abs path>]` (design section 18).
    public static func printAgent(_ services: Services, binary: String?) -> Envelope {
        AgentPlist.printed(.refresh, command: command, services, binary: binary)
    }
}

extension StatusCommand {
    /// `status --print-agent [--binary <abs path>]` (design section 11): the daily `status --notify` agent. Pure, like the
    /// refresh one.
    public static func printAgent(_ services: Services, binary: String?) -> Envelope {
        AgentPlist.printed(.status, command: command, services, binary: binary)
    }
}
