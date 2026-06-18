const std = @import("std");
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const client_log = @import("../core/client_log.zig");
const io = @import("../core/io.zig");
const protocol = @import("../protocol/mod.zig");

const hpb = protocol.hpb;

pub const Payload = struct {
    code: []const u8,
    message: []const u8,
    hint: []const u8,
};

pub fn printPayload(payload: []const u8) !void {
    try printParsed(try parse(payload));
}

pub fn parse(payload: []const u8) !Payload {
    var decoded = try protocol.decodePayload(hpb.Error, app_allocator.allocator(), payload);
    defer decoded.deinit(app_allocator.allocator());
    return .{
        .code = try app_allocator.allocator().dupe(u8, decoded.code),
        .message = try app_allocator.allocator().dupe(u8, decoded.message),
        .hint = try app_allocator.allocator().dupe(u8, decoded.hint orelse ""),
    };
}

pub fn transportExitCode(code: []const u8) ?u8 {
    const prefix = "SSH_TRANSPORT_EXITED_";
    if (!std.mem.startsWith(u8, code, prefix)) return null;
    const parsed = std.fmt.parseUnsigned(u16, code[prefix.len..], 10) catch return null;
    return @intCast(@min(parsed, 255));
}

pub fn printParsed(parsed: Payload) !void {
    defer free(parsed);
    client_log.flush(posix.STDERR_FILENO);
    try printBorrowed(parsed);
}

fn printBorrowed(parsed: Payload) !void {
    try io.writeAll(posix.STDERR_FILENO, "ERROR ");
    try io.writeAll(posix.STDERR_FILENO, parsed.message);
    try io.writeAll(posix.STDERR_FILENO, "\n");
    if (parsed.hint.len > 0) {
        try io.writeAll(posix.STDERR_FILENO, parsed.hint);
        try io.writeAll(posix.STDERR_FILENO, "\n");
    }
}

pub fn free(parsed: Payload) void {
    app_allocator.allocator().free(parsed.code);
    app_allocator.allocator().free(parsed.message);
    app_allocator.allocator().free(parsed.hint);
}
