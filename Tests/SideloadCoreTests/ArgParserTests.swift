import Testing

@testable import SideloadCore
@testable import sideload

private let spec = ArgSpec(values: ["alias", "match"], flags: ["yes"])

private func usageMessage(_ args: [String]) -> String? {
    do {
        _ = try ArgParser.parse(args, spec: spec)
        return nil
    } catch let e as SideloadError {
        #expect(e.code == "USAGE")
        #expect(e.fix == "Run `sideload help`.")
        return e.message
    } catch {
        return "wrong error type"
    }
}

@Suite("ArgParser")
struct ArgParserTests {
    @Test("--opt value, --opt=value, flags and positionals in any order")
    func forms() throws {
        let p = try ArgParser.parse(["save", "--alias", "a", "--match=b c", "--yes", "extra"], spec: spec)
        #expect(p.positionals == ["save", "extra"])
        #expect(p.values == ["alias": "a", "match": "b c"])
        #expect(p.flags == ["yes"])
        #expect(!p.help)
    }

    @Test("an empty --opt= value is a value")
    func emptyInline() throws {
        let p = try ArgParser.parse(["--alias="], spec: spec)
        #expect(p.values == ["alias": ""])
    }

    @Test("the last occurrence wins")
    func repeated() throws {
        let p = try ArgParser.parse(["--alias", "a", "--alias=b"], spec: spec)
        #expect(p.values == ["alias": "b"])
    }

    @Test("-h and --help set help for every schema")
    func help() throws {
        #expect(try ArgParser.parse(["-h"], spec: ArgSpec()).help)
        #expect(try ArgParser.parse(["--help"], spec: ArgSpec()).help)
        #expect(try ArgParser.parse(["--alias", "a", "-h"], spec: spec).help)
    }

    @Test("an unknown option is USAGE, long or short")
    func unknown() {
        #expect(usageMessage(["--nope"]) == "Unknown option '--nope'.")
        #expect(usageMessage(["--nope=1"]) == "Unknown option '--nope'.")
        #expect(usageMessage(["-x"]) == "Unknown option '-x'.")
        #expect(usageMessage(["-yes"]) == "Unknown option '-yes'.")
        #expect(usageMessage(["--"] + ["--nope"]) == nil, "after -- everything is a positional")
    }

    @Test("a value option needs a value that does not look like an option")
    func values() {
        #expect(usageMessage(["--alias"]) == "Option '--alias <value>' argument missing.")
        #expect(usageMessage(["--alias", "--yes"])?.contains("ambiguous") == true)
        #expect(usageMessage(["--alias", "-x"])?.contains("--alias=-x") == true)
        #expect(usageMessage(["--alias=-x"]) == nil, "= form allows a leading dash")
    }

    @Test("a flag takes no value")
    func flagWithValue() {
        #expect(usageMessage(["--yes=1"]) == "Option '--yes' does not take a value.")
        #expect(usageMessage(["--help=1"]) == "Option '--help' does not take a value.")
    }

    @Test("-- ends options; a lone - is a positional")
    func terminator() throws {
        let p = try ArgParser.parse(["a", "--", "--yes", "-h"], spec: spec)
        #expect(p.positionals == ["a", "--yes", "-h"])
        #expect(p.flags.isEmpty)
        #expect(try ArgParser.parse(["-"], spec: spec).positionals == ["-"])
    }

    @Test("an option name is matched exactly, not by prefix")
    func exact() {
        #expect(usageMessage(["--ali", "x"]) == "Unknown option '--ali'.")
        #expect(usageMessage(["--yes2"]) == "Unknown option '--yes2'.")
    }
}
