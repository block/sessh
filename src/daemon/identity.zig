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
    return processStartTimeFromProc(allocator, pid) catch processStartTimeFromPs(allocator, pid);
}

fn processStartTimeFromProc(allocator: std.mem.Allocator, pid: u64) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "/proc/{}/stat", .{pid});
    defer allocator.free(path);

    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
    defer allocator.free(bytes);

    const after_comm_index = std.mem.lastIndexOf(u8, bytes, ") ") orelse return error.ProcessStartTimeUnavailable;
    const fields = bytes[after_comm_index + 2 ..];
    const start_time = try procStatField(fields, 22);
    return std.fmt.allocPrint(allocator, "procstat:{s}", .{start_time});
}

fn procStatField(fields_from_state: []const u8, field_number: usize) ![]const u8 {
    if (field_number < 3) return error.ProcessStartTimeUnavailable;
    var fields = std.mem.tokenizeAny(u8, fields_from_state, " \t\r\n");
    var current_field: usize = 3;
    while (fields.next()) |field| : (current_field += 1) {
        if (current_field == field_number) return field;
    }
    return error.ProcessStartTimeUnavailable;
}

fn processStartTimeFromPs(allocator: std.mem.Allocator, pid: u64) ![]u8 {
    const pid_arg = try std.fmt.allocPrint(allocator, "{}", .{pid});
    defer allocator.free(pid_arg);

    // BLOCKING_WAIT: this is the portability fallback when `/proc` cannot
    // provide a stable process start token. Cleanup records compare the opaque
    // string exactly; it does not need to match another machine's clock format.
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
    return std.fmt.allocPrint(allocator, "ps-lstart:{s}", .{trimmed});
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

test "procStatField extracts Linux process start time field" {
    const fields =
        "S 0 121 121 0 -1 4194560 141 335 0 0 0 0 0 0 20 0 1 0 110179745 1777664 299";
    try std.testing.expectEqualStrings("110179745", try procStatField(fields, 22));
}
