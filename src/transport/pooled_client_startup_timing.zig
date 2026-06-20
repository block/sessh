const std = @import("std");

pub const Measurements = struct {
    request_to_open_ms: u64,
    open_to_open_ok_ms: u64,
    open_ok_to_first_payload_ms: u64,
    request_to_first_payload_ms: u64,
};

pub const PooledClientStartupTiming = struct {
    request_started_ms: u64 = 0,
    mux_open_sent_ms: u64 = 0,
    mux_open_ok_ms: u64 = 0,
    first_payload_ms: u64 = 0,
    logged: bool = false,

    pub fn startedNow() PooledClientStartupTiming {
        return .{ .request_started_ms = nowUnixMs() };
    }

    pub fn noteMuxOpenSent(self: *PooledClientStartupTiming) void {
        self.mux_open_sent_ms = nowUnixMs();
    }

    pub fn noteOpenOk(self: *PooledClientStartupTiming) void {
        if (self.mux_open_ok_ms == 0) self.mux_open_ok_ms = nowUnixMs();
    }

    pub fn noteFirstPayload(self: *PooledClientStartupTiming) bool {
        if (self.first_payload_ms != 0) return false;
        self.first_payload_ms = nowUnixMs();
        return true;
    }

    pub fn markLogged(self: *PooledClientStartupTiming) bool {
        if (self.logged) return false;
        self.logged = true;
        return true;
    }

    pub fn measurements(self: PooledClientStartupTiming) Measurements {
        return .{
            .request_to_open_ms = elapsedMs(self.request_started_ms, self.mux_open_sent_ms),
            .open_to_open_ok_ms = elapsedMs(self.mux_open_sent_ms, self.mux_open_ok_ms),
            .open_ok_to_first_payload_ms = elapsedMs(self.mux_open_ok_ms, self.first_payload_ms),
            .request_to_first_payload_ms = elapsedMs(self.request_started_ms, self.first_payload_ms),
        };
    }
};

fn nowUnixMs() u64 {
    const ms = std.time.milliTimestamp();
    if (ms <= 0) return 0;
    return @intCast(ms);
}

fn elapsedMs(start_ms: u64, end_ms: u64) u64 {
    if (start_ms == 0 or end_ms == 0 or end_ms < start_ms) return 0;
    return end_ms - start_ms;
}

test "measurements treat missing or reversed timestamps as zero" {
    const timing = PooledClientStartupTiming{
        .request_started_ms = 100,
        .mux_open_sent_ms = 150,
        .mux_open_ok_ms = 125,
        .first_payload_ms = 0,
    };

    const measurements = timing.measurements();
    try std.testing.expectEqual(@as(u64, 50), measurements.request_to_open_ms);
    try std.testing.expectEqual(@as(u64, 0), measurements.open_to_open_ok_ms);
    try std.testing.expectEqual(@as(u64, 0), measurements.open_ok_to_first_payload_ms);
    try std.testing.expectEqual(@as(u64, 0), measurements.request_to_first_payload_ms);
}

test "startup timing records first payload and logs once" {
    var timing = PooledClientStartupTiming.startedNow();
    timing.noteMuxOpenSent();
    timing.noteOpenOk();
    try std.testing.expect(timing.noteFirstPayload());
    try std.testing.expect(!timing.noteFirstPayload());
    try std.testing.expect(timing.markLogged());
    try std.testing.expect(!timing.markLogged());
}
