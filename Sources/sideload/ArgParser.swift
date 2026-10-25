import SideloadCore

/// A command's option schema. Names are long names without the leading dashes; `-h` and `--help` are
/// accepted by every command.
struct ArgSpec {
    /// Options that take a value: `--opt value` or `--opt=value`.
    var values: Set<String> = []
    /// Boolean flags.
    var flags: Set<String> = []
}

struct ParsedArgs: Equatable {
    var positionals: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    var help: Bool { flags.contains("help") }
}

/// Hand-written parser (design section 7): per-command schema, `--opt value`, `--opt=value`, boolean flags,
/// `-h`, `--` ends options. An unknown option or a missing or ambiguous value is `USAGE`; the number of
/// positionals is the command's business.
enum ArgParser {
    static func parse(_ args: [String], spec: ArgSpec) throws -> ParsedArgs {
        var out = ParsedArgs()
        var i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            if arg == "--" {
                out.positionals += args[i...]
                break
            }
            if arg == "-h" {
                out.flags.insert("help")
            } else if arg.hasPrefix("--") {
                var name = String(arg.dropFirst(2))
                var inline: String?
                if let eq = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: eq)...])
                    name = String(name[..<eq])
                }
                if name == "help" || spec.flags.contains(name) {
                    if inline != nil { throw usage("Option '--\(name)' does not take a value.") }
                    out.flags.insert(name)
                } else if spec.values.contains(name) {
                    if let inline {
                        out.values[name] = inline
                    } else {
                        guard i < args.count else { throw usage("Option '--\(name) <value>' argument missing.") }
                        let value = args[i]
                        guard !value.hasPrefix("-") else {
                            throw usage(
                                "Option '--\(name) <value>' argument is ambiguous. To pass a value starting with a dash, use '--\(name)=\(value)'."
                            )
                        }
                        out.values[name] = value
                        i += 1
                    }
                } else {
                    throw usage("Unknown option '--\(name)'.")
                }
            } else if arg.hasPrefix("-") && arg != "-" {
                throw usage("Unknown option '\(arg)'.")
            } else {
                out.positionals.append(arg)
            }
        }
        return out
    }

    static func usage(_ message: String) -> SideloadError {
        SideloadError("USAGE", message, fix: "Run `sideload help`.")
    }
}
