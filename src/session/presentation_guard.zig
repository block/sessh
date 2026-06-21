// RAII-style restoration for visible terminal presentation. The guard records
// the terminal modes sessh changes and restores them even when a session exits
// through an error path.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const core_blocking = @import("../core/blocking.zig");
const io = @import("../core/io.zig");
const app_allocator = @import("../core/app_allocator.zig");
const renderer_mod = @import("renderer.zig");
const terminal = @import("../tty/terminal.zig");

const Capabilities = renderer_mod.Capabilities;
const Renderer = renderer_mod.Renderer;
const TerminalFds = terminal.TerminalFds;

pub const Guard = struct {
    renderer: Renderer,
    cleanup_title: ?[]const u8 = null,
    initial_kitty_keyboard_flags: u5 = 0,
    alternate_screen_active: bool = false,
    active: bool = true,

    pub fn init(blocking: core_blocking.Blocking, fd: c.fd_t) Guard {
        return initWithTerminalFds(blocking, .{ .output = fd });
    }

    pub fn initWithTerminalFds(blocking: core_blocking.Blocking, fds: TerminalFds) Guard {
        return initWithRenderer(Renderer.init(fds.output), null, initialKittyKeyboardFlags(blocking, fds));
    }

    pub fn initWithCleanupTitle(blocking: core_blocking.Blocking, fd: c.fd_t, cleanup_title: []const u8) Guard {
        return initWithTerminalFdsAndCleanupTitle(blocking, .{ .output = fd }, cleanup_title);
    }

    pub fn initWithTerminalFdsAndCleanupTitle(blocking: core_blocking.Blocking, fds: TerminalFds, cleanup_title: []const u8) Guard {
        return initWithRenderer(Renderer.init(fds.output), cleanup_title, initialKittyKeyboardFlags(blocking, fds));
    }

    pub fn initWithInitialKittyKeyboardFlags(fd: c.fd_t, initial_kitty_keyboard_flags: u5) Guard {
        return initWithRenderer(Renderer.init(fd), null, initial_kitty_keyboard_flags);
    }

    pub fn initWithCleanupTitleAndInitialKittyKeyboardFlags(
        fd: c.fd_t,
        cleanup_title: []const u8,
        initial_kitty_keyboard_flags: u5,
    ) Guard {
        return initWithRenderer(Renderer.init(fd), cleanup_title, initial_kitty_keyboard_flags);
    }

    pub fn withCapabilities(blocking: core_blocking.Blocking, fd: c.fd_t, caps: Capabilities) Guard {
        return withTerminalFdsAndCapabilities(blocking, .{ .output = fd }, caps);
    }

    pub fn withTerminalFdsAndCapabilities(blocking: core_blocking.Blocking, fds: TerminalFds, caps: Capabilities) Guard {
        return initWithRenderer(Renderer.withCapabilities(fds.output, caps), null, initialKittyKeyboardFlags(blocking, fds));
    }

    pub fn withCapabilitiesAndInitialKittyKeyboardFlags(
        fd: c.fd_t,
        caps: Capabilities,
        initial_kitty_keyboard_flags: u5,
    ) Guard {
        return initWithRenderer(Renderer.withCapabilities(fd, caps), null, initial_kitty_keyboard_flags);
    }

    pub fn withCapabilitiesAndCleanupTitle(blocking: core_blocking.Blocking, fd: c.fd_t, caps: Capabilities, cleanup_title: []const u8) Guard {
        return withTerminalFdsAndCapabilitiesAndCleanupTitle(blocking, .{ .output = fd }, caps, cleanup_title);
    }

    pub fn withTerminalFdsAndCapabilitiesAndCleanupTitle(blocking: core_blocking.Blocking, fds: TerminalFds, caps: Capabilities, cleanup_title: []const u8) Guard {
        return initWithRenderer(Renderer.withCapabilities(fds.output, caps), cleanup_title, initialKittyKeyboardFlags(blocking, fds));
    }

    pub fn enterAlternateScreen(self: *Guard) !void {
        if (self.alternate_screen_active) return;
        try self.renderer.enterAlternateScreen();
        self.alternate_screen_active = true;
    }

    pub fn leaveAlternateScreen(self: *Guard) !void {
        if (!self.alternate_screen_active) return;
        try self.renderer.leaveAlternateScreen();
        self.alternate_screen_active = false;
    }

    pub fn restore(self: *Guard) void {
        if (!self.active) return;
        self.leaveAlternateScreen() catch {};
        self.renderer.restorePresentation(self.initial_kitty_keyboard_flags) catch {};
        if (self.cleanup_title) |title| self.renderer.setTitle(title) catch {};
        self.active = false;
    }
};

fn initWithRenderer(renderer: Renderer, cleanup_title: ?[]const u8, initial_kitty_keyboard_flags: u5) Guard {
    return .{
        .renderer = renderer,
        .cleanup_title = cleanup_title,
        .initial_kitty_keyboard_flags = initial_kitty_keyboard_flags,
    };
}

pub fn restoreVisibleClientEndBytes(visible_client_end_restore: ?*std.ArrayList(u8)) void {
    restoreVisibleClientEndBytesToFd(posix.STDOUT_FILENO, visible_client_end_restore);
}

fn restoreVisibleClientEndBytesToFd(fd: c.fd_t, visible_client_end_restore: ?*std.ArrayList(u8)) void {
    const bytes = visible_client_end_restore orelse return;
    defer bytes.clearRetainingCapacity();
    if (c.isatty(fd) == 0) return;
    io.writeAll(fd, bytes.items) catch {};
}

pub fn restoreLocal(initial_kitty_keyboard_flags: u5) void {
    if (c.isatty(posix.STDOUT_FILENO) == 0) return;
    const renderer = Renderer.init(posix.STDOUT_FILENO);
    renderer.restorePresentation(initial_kitty_keyboard_flags) catch {};
    const cleanup_title = std.process.getCwdAlloc(app_allocator.allocator()) catch null;
    if (cleanup_title) |title| {
        defer app_allocator.allocator().free(title);
        renderer.setTitle(title) catch {};
    }
}

fn initialKittyKeyboardFlags(blocking: core_blocking.Blocking, fds: TerminalFds) u5 {
    if (c.isatty(fds.output) == 0) return 0;
    return terminal.queryInitialKittyKeyboardFlags(blocking, fds);
}

test "final visible-client exit restore skips non-tty output and clears saved cleanup bytes" {
    const output = try posix.pipe();
    defer posix.close(output[0]);
    defer posix.close(output[1]);

    var visible_client_end_restore = std.ArrayList(u8).empty;
    defer visible_client_end_restore.deinit(std.testing.allocator);
    try visible_client_end_restore.appendSlice(std.testing.allocator, "restore-primary");

    restoreVisibleClientEndBytesToFd(output[1], &visible_client_end_restore);

    var pollfds = [_]posix.pollfd{.{
        .fd = output[0],
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try posix.poll(&pollfds, 0));
    try std.testing.expectEqual(@as(usize, 0), visible_client_end_restore.items.len);
}

test "presentation guard restores cleanup title" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var guard = Guard.withTerminalFdsAndCapabilitiesAndCleanupTitle(
        core_blocking.fromTest(),
        .{ .input = fds[0], .output = fds[1] },
        Capabilities.xterm_compatible,
        "/Users/tomm/Development/sessh",
    );
    guard.restore();

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b]2;/Users/tomm/Development/sessh\x1b\\") != null);
}

test "presentation guard restores captured kitty keyboard flags" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var guard = Guard.withCapabilitiesAndInitialKittyKeyboardFlags(
        fds[1],
        Capabilities.xterm_compatible,
        3,
    );
    guard.restore();

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[=3u") != null);
}

test "presentation guard leaves alternate screen only when it entered it" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var guard = Guard.withTerminalFdsAndCapabilities(
        core_blocking.fromTest(),
        .{ .input = fds[0], .output = fds[1] },
        Capabilities.xterm_compatible,
    );
    try guard.enterAlternateScreen();
    guard.restore();

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1049h") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1049l") != null);
}

test "presentation guard does not leave alternate screen when it did not enter it" {
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var guard = Guard.withCapabilities(core_blocking.fromTest(), fds[1], Capabilities.xterm_compatible);
    guard.restore();

    var buf: [512]u8 = undefined;
    const len = try posix.read(fds[0], &buf);
    const bytes = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1049l") == null);
}
