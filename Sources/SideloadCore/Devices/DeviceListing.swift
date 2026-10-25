extension DeviceCtl {
    /// `devicectl list devices`, parsed. Nil when devicectl failed (non-zero exit or no parseable output);
    /// wrapper errors (`OUTPUT_LIMIT`, config errors) still throw. Callers decide what a failure means.
    public func listDevices() async throws -> [ListedDevice]? {
        let res = try await run(["list", "devices"], timeoutSec: 20)
        guard res.code == 0, let json = res.json else { return nil }
        return DeviceList.parse(json)
    }

    /// Like `listDevices`, but parses whatever JSON devicectl wrote even when it exited non-zero. Only the
    /// canary's log scrubbing uses it: more names found
    /// means more scrubbed. Nil when there is no JSON.
    public func listDevicesForScrubbing() async throws -> [ListedDevice]? {
        let res = try await run(["list", "devices"], timeoutSec: 20)
        guard let json = res.json else { return nil }
        return DeviceList.parse(json)
    }
}
