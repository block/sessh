const std = @import("std");
const c = std.c;

pub const DaemonIdentity = struct {
    pid: u64,
    start_time: []const u8,
    socket_path: []const u8,
};

pub fn current(allocator: std.mem.Allocator, socket_path: []const u8) !DaemonIdentity {
    const pid: u64 = @intCast(c.getpid());
    return .{
        .pid = pid,
        .start_time = try processStartTime(allocator, pid),
        .socket_path = socket_path,
    };
}

pub fn processStartTime(allocator: std.mem.Allocator, pid: u64) ![]u8 {
    const pid_arg = try std.fmt.allocPrint(allocator, "{}", .{pid});
    defer allocator.free(pid_arg);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "ps", "-p", pid_arg, "-o", "lstart=" },
        .max_output_bytes = 4096,
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.ProcessStartTimeUnavailable,
        else => return error.ProcessStartTimeUnavailable,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return error.ProcessStartTimeUnavailable;
    return allocator.dupe(u8, trimmed);
}

pub fn processIdentityMatches(allocator: std.mem.Allocator, pid: u64, expected_start_time: []const u8) bool {
    const actual = processStartTime(allocator, pid) catch return false;
    defer allocator.free(actual);
    return std.mem.eql(u8, actual, expected_start_time);
}

test "processStartTime returns an opaque non-empty string for current process" {
    const start_time = try processStartTime(std.testing.allocator, @intCast(c.getpid()));
    defer std.testing.allocator.free(start_time);
    try std.testing.expect(start_time.len > 0);
}
