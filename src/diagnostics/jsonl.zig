const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");
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

pub fn writeEvent(fd: c.fd_t, event: Event) !void {
    try io.writeAll(fd, "{\"event\":");
    try writeString(fd, event.label());
    try io.writeAll(fd, "}\n");
}

pub fn writeMessage(fd: c.fd_t, event: Event, message: []const u8) !void {
    try io.writeAll(fd, "{\"event\":");
    try writeString(fd, event.label());
    try io.writeAll(fd, ",\"message\":");
    try writeString(fd, message);
    try io.writeAll(fd, "}\n");
}

pub fn writeRetryScheduled(fd: c.fd_t, retry_at_unix_ms: u64) !void {
    var buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "{{\"event\":\"retry_scheduled\",\"retry_at_unix_ms\":{}}}\n",
        .{retry_at_unix_ms},
    );
    try io.writeAll(fd, line);
}

pub fn writeRetryNow(fd: c.fd_t) !void {
    try writeEvent(fd, .retry_now);
}

pub fn writeConnectionEvent(fd: c.fd_t, event: pb.ConnectionEvent.event_union) !void {
    switch (event) {
        .binary_bootstrapping => try writeEvent(fd, .binary_bootstrapping),
        .daemon_connecting => try writeEvent(fd, .daemon_connecting),
        .daemon_connected => try writeEvent(fd, .daemon_connected),
        .daemon_disconnected => try writeEvent(fd, .daemon_disconnected),
        .unresponsive => try writeEvent(fd, .unresponsive),
        .ssh_connecting => try writeEvent(fd, .ssh_connecting),
        .ssh_connected => try writeEvent(fd, .ssh_connected),
        .ssh_stderr => |stderr| try writeMessage(fd, .ssh_stderr, stderr.data),
    }
}

pub fn writeDiagnostic(fd: c.fd_t, message: []const u8) !void {
    try writeMessage(fd, .diagnostic, message);
}

pub fn writeStatus(fd: c.fd_t, message: []const u8) !void {
    try writeMessage(fd, .status, message);
}

pub fn writeFinalFailure(fd: c.fd_t, message: []const u8) !void {
    try writeMessage(fd, .final_failure, message);
}

pub fn writeString(fd: c.fd_t, value: []const u8) !void {
    try io.writeAll(fd, "\"");
    for (value) |byte| switch (byte) {
        '"' => try io.writeAll(fd, "\\\""),
        '\\' => try io.writeAll(fd, "\\\\"),
        '\n' => try io.writeAll(fd, "\\n"),
        '\r' => try io.writeAll(fd, "\\r"),
        '\t' => try io.writeAll(fd, "\\t"),
        else => {
            if (byte < 0x20) {
                var buf: [6]u8 = undefined;
                const escaped = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{byte});
                try io.writeAll(fd, escaped);
            } else {
                try io.writeAll(fd, (&[_]u8{byte})[0..]);
            }
        },
    };
    try io.writeAll(fd, "\"");
}

test "message escapes JSON string content" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    try writeDiagnostic(fds[1], "quote \" slash \\ newline\n tab\t control\x01");
    posix.close(fds[1]);

    var buf: [256]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings(
        "{\"event\":\"diagnostic\",\"message\":\"quote \\\" slash \\\\ newline\\n tab\\t control\\u0001\"}\n",
        buf[0..n],
    );
}

test "JSONL connection schema uses stable event names and fields" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);

    try writeConnectionEvent(fds[1], .{ .daemon_disconnected = .{} });
    try writeRetryScheduled(fds[1], 1700000000123);
    try writeRetryNow(fds[1]);
    try writeConnectionEvent(fds[1], .{ .unresponsive = .{} });
    try writeConnectionEvent(fds[1], .{ .ssh_stderr = .{ .data = "ssh: nope\n" } });
    try writeConnectionEvent(fds[1], .{ .daemon_connecting = .{} });
    try writeConnectionEvent(fds[1], .{ .daemon_connected = .{} });
    try writeFinalFailure(fds[1], "gave up");
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
