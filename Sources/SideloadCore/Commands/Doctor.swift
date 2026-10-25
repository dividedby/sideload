/// `doctor`: read-only environment checks. `ok` is false only if some check has severity `fail`.
public enum Doctor {
    public static let checks: [any Check] = [
        XcodeCheck(), CLTCheck(), CertificateCheck(), FreeCertificateCheck(), DeviceCheck(), AppleTVCheck(), DiskCheck(),
    ]

    /// A check that throws is reported as a `fail` row, never as an exception.
    static func runCheck(_ check: any Check, _ services: Services) async -> [CheckResult] {
        do {
            return try await check.run(services)
        } catch {
            let (what, fix): (String, String?)
            if let e = error as? SideloadError {
                (what, fix) = (e.code, e.fix)
            } else {
                (what, fix) = (String(describing: error), nil)
            }
            return [
                CheckResult(
                    id: check.id, severity: .fail, message: "Check crashed: \(what)",
                    fix: fix ?? "Re-run `sideload doctor`; if it persists this is a bug.")
            ]
        }
    }

    public static func run(_ services: Services) async -> Envelope {
        var results: [CheckResult] = []
        for check in checks { results += await runCheck(check, services) }
        let data: [String: JSONValue] = ["checks": .array(results.map(\.json))]
        let failed = results.filter { $0.severity == .fail }
        if failed.isEmpty { return .result("doctor", data) }
        return Envelope(
            ok: false, command: "doctor", data: data,
            errors: failed.map {
                Envelope.Entry(
                    code: "CHECK_" + $0.id.uppercased().replacingOccurrences(of: "-", with: "_"),
                    message: $0.message, fix: $0.fix)
            })
    }
}
