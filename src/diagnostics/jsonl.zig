const std = @import("std");
const c = std.c;
const posix = std.posix;

const io = @import("../core/io.zig");

pub fn writeEvent(fd: c.fd_t, event: []const u8) !void {
    try io.writeAll(fd, "{\"event\":");
    try writeString(fd, event);
    try io.writeAll(fd, "}\n");
}

pub fn writeMessage(fd: c.fd_t, event: []const u8, message: []const u8) !void {
    try io.writeAll(fd, "{\"event\":");
    try writeString(fd, event);
    try io.writeAll(fd, ",\"message\":");
    try writeString(fd, message);
    try io.writeAll(fd, "}\n");
}

pub fn writeRetry(fd: c.fd_t, retry_at_unix_ms: u64) !void {
    var buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "{{\"event\":\"retry\",\"retry_at_unix_ms\":{}}}\n",
        .{retry_at_unix_ms},
    );
    try io.writeAll(fd, line);
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

    try writeMessage(fds[1], "diagnostic", "quote \" slash \\ newline\n tab\t control\x01");
    posix.close(fds[1]);

    var buf: [256]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings(
        "{\"event\":\"diagnostic\",\"message\":\"quote \\\" slash \\\\ newline\\n tab\\t control\\u0001\"}\n",
        buf[0..n],
    );
}
