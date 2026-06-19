const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_fds = @import("../core/fds.zig");
const frame = @import("frame.zig");

pub fn setNonBlockingFdForTest(fd: c.fd_t) !void {
    try core_fds.setNonBlocking(fd);
}

pub fn closePipeForTest(pipe: [2]c.fd_t) void {
    _ = c.close(pipe[0]);
    _ = c.close(pipe[1]);
}

pub fn socketPairForTest() ![2]c.fd_t {
    var fds: [2]c.fd_t = undefined;
    if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &fds) != 0) return error.SocketPairFailed;
    return fds;
}

pub fn drainPipeForTest(allocator: std.mem.Allocator, fd: c.fd_t, actual: *std.ArrayList(u8)) !void {
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buffer, buffer.len);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => return,
            .INTR => continue,
            else => return error.ReadFailed,
        };
        if (n == 0) return;
        try actual.appendSlice(allocator, buffer[0..@intCast(n)]);
    }
}

pub fn readAvailableForTest(allocator: std.mem.Allocator, fd: c.fd_t, out: *std.ArrayList(u8)) !void {
    var buf: [128]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => return err,
        };
        if (n == 0) return;
        try out.appendSlice(allocator, buf[0..n]);
    }
}

pub fn rawFrameForTest(allocator: std.mem.Allocator, frame_header_len: usize, payload: []const u8) ![]u8 {
    const frame_bytes = try allocator.alloc(u8, frame_header_len + payload.len);
    const len: u32 = @intCast(payload.len);
    frame_bytes[0] = @intCast((len >> 24) & 0xff);
    frame_bytes[1] = @intCast((len >> 16) & 0xff);
    frame_bytes[2] = @intCast((len >> 8) & 0xff);
    frame_bytes[3] = @intCast(len & 0xff);
    @memcpy(frame_bytes[frame_header_len..], payload);
    return frame_bytes;
}

pub fn readFrameForTest(allocator: std.mem.Allocator, fd: c.fd_t) !frame.OwnedFrame {
    var reader = frame.FrameReader.init(allocator);
    defer reader.deinit();
    while (true) {
        switch (try reader.readBlocking(fd)) {
            .blocked => return error.WouldBlock,
            .progress => continue,
            .frame => |owned_frame| return owned_frame,
            .eof => return error.EndOfStream,
            .truncated_frame => return error.TruncatedFrame,
        }
    }
}
