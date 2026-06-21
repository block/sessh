const std = @import("std");
const builtin = @import("builtin");
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
    return switch (builtin.os.tag) {
        .linux => processStartTimeFromProc(allocator, pid),
        .macos => processStartTimeFromDarwinProc(allocator, pid),
        else => error.ProcessStartTimeUnavailable,
    };
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

pub fn processIdentityMatches(allocator: std.mem.Allocator, pid: u64, expected_start_time: []const u8) bool {
    const actual = processStartTime(allocator, pid) catch return false;
    defer allocator.free(actual);
    return std.mem.eql(u8, actual, expected_start_time);
}

const darwin_proc = if (builtin.os.tag == .macos) struct {
    const PROC_PIDTBSDINFO = 3;
    const MAXCOMLEN = 16;

    const ProcBsdInfo = extern struct {
        pbi_flags: u32,
        pbi_status: u32,
        pbi_xstatus: u32,
        pbi_pid: u32,
        pbi_ppid: u32,
        pbi_uid: u32,
        pbi_gid: u32,
        pbi_ruid: u32,
        pbi_rgid: u32,
        pbi_svuid: u32,
        pbi_svgid: u32,
        rfu_1: u32,
        pbi_comm: [MAXCOMLEN]u8,
        pbi_name: [2 * MAXCOMLEN]u8,
        pbi_nfiles: u32,
        pbi_pgid: u32,
        pbi_pjobc: u32,
        e_tdev: u32,
        e_tpgid: u32,
        pbi_nice: i32,
        pbi_start_tvsec: u64,
        pbi_start_tvusec: u64,
    };

    extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
} else struct {};

fn processStartTimeFromDarwinProc(allocator: std.mem.Allocator, pid: u64) ![]u8 {
    if (builtin.os.tag != .macos) return error.ProcessStartTimeUnavailable;
    if (pid == 0 or pid > @as(u64, @intCast(std.math.maxInt(c_int)))) return error.ProcessStartTimeUnavailable;

    var info: darwin_proc.ProcBsdInfo = undefined;
    const expected_size: c_int = @intCast(@sizeOf(darwin_proc.ProcBsdInfo));
    const actual_size = darwin_proc.proc_pidinfo(
        @intCast(pid),
        darwin_proc.PROC_PIDTBSDINFO,
        0,
        &info,
        expected_size,
    );
    if (actual_size != expected_size) return error.ProcessStartTimeUnavailable;
    if (info.pbi_pid != pid) return error.ProcessStartTimeUnavailable;
    // The token is intentionally opaque. Cleanup only compares exact strings,
    // so we do not need to normalize it across platforms.
    return std.fmt.allocPrint(allocator, "darwin-proc:{}:{}", .{ info.pbi_start_tvsec, info.pbi_start_tvusec });
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
