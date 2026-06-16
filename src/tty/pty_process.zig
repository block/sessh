const std = @import("std");
const c = std.c;
const posix = std.posix;

const terminal = @import("terminal.zig");
const tty_settings = @import("settings.zig");

extern "c" fn forkpty(amaster: *c_int, name: ?[*:0]u8, termp: ?*anyopaque, winp: ?*c.winsize) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn ttyname(fd: c_int) ?[*:0]u8;

pub const SpawnOptions = struct {
    rows: u16,
    cols: u16,
    shell: ?[]const u8 = null,
    command_argv: []const []const u8 = &.{},
    shell_command: ?[]const u8 = null,
    environment: []const EnvironmentEntry = &.{},
    session_guid: ?[]const u8 = null,
    add_sessh_path_to_env: bool = false,
    tty_settings: ?tty_settings.Settings = null,
};

pub const EnvironmentEntry = struct {
    name: [:0]const u8,
    value: [:0]const u8,
};

pub const Child = struct {
    pid: c.pid_t,
    master_fd: c.fd_t,

    pub fn closeMaster(self: *Child) void {
        if (self.master_fd >= 0) {
            posix.close(self.master_fd);
            self.master_fd = -1;
        }
    }

    pub fn wait(self: *Child) std.process.Child.Term {
        if (self.pid == 0) return .{ .Unknown = 0 };
        // BLOCKING_WAIT: process cleanup after the PTY master has been closed
        // and SIGTERM has been sent. This is not daemon event-loop work.
        const result = posix.waitpid(self.pid, 0);
        self.pid = 0;
        return waitStatusToTerm(result.status);
    }

    pub fn terminate(self: *Child) void {
        self.closeMaster();
        if (self.pid != 0) {
            posix.kill(self.pid, posix.SIG.TERM) catch {};
            _ = self.wait();
        }
    }
};

// All PTY users should go through these master-read helpers instead of calling
// read(2) directly. PTY EOF is not identical to pipe EOF on every platform:
// Linux reports the closed slave side as EIO on the master. Keeping that rule
// here prevents the stream and remote terminal processs from growing separate PTY lore.
pub const MasterRead = union(enum) {
    bytes: []const u8,
    would_block,
    eof,
};

pub const DrainLimits = struct {
    max_reads: usize = std.math.maxInt(usize),
    max_bytes: usize = std.math.maxInt(usize),
};

pub const DrainResult = struct {
    read_count: usize = 0,
    byte_count: usize = 0,
    eof: bool = false,
    limited: bool = false,
};

pub fn spawn(allocator: std.mem.Allocator, options: SpawnOptions) !Child {
    if (options.command_argv.len > 0 and options.shell_command != null) return error.InvalidSessionCommand;

    const shell_path = options.shell orelse defaultShellPath();
    const shell_z = try allocator.dupeZ(u8, shell_path);
    defer allocator.free(shell_z);
    const shell_argv0 = try loginShellArg0(allocator, shell_path);
    defer allocator.free(shell_argv0);

    var prepared_command: ?PreparedCommand = if (options.shell_command) |command|
        try prepareShellCommand(allocator, shell_path, command)
    else if (options.command_argv.len > 0)
        try prepareCommandArgv(allocator, options.command_argv)
    else
        null;
    defer if (prepared_command) |*command| command.deinit(allocator);

    const session_guid_z: ?[:0]u8 = if (options.session_guid) |guid| try allocator.dupeZ(u8, guid) else null;
    defer if (session_guid_z) |guid| allocator.free(guid);

    const sessh_path_z: ?[:0]u8 = if (options.add_sessh_path_to_env) try sesshPathForEnvironment(allocator) else null;
    defer if (sessh_path_z) |path| allocator.free(path);
    const path_z: ?[:0]u8 = if (sessh_path_z) |sessh_path| try pathWithSesshPathForEnvironment(allocator, sessh_path) else null;
    defer if (path_z) |path| allocator.free(path);
    const term_z: ?[:0]u8 = if (options.tty_settings) |settings|
        if (settings.term) |term| try allocator.dupeZ(u8, term) else null
    else
        null;
    defer if (term_z) |term| allocator.free(term);

    var master: c_int = -1;
    var size = c.winsize{ .row = options.rows, .col = options.cols, .xpixel = 0, .ypixel = 0 };
    const pid = forkpty(&master, null, null, &size);
    if (pid < 0) return error.ForkPtyFailed;
    if (pid == 0) {
        terminal.setSigpipe(posix.SIG.DFL);
        for (options.environment) |entry| {
            _ = setenv(entry.name.ptr, entry.value.ptr, 1);
        }
        if (term_z) |term| {
            _ = setenv("TERM", term.ptr, 1);
        } else {
            // No TERM means this PTY is backed by sessh's terminal emulator,
            // not the caller's outer terminal.
            _ = setenv("TERM", "xterm-256color", 1);
        }
        _ = setenv("SHELL", shell_z.ptr, 1);
        if (ttyname(posix.STDIN_FILENO)) |path| {
            _ = setenv("SSH_TTY", path, 1);
        }
        if (session_guid_z) |guid| _ = setenv("SESSH_GUID", guid.ptr, 1);
        if (sessh_path_z) |path| _ = setenv("SESSH_PATH", path.ptr, 1);
        if (path_z) |path| _ = setenv("PATH", path.ptr, 1);
        if (options.tty_settings) |settings| tty_settings.applyToFd(settings, posix.STDIN_FILENO) catch {};
        if (prepared_command) |command| {
            posix.execvpeZ(command.argv[0].?, command.argv.ptr, @ptrCast(c.environ)) catch {};
        } else {
            const dash_i: [*:0]const u8 = "-i";
            var child_argv = [_:null]?[*:0]const u8{ shell_argv0.ptr, dash_i };
            _ = c.execve(shell_z.ptr, &child_argv, @ptrCast(c.environ));
        }
        std.process.exit(127);
    }
    return .{ .pid = pid, .master_fd = master };
}

pub fn readMaster(fd: c.fd_t, buf: []u8) !MasterRead {
    return readMasterInner(fd, buf);
}

pub fn readMasterNonBlocking(fd: c.fd_t, buf: []u8) !MasterRead {
    const original_flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (original_flags < 0) return error.PtyMasterReadFailed;
    const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
    const changed_flags = (original_flags & nonblocking_flag) == 0;
    if (changed_flags and c.fcntl(fd, c.F.SETFL, original_flags | nonblocking_flag) < 0) {
        return error.PtyMasterReadFailed;
    }
    defer {
        if (changed_flags) _ = c.fcntl(fd, c.F.SETFL, original_flags);
    }
    return readMasterInner(fd, buf);
}

fn readMasterInner(fd: c.fd_t, buf: []u8) !MasterRead {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n > 0) return .{ .bytes = buf[0..@intCast(n)] };
        if (n == 0) return .eof;
        switch (posix.errno(n)) {
            .AGAIN => return .would_block,
            .INTR => continue,
            // On Linux, a PTY master reports EOF as EIO after the slave side
            // closes. Other fd types should not use this helper.
            .IO => return .eof,
            else => return error.PtyMasterReadFailed,
        }
    }
}

pub fn drainMasterNonBlocking(
    fd: c.fd_t,
    context: anytype,
    on_bytes: anytype,
    limits: DrainLimits,
) !DrainResult {
    var result = DrainResult{};
    while (result.read_count < limits.max_reads and result.byte_count < limits.max_bytes) {
        var buf: [4096]u8 = undefined;
        switch (try readMasterNonBlocking(fd, &buf)) {
            .bytes => |bytes| {
                result.read_count += 1;
                result.byte_count += bytes.len;
                try on_bytes(context, bytes);
            },
            .would_block => return result,
            .eof => {
                result.eof = true;
                return result;
            },
        }
    }
    result.limited = true;
    return result;
}

pub fn waitStatusToTerm(status: u32) std.process.Child.Term {
    return if (posix.W.IFEXITED(status))
        .{ .Exited = posix.W.EXITSTATUS(status) }
    else if (posix.W.IFSIGNALED(status))
        .{ .Signal = posix.W.TERMSIG(status) }
    else if (posix.W.IFSTOPPED(status))
        .{ .Stopped = posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

const PreparedCommand = struct {
    argv: [:null]?[*:0]const u8,
    owned_args: [][:0]u8,

    fn deinit(self: *PreparedCommand, allocator: std.mem.Allocator) void {
        for (self.owned_args) |arg| allocator.free(arg);
        allocator.free(self.owned_args);
        allocator.free(self.argv);
        self.* = undefined;
    }
};

fn prepareCommandArgv(allocator: std.mem.Allocator, command_argv: []const []const u8) !PreparedCommand {
    if (command_argv.len == 0) return error.InvalidCommandArgv;
    return prepareCommandArgvInner(allocator, command_argv, false);
}

fn prepareCommandArgvInner(allocator: std.mem.Allocator, command_argv: []const []const u8, allow_empty_args: bool) !PreparedCommand {
    var owned_args = try allocator.alloc([:0]u8, command_argv.len);
    var initialized: usize = 0;
    errdefer {
        for (owned_args[0..initialized]) |arg| allocator.free(arg);
        allocator.free(owned_args);
    }

    var argv = try allocator.allocSentinel(?[*:0]const u8, command_argv.len, null);
    errdefer allocator.free(argv);

    for (command_argv, 0..) |arg, i| {
        if (!allow_empty_args and arg.len == 0) return error.InvalidCommandArgv;
        owned_args[i] = try allocator.dupeZ(u8, arg);
        initialized += 1;
        argv[i] = owned_args[i].ptr;
    }
    return .{ .argv = argv, .owned_args = owned_args };
}

fn prepareShellCommand(allocator: std.mem.Allocator, shell_path: []const u8, shell_command: []const u8) !PreparedCommand {
    const shell_dash_c = [_][]const u8{ shell_path, "-c", shell_command };
    return prepareCommandArgvInner(allocator, &shell_dash_c, true);
}

fn loginShellArg0(allocator: std.mem.Allocator, shell_path: []const u8) ![:0]u8 {
    const base = std.fs.path.basename(shell_path);
    const name = if (base.len == 0) "sh" else base;
    var arg = try allocator.allocSentinel(u8, name.len + 1, 0);
    arg[0] = '-';
    @memcpy(arg[1 .. 1 + name.len], name);
    return arg;
}

pub fn defaultShellPath() []const u8 {
    const env_shell = if (c.getenv("SHELL")) |shell_z| std.mem.span(shell_z) else null;
    const passwd_shell = if (c.getpwuid(c.getuid())) |passwd|
        if (passwd.shell) |shell_z| std.mem.span(shell_z) else null
    else
        null;
    return chooseDefaultShell(env_shell, passwd_shell);
}

fn chooseDefaultShell(env_shell: ?[]const u8, passwd_shell: ?[]const u8) []const u8 {
    if (env_shell) |shell| {
        if (shell.len > 0) return shell;
    }
    if (passwd_shell) |shell| {
        if (shell.len > 0) return shell;
    }
    return "/bin/sh";
}

fn sesshPathForEnvironment(allocator: std.mem.Allocator) ![:0]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidExecutablePath;
    return allocator.dupeZ(u8, exe_dir);
}

fn pathWithSesshPathForEnvironment(allocator: std.mem.Allocator, sessh_path: []const u8) ![:0]u8 {
    if (c.getenv("PATH")) |path_z| {
        const path = std.mem.span(path_z);
        if (path.len > 0) {
            const combined = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ path, sessh_path });
            defer allocator.free(combined);
            return allocator.dupeZ(u8, combined);
        }
    }
    return allocator.dupeZ(u8, sessh_path);
}

test "prepare shell command preserves an explicit empty command" {
    var command = try prepareShellCommand(std.testing.allocator, "/bin/sh", "");
    defer command.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(command.argv[0].?));
    try std.testing.expectEqualStrings("-c", std.mem.span(command.argv[1].?));
    try std.testing.expectEqualStrings("", std.mem.span(command.argv[2].?));
}

test "login shell argv0 uses dash-prefixed basename" {
    const arg = try loginShellArg0(std.testing.allocator, "/usr/local/bin/zsh");
    defer std.testing.allocator.free(arg);
    try std.testing.expectEqualStrings("-zsh", arg);
}

test "default shell prefers process environment then passwd then sh" {
    try std.testing.expectEqualStrings("/bin/zsh", chooseDefaultShell("/bin/zsh", "/bin/bash"));
    try std.testing.expectEqualStrings("/bin/bash", chooseDefaultShell("", "/bin/bash"));
    try std.testing.expectEqualStrings("/bin/sh", chooseDefaultShell(null, ""));
}

const DrainTestContext = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *DrainTestContext) void {
        self.bytes.deinit(self.allocator);
    }
};

fn appendDrainTestBytes(context: *DrainTestContext, bytes: []const u8) !void {
    try context.bytes.appendSlice(context.allocator, bytes);
}

test "drain master reads available PTY output while child is still alive" {
    var child = try spawn(std.testing.allocator, .{
        .rows = 24,
        .cols = 80,
        .shell = "/bin/sh",
        .shell_command = "printf PTY_MASTER_DRAIN; read ignored",
    });
    defer child.terminate();

    var pollfds = [_]posix.pollfd{.{
        .fd = child.master_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try posix.poll(&pollfds, 1_000);
    try std.testing.expect(ready == 1);
    try std.testing.expect((pollfds[0].revents & posix.POLL.IN) != 0);

    var context = DrainTestContext{ .allocator = std.testing.allocator };
    defer context.deinit();
    const result = try drainMasterNonBlocking(
        child.master_fd,
        &context,
        appendDrainTestBytes,
        .{},
    );

    try std.testing.expectEqualStrings("PTY_MASTER_DRAIN", context.bytes.items);
    try std.testing.expect(!result.eof);
}

fn readChildPtyOutput(allocator: std.mem.Allocator, child: *Child) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    while (true) {
        var buf: [4096]u8 = undefined;
        switch (try readMaster(child.master_fd, &buf)) {
            .bytes => |bytes| try output.appendSlice(allocator, bytes),
            .would_block => unreachable,
            .eof => return output.toOwnedSlice(allocator),
        }
    }
}

test "spawn applies portable tty settings before exec" {
    const modes = [_]tty_settings.Mode{
        .{ .opcode = 53, .value = 0 },
    };
    const settings = tty_settings.Settings{
        .term = "ansi",
        .modes = &modes,
    };
    var child = try spawn(std.testing.allocator, .{
        .rows = 24,
        .cols = 80,
        .shell = "/bin/sh",
        .shell_command = "printf 'TERM=%s\\n' \"$TERM\"; stty -a",
        .tty_settings = settings,
    });
    defer child.terminate();

    const output = try readChildPtyOutput(std.testing.allocator, &child);
    defer std.testing.allocator.free(output);
    const term = child.wait();

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    try std.testing.expect(std.mem.indexOf(u8, output, "TERM=ansi") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-echo") != null);
}
