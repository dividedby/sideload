import SideloadCore

let allCommands: [JSONValue] = ["doctor", "device", "canary", "portal", "export-cert", "fetch", "sign", "install", "status", "ledger", "inspect", "provision", "app", "slot", "refresh", "updates"]
let builtCommands: [JSONValue] = ["doctor", "device", "canary", "ledger", "portal", "export-cert", "status", "inspect", "fetch", "provision", "sign", "install", "refresh", "app", "slot", "updates"]

private let helpFlags: Set<String> = ["-h", "--help"]

private func help() -> Envelope {
    .result("help", [
        "commands": .array(allCommands),
        "built": .array(builtCommands),
        "usage": [
            "canary --device <alias> [--keep] [--evidence] --yes",
            "canary history",
            "device save|list ...",
            "device auto-refresh --alias <alias> --on|--off --yes",
            "device slots --alias <alias> --reserved 0-3 --yes",
            "device lendable --alias <alias> --app <apollo|stremio-ios|stremio-tvos|filler>|--none --yes",
            "device remove --alias <alias> --yes",
            "inspect <path.ipa>",
            "fetch --app <apollo|stremio-ios|stremio-tvos> [--approve --version <v>]",
            "updates [--app <apollo|stremio-ios|stremio-tvos>] [--force]",
            "provision --app <apollo|stremio-ios|stremio-tvos|filler> --device <alias> [--register-device] [--renew] --yes",
            "provision --renew-ack --yes",
            "sign --app <apollo|stremio-ios|stremio-tvos> --device <alias> --yes",
            "install --app <apollo|stremio-ios|stremio-tvos|filler> --device <alias> --yes",
            .string("refresh --device <alias> [--app <apollo|stremio-ios|stremio-tvos|filler>] [--within 1-\(RefreshCommand.maxWithin) | --force] --yes"),
            "refresh --auto",
            "refresh --print-agent [--binary <absolute path>]",
            "app remove --app <apollo|stremio-ios|stremio-tvos|filler> --device <alias> --yes",
            "slot lend --device <alias>|--udid <id> --to lab",
            "slot return --device <alias>|--udid <id>",
            "slot restore --device <alias> [--app <apollo|stremio-ios|stremio-tvos|filler>] --yes",
            "export-cert --device <alias> [--profile <uuid>] [--out <dir>] [--copy-password] --yes",
            "ledger [refresh]",
            "portal [certificates|bundle-ids|devices|profiles] [--show-identifiers]",
            "status",
        ],
        "docs": "docs/design.md",
        "note": "commands not listed under `built` are not built yet; see docs/design.md",
    ])
}

private let deviceSpec = ArgSpec(values: ["alias", "match", "platform", "reserved", "app"], flags: ["yes", "on", "off", "none"])
private let canarySpec = ArgSpec(values: ["device"], flags: ["yes", "keep", "evidence"])

private let exportCertSpec = ArgSpec(values: ["device", "profile", "out"], flags: ["yes", "copy-password"])
private let provisionSpec = ArgSpec(values: ["app", "device"], flags: ["yes", "register-device", "renew", "renew-ack"])
private let signSpec = ArgSpec(values: ["app", "device"], flags: ["yes"])
private let installSpec = ArgSpec(values: ["app", "device"], flags: ["yes"])
private let refreshSpec = ArgSpec(values: ["device", "app", "within", "binary"], flags: ["yes", "force", "auto", "print-agent"])
// `--auto` and `--print-agent` each take no other option (`--binary` belongs to `--print-agent`).
private let refreshAutoConflicts = ["device", "app", "within", "yes", "force", "binary", "print-agent"]
private let refreshPrintAgentConflicts = ["device", "app", "within", "yes", "force", "auto"]
private let appSpec = ArgSpec(values: ["app", "device"], flags: ["yes"])
private let slotSpec = ArgSpec(values: ["device", "udid", "to", "app"], flags: ["yes"])
private let fetchSpec = ArgSpec(values: ["app", "version"], flags: ["approve"])
private let updatesSpec = ArgSpec(values: ["app"], flags: ["force"])
private let portalSpec = ArgSpec(flags: ["show-identifiers"])
// `status` v1 is read-only; the designed `--notify` and `--print-agent` parse only so they can say they are not built.
private let statusDeferredFlags = ["notify", "print-agent"]
private let statusSpec = ArgSpec(flags: Set(statusDeferredFlags))

private func unexpectedPositionals(_ command: String) -> Envelope {
    .fail(command, code: "USAGE", message: "Unexpected positional arguments.", fix: "Run `sideload help`.")
}

/// Dispatches one invocation to a command and returns its single result object. `services` defaults to the
/// live set; tests pass fakes. Commands not built yet report `NOT_IMPLEMENTED`.
func run(argv: [String], services: Services? = nil) async -> Envelope {
    guard argv.first == "provision" else { return await dispatch(argv: argv, services: services) }
    // The one place a provision envelope is finalized: whichever way `dispatch` returns (a parse-level USAGE, a failed
    // `ensureHome`, the command itself), what an earlier --renew run left in tmp/ is in it. The record is read first,
    // before anything of this run can change it.
    let services = services ?? liveServices()
    let record = ProvisionCommand.RenewRecord.read(services)
    let envelope = await dispatch(argv: argv, services: services)
    return record.merged(into: envelope, listed: envelope.ok && envelope.data["renewMovesAcknowledged"] != nil)
}

private func dispatch(argv: [String], services: Services?) async -> Envelope {
    guard let command = argv.first, command != "help" else { return help() }
    let rest = Array(argv.dropFirst())
    let wantsHelp = rest.contains { helpFlags.contains($0) }

    if command.hasPrefix("-") {
        if helpFlags.contains(command) { return help() }
        return Envelope.from(ArgParser.usage("Unknown option '\(command)'."), command: "sideload")
    }

    let spec: ArgSpec
    switch command {
    case "doctor": spec = ArgSpec()
    case "device": spec = deviceSpec
    case "canary": spec = canarySpec
    case "ledger": spec = ArgSpec()
    case "portal": spec = portalSpec
    case "export-cert": spec = exportCertSpec
    case "status": spec = statusSpec
    case "inspect": spec = ArgSpec()
    case "fetch": spec = fetchSpec
    case "updates": spec = updatesSpec
    case "provision": spec = provisionSpec
    case "sign": spec = signSpec
    case "install": spec = installSpec
    case "refresh": spec = refreshSpec
    case "app": spec = appSpec
    case "slot": spec = slotSpec
    default:
        if wantsHelp { return help() }
        guard allCommands.contains(.string(command)) else {
            return .fail(command, code: "UNKNOWN_COMMAND", message: "Unknown command \"\(command)\".", fix: "Run `sideload help`.")
        }
        return .fail(
            command, code: "NOT_IMPLEMENTED",
            message: "\"\(command)\" is not built yet.",
            fix: "Not built yet; see docs/design.md for the plan.")
    }

    let parsed: ParsedArgs
    do {
        parsed = try ArgParser.parse(rest, spec: spec)
    } catch {
        return .from(error, command: command)
    }
    if parsed.help { return help() }

    // `device` takes one subcommand, `canary` only `history`, `ledger` only `refresh`, `portal` one list name, `inspect` one path; `doctor` and `status` take none.
    let maxPositionals = ["device", "canary", "ledger", "portal", "inspect", "app", "slot"].contains(command) ? 1 : 0
    if parsed.positionals.count > maxPositionals { return unexpectedPositionals(command) }
    if command == "canary", let sub = parsed.positionals.first, sub != "history" {
        return unexpectedPositionals(command)
    }

    if command == "ledger", let sub = parsed.positionals.first, sub != "refresh" {
        return unexpectedPositionals(command)
    }

    if command == "status", let flag = statusDeferredFlags.first(where: parsed.flags.contains) {
        return .fail(
            command, code: "USAGE", message: "status --\(flag) is not built yet (status v1 is read-only).",
            fix: "Run `sideload status` with no options.")
    }

    if command == "refresh", parsed.flags.contains("print-agent"),
        let option = refreshPrintAgentConflicts.first(where: { parsed.values[$0] != nil || parsed.flags.contains($0) })
    {
        return .fail(
            command, code: "USAGE", message: "refresh --print-agent takes no other option but --binary (--\(option) was given).",
            fix: "Run `sideload refresh --print-agent [--binary <absolute path>]` on its own.")
    }

    if command == "refresh", parsed.values["binary"] != nil, !parsed.flags.contains("print-agent") {
        return .fail(
            command, code: "USAGE", message: "--binary belongs to refresh --print-agent.",
            fix: "Run `sideload refresh --print-agent --binary <absolute path>`.")
    }

    if command == "refresh", parsed.flags.contains("auto"),
        let option = refreshAutoConflicts.first(where: { parsed.values[$0] != nil || parsed.flags.contains($0) })
    {
        return .fail(
            command, code: "USAGE", message: "refresh --auto takes no other option (--\(option) was given).",
            fix: "Run `sideload refresh --auto` on its own; the opted-in devices and the limits are the policy's.")
    }

    var portalResource: PortalResource?
    if command == "portal", let name = parsed.positionals.first {
        guard let resource = PortalResource(cliName: name) else {
            return .fail(
                command, code: "USAGE", message: "Unknown portal list.",
                fix: "Use certificates, bundle-ids, devices or profiles, or no argument for all four.")
        }
        portalResource = resource
    }

    let services = services ?? liveServices()
    // Pure: it prints text, so it does not even create the home.
    if command == "refresh", parsed.flags.contains("print-agent") {
        return RefreshCommand.printAgent(services, binary: parsed.values["binary"])
    }
    do {
        try services.home.ensureHome()
    } catch {
        return .from(error, command: command)
    }
    if command == "doctor" { return await Doctor.run(services) }
    if command == "status" { return StatusCommand.run(services) }
    if command == "ledger" { return await LedgerCommand.run(services, LedgerOptions(sub: parsed.positionals.isEmpty ? .show : .refresh)) }
    if command == "fetch" {
        return await FetchCommand.run(services, FetchOptions(app: parsed.values["app"], approve: parsed.flags.contains("approve"), version: parsed.values["version"]))
    }
    if command == "updates" {
        return await UpdatesCommand.run(services, UpdatesOptions(app: parsed.values["app"], force: parsed.flags.contains("force")))
    }
    if command == "provision" {
        return await ProvisionCommand.run(
            services,
            ProvisionOptions(
                app: parsed.values["app"], device: parsed.values["device"],
                registerDevice: parsed.flags.contains("register-device"), renew: parsed.flags.contains("renew"),
                yes: parsed.flags.contains("yes"), renewAck: parsed.flags.contains("renew-ack")))
    }
    if command == "sign" {
        return await SignCommand.run(
            services,
            SignOptions(app: parsed.values["app"], device: parsed.values["device"], yes: parsed.flags.contains("yes")))
    }
    if command == "install" {
        return await InstallCommand.run(
            services,
            InstallOptions(app: parsed.values["app"], device: parsed.values["device"], yes: parsed.flags.contains("yes")))
    }
    if command == "refresh", parsed.flags.contains("auto") { return await RefreshCommand.runAuto(services) }
    if command == "refresh" {
        return await RefreshCommand.run(
            services,
            RefreshOptions(
                device: parsed.values["device"], app: parsed.values["app"], within: parsed.values["within"],
                force: parsed.flags.contains("force"), yes: parsed.flags.contains("yes")))
    }
    if command == "app" {
        return await AppCommand.run(
            services,
            AppOptions(
                sub: parsed.positionals.first, app: parsed.values["app"], device: parsed.values["device"],
                yes: parsed.flags.contains("yes")))
    }
    if command == "slot" {
        return await SlotCommand.run(
            services,
            SlotOptions(
                sub: parsed.positionals.first, device: parsed.values["device"], udid: parsed.values["udid"],
                to: parsed.values["to"], app: parsed.values["app"], yes: parsed.flags.contains("yes")))
    }
    if command == "inspect" { return await InspectCommand.run(services, InspectOptions(path: parsed.positionals.first)) }
    if command == "export-cert" {
        return await ExportCertCommand.run(
            services,
            ExportCertOptions(
                device: parsed.values["device"], profile: parsed.values["profile"], out: parsed.values["out"],
                yes: parsed.flags.contains("yes"), copyPassword: parsed.flags.contains("copy-password")))
    }
    if command == "portal" {
        return await PortalCommand.run(
            services, PortalOptions(resource: portalResource, showIdentifiers: parsed.flags.contains("show-identifiers")))
    }
    if command == "canary", parsed.positionals.first == "history" {
        // Read-only: no device, no confirmation, no lock, so no canary option applies.
        if !parsed.values.isEmpty || !parsed.flags.isEmpty {
            return .fail(
                "canary history", code: "USAGE", message: "canary history takes no options.",
                fix: "Run `sideload canary history` with no options.")
        }
        return CanaryHistory.run(services)
    }
    if command == "canary" {
        return await CanaryCommand.run(
            services,
            CanaryOptions(
                device: parsed.values["device"], yes: parsed.flags.contains("yes"), keep: parsed.flags.contains("keep"),
                evidence: parsed.flags.contains("evidence")))
    }
    return await DeviceCommand.run(
        services,
        DeviceOptions(
            sub: parsed.positionals.first, alias: parsed.values["alias"], match: parsed.values["match"],
            platform: parsed.values["platform"], on: parsed.flags.contains("on"), off: parsed.flags.contains("off"),
            reserved: parsed.values["reserved"], app: parsed.values["app"], none: parsed.flags.contains("none"),
            yes: parsed.flags.contains("yes")))
}
