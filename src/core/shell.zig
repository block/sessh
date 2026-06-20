const std = @import("std");

fn joinArgs(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
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

test "joinArgs produces shell-split ssh options" {
    const joined = try joinArgs(std.testing.allocator, &.{ "-F", "ssh config", "alpha ' beta", "" });
    defer std.testing.allocator.free(joined);

    try std.testing.expectEqualStrings("'-F' 'ssh config' 'alpha '\\'' beta' ''", joined);
}
