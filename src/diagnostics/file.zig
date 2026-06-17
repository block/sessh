const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_fds = @import("../core/fds.zig");
const io = @import("../core/io.zig");
const terminal = @import("../tty/terminal.zig");

pub const Handle = struct {
    output_fd: c.fd_t = -1,
    input_fd: c.fd_t = -1,
    mode_guard: terminal.TerminalModeGuard = undefined,
    mode_guard_enabled: bool = false,

    pub fn open(path: ?[]const u8) !Handle {
        const file_path = path orelse return .{};
        if (file_path.len == 0) return .{};

        const probe_fd = posix.open(file_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch {
            return try openOutputOnly(file_path);
        };
        if (c.isatty(probe_fd) == 0) {
            posix.close(probe_fd);
            return try openOutputOnly(file_path);
        }

        var handle = Handle{
            .output_fd = probe_fd,
            .input_fd = probe_fd,
        };
        core_fds.setNonBlocking(probe_fd) catch |err| {
            handle.deinit();
            return err;
        };
        // If the diagnostics file is a tty, it is also a reconnect control
        // channel. ProxyCommand stdin is the SSH byte stream, and terminal mode
        // may use an explicitly separate tty, so Ctrl-R must be read from this
        // fd instead of assuming fd 0.
        handle.mode_guard = terminal.TerminalModeGuard.enable(probe_fd) catch |err| {
            handle.deinit();
            return err;
        };
        handle.mode_guard_enabled = true;
        return handle;
    }

    pub fn deinit(self: *Handle) void {
        if (self.mode_guard_enabled) {
            self.mode_guard.restore();
            self.mode_guard_enabled = false;
        }
        if (self.output_fd >= 0) {
            posix.close(self.output_fd);
            self.output_fd = -1;
        }
        self.input_fd = -1;
    }
};

fn openOutputOnly(path: []const u8) !Handle {
    const fd = posix.open(path, .{
        .ACCMODE = .WRONLY,
        .CLOEXEC = true,
        .CREAT = true,
        .APPEND = true,
        .NONBLOCK = true,
    }, 0o600) catch |err| return err;
    return .{ .output_fd = fd };
}

pub fn validatePath(path: []const u8) !void {
    const probe_fd = posix.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0) catch {
        const output_fd = try posix.open(path, .{
            .ACCMODE = .WRONLY,
            .CLOEXEC = true,
            .CREAT = true,
            .APPEND = true,
        }, 0o600);
        posix.close(output_fd);
        return;
    };
    defer posix.close(probe_fd);
    if (c.isatty(probe_fd) != 0) return;

    const output_fd = try posix.open(path, .{
        .ACCMODE = .WRONLY,
        .CLOEXEC = true,
        .CREAT = true,
        .APPEND = true,
    }, 0o600);
    posix.close(output_fd);
}

test "opens regular file as output only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "diagnostics.log" });
    defer std.testing.allocator.free(path);

    var diagnostics = try Handle.open(path);
    defer diagnostics.deinit();

    try std.testing.expect(diagnostics.output_fd >= 0);
    try std.testing.expect(diagnostics.input_fd < 0);
    try io.writeAll(diagnostics.output_fd, "status\n");
    diagnostics.deinit();

    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "diagnostics.log", 64);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("status\n", contents);
}

test "reports uncreatable path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "missing-parent", "diagnostics.log" });
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.FileNotFound, Handle.open(path));
}

test "validation creates regular file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "validated-diagnostics.log" });
    defer std.testing.allocator.free(path);

    try validatePath(path);
    const file = try tmp.dir.openFile("validated-diagnostics.log", .{});
    file.close();
}

test "validation reports uncreatable path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "missing-parent", "diagnostics.log" });
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.FileNotFound, validatePath(path));
}
