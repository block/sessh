const std = @import("std");
const c = std.c;

const io_helpers = @import("io.zig");

pub fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    for (args, 0..) |arg, i| {
        if (i > 0) try out.append(allocator, ' ');
        try appendQuotedArg(allocator, &out, arg);
    }

    return out.toOwnedSlice(allocator);
}

fn appendQuotedArg(allocator: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    try out.append(allocator, '\'');
    for (arg) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
}

pub fn writeArg(fd: c.fd_t, arg: []const u8) !void {
    if (arg.len == 0) {
        try io_helpers.writeAll(fd, "''");
        return;
    }
    if (isPlainArg(arg)) {
        try io_helpers.writeAll(fd, arg);
        return;
    }
    try io_helpers.writeAll(fd, "'");
    for (arg) |byte| {
        if (byte == '\'') {
            try io_helpers.writeAll(fd, "'\\''");
        } else {
            var one = [_]u8{byte};
            try io_helpers.writeAll(fd, &one);
        }
    }
    try io_helpers.writeAll(fd, "'");
}

fn isPlainArg(arg: []const u8) bool {
    for (arg) |byte| {
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '-', '.', '/', ':', '@', '%', '+', '=' => {},
            else => return false,
        }
    }
    return true;
}

test "joinArgs produces shell-split ssh options" {
    const joined = try joinArgs(std.testing.allocator, &.{ "-F", "ssh config", "alpha ' beta", "" });
    defer std.testing.allocator.free(joined);

    try std.testing.expectEqualStrings("'-F' 'ssh config' 'alpha '\\'' beta' ''", joined);
}
