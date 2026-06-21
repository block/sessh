// JSONL diagnostics formatting for users and harnesses that need machine-readable
// connection events. It mirrors the human diagnostics vocabulary without tying
// callers to a terminal presentation mode.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_blocking = @import("../core/blocking.zig");
const protocol = @import("../protocol/mod.zig");
const pb = protocol.pb;

pub const Event = enum {
    binary_bootstrapping,
    daemon_connecting,
    daemon_connected,
    daemon_disconnected,
    unresponsive,
    ssh_connecting,
    ssh_connected,
    ssh_stderr,
    retry_scheduled,
    retry_now,
    diagnostic,
    status,
    final_failure,

    fn label(self: Event) []const u8 {
        return switch (self) {
            .binary_bootstrapping => "binary_bootstrapping",
            .daemon_connecting => "daemon_connecting",
            .daemon_connected => "daemon_connected",
            .daemon_disconnected => "daemon_disconnected",
            .unresponsive => "unresponsive",
            .ssh_connecting => "ssh_connecting",
            .ssh_connected => "ssh_connected",
            .ssh_stderr => "ssh_stderr",
            .retry_scheduled => "retry_scheduled",
            .retry_now => "retry_now",
            .diagnostic => "diagnostic",
            .status => "status",
            .final_failure => "final_failure",
        };
    }
};

fn writeEvent(blocking: core_blocking.Blocking, fd: c.fd_t, event: Event) !void {
    try blocking.writeAll(fd, "{\"event\":");
    try writeString(blocking, fd, event.label());
    try blocking.writeAll(fd, "}\n");
}

fn writeMessage(blocking: core_blocking.Blocking, fd: c.fd_t, event: Event, message: []const u8) !void {
    try blocking.writeAll(fd, "{\"event\":");
    try writeString(blocking, fd, event.label());
    try blocking.writeAll(fd, ",\"message\":");
    try writeString(blocking, fd, message);
    try blocking.writeAll(fd, "}\n");
}

pub fn writeRetryScheduled(blocking: core_blocking.Blocking, fd: c.fd_t, retry_at_unix_ms: u64) !void {
    var buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "{{\"event\":\"retry_scheduled\",\"retry_at_unix_ms\":{}}}\n",
        .{retry_at_unix_ms},
    );
    try blocking.writeAll(fd, line);
}

fn writeRetryNow(blocking: core_blocking.Blocking, fd: c.fd_t) !void {
    try writeEvent(blocking, fd, .retry_now);
}

pub fn writeConnectionEvent(blocking: core_blocking.Blocking, fd: c.fd_t, event: pb.ConnectionEvent.event_union) !void {
    switch (event) {
        .binary_bootstrapping => try writeEvent(blocking, fd, .binary_bootstrapping),
        .daemon_connecting => try writeEvent(blocking, fd, .daemon_connecting),
        .daemon_connected => try writeEvent(blocking, fd, .daemon_connected),
        .daemon_disconnected => try writeEvent(blocking, fd, .daemon_disconnected),
        .unresponsive => try writeEvent(blocking, fd, .unresponsive),
        .ssh_connecting => try writeEvent(blocking, fd, .ssh_connecting),
        .ssh_connected => try writeEvent(blocking, fd, .ssh_connected),
        .ssh_stderr => |stderr| try writeMessage(blocking, fd, .ssh_stderr, stderr.data),
    }
}

pub fn writeDiagnostic(blocking: core_blocking.Blocking, fd: c.fd_t, message: []const u8) !void {
    try writeMessage(blocking, fd, .diagnostic, message);
}

pub fn writeStatus(blocking: core_blocking.Blocking, fd: c.fd_t, message: []const u8) !void {
    try writeMessage(blocking, fd, .status, message);
}

fn writeFinalFailure(blocking: core_blocking.Blocking, fd: c.fd_t, message: []const u8) !void {
    try writeMessage(blocking, fd, .final_failure, message);
}

fn writeString(blocking: core_blocking.Blocking, fd: c.fd_t, value: []const u8) !void {
    // Minimal JSON string writer for diagnostics. It escapes control characters
    // so JSONL consumers can parse each event as one physical line.
    try blocking.writeAll(fd, "\"");
    for (value) |byte| switch (byte) {
        '"' => try blocking.writeAll(fd, "\\\""),
        '\\' => try blocking.writeAll(fd, "\\\\"),
        '\n' => try blocking.writeAll(fd, "\\n"),
        '\r' => try blocking.writeAll(fd, "\\r"),
        '\t' => try blocking.writeAll(fd, "\\t"),
        else => {
            if (byte < 0x20) {
                var buf: [6]u8 = undefined;
                const escaped = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{byte});
                try blocking.writeAll(fd, escaped);
            } else {
                try blocking.writeAll(fd, (&[_]u8{byte})[0..]);
            }
        },
    };
    try blocking.writeAll(fd, "\"");
}

test "message escapes JSON string content" {
    const blocking = core_blocking.fromTest();
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    try writeDiagnostic(blocking, fds[1], "quote \" slash \\ newline\n tab\t control\x01");
    posix.close(fds[1]);

    var buf: [256]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings(
        "{\"event\":\"diagnostic\",\"message\":\"quote \\\" slash \\\\ newline\\n tab\\t control\\u0001\"}\n",
        buf[0..n],
    );
}

test "JSONL connection schema uses stable event names and fields" {
    const blocking = core_blocking.fromTest();
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    try writeConnectionEvent(blocking, fds[1], .{ .daemon_disconnected = .{} });
    try writeRetryScheduled(blocking, fds[1], 1700000000123);
    try writeRetryNow(blocking, fds[1]);
    try writeConnectionEvent(blocking, fds[1], .{ .unresponsive = .{} });
    try writeConnectionEvent(blocking, fds[1], .{ .ssh_stderr = .{ .data = "ssh: nope\n" } });
    try writeConnectionEvent(blocking, fds[1], .{ .daemon_connecting = .{} });
    try writeConnectionEvent(blocking, fds[1], .{ .daemon_connected = .{} });
    try writeFinalFailure(blocking, fds[1], "gave up");
    posix.close(fds[1]);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    while (true) {
        var buf: [256]u8 = undefined;
        const n = try posix.read(fds[0], &buf);
        if (n == 0) break;
        try output.appendSlice(std.testing.allocator, buf[0..n]);
    }

    try std.testing.expectEqualStrings(
        "{\"event\":\"daemon_disconnected\"}\n" ++
            "{\"event\":\"retry_scheduled\",\"retry_at_unix_ms\":1700000000123}\n" ++
            "{\"event\":\"retry_now\"}\n" ++
            "{\"event\":\"unresponsive\"}\n" ++
            "{\"event\":\"ssh_stderr\",\"message\":\"ssh: nope\\n\"}\n" ++
            "{\"event\":\"daemon_connecting\"}\n" ++
            "{\"event\":\"daemon_connected\"}\n" ++
            "{\"event\":\"final_failure\",\"message\":\"gave up\"}\n",
        output.items,
    );
}
