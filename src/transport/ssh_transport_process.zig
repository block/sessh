const std = @import("std");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const daemon_log = @import("../daemon/log.zig");
const ssh_opts = @import("ssh_options.zig");

const appendTransportSshOptions = ssh_opts.appendTransportSshOptions;
const transportSshOptionsLen = ssh_opts.transportSshOptionsLen;

// POSIX WNOHANG. Zig 0.15 does not expose a portable constant, and our
// supported Unix targets use the stable POSIX value.
const wait_nohang: c_int = 1;

pub const Target = struct {
    options: []const []const u8,
    host: []const u8,
    default_ipqos_option: ?[]const u8 = null,
    resolved_user: []const u8 = "",
    resolved_host: []const u8 = "",
    resolved_port: []const u8 = config.default_ssh_port,
};

pub const SshTransportProcess = struct {
    child: std.process.Child,
    stderr_fd: c.fd_t = -1,

    pub fn closeStdin(self: *SshTransportProcess) void {
        closeChildStdin(&self.child);
    }

    pub fn closeStderr(self: *SshTransportProcess) void {
        if (self.stderr_fd >= 0) {
            posix.close(self.stderr_fd);
            self.stderr_fd = -1;
        }
    }

    pub fn wait(self: *SshTransportProcess) !std.process.Child.Term {
        return self.child.wait();
    }

    pub fn pollExit(self: *SshTransportProcess) ?std.process.Child.Term {
        if (self.child.term) |term| {
            return term catch .{ .Unknown = 0 };
        }
        var status: c_int = 0;
        const result = c.waitpid(self.child.id, &status, wait_nohang);
        if (result == 0) return null;
        if (result < 0) {
            return switch (posix.errno(result)) {
                .INTR => null,
                else => .{ .Unknown = 0 },
            };
        }
        const term = waitStatusToTerm(@bitCast(status));
        self.child.term = term;
        self.child.id = undefined;
        return term;
    }

    pub fn terminate(self: *SshTransportProcess) void {
        self.closeStdin();
        _ = self.child.kill() catch {
            _ = self.child.wait() catch {};
        };
        self.closeStderr();
    }
};

fn waitStatusToTerm(status: u32) std.process.Child.Term {
    return if (posix.W.IFEXITED(status))
        .{ .Exited = posix.W.EXITSTATUS(status) }
    else if (posix.W.IFSIGNALED(status))
        .{ .Signal = posix.W.TERMSIG(status) }
    else if (posix.W.IFSTOPPED(status))
        .{ .Stopped = posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

pub fn defaultSshOptionsLen(target: Target) usize {
    return if (target.default_ipqos_option == null) 0 else 1;
}

pub fn appendDefaultSshOptions(ssh_argv: [][]const u8, arg_index: *usize, default_ipqos_option: ?[]const u8) void {
    if (default_ipqos_option) |option| {
        ssh_argv[arg_index.*] = option;
        arg_index.* += 1;
    }
}

pub fn spawnSshTransportProcess(
    allocator: std.mem.Allocator,
    target: Target,
    remote_command: []const u8,
    env_map: ?*const std.process.EnvMap,
    bootstrap: bool,
) !SshTransportProcess {
    const batch_mode_options: usize = 1;
    const default_options = defaultSshOptionsLen(target);
    const transport_options = transportSshOptionsLen(target.options);
    const ssh_argv = try allocator.alloc([]const u8, transport_options + batch_mode_options + default_options + 4);
    defer allocator.free(ssh_argv);
    ssh_argv[0] = "ssh";
    var arg_index: usize = 1;
    // Daemon-owned ssh transports must fail cleanly instead of prompting on
    // stdio. Put this before user/config options because OpenSSH uses the first
    // value it sees for many config keys.
    ssh_argv[arg_index] = "-oBatchMode=yes";
    arg_index += 1;
    appendDefaultSshOptions(ssh_argv, &arg_index, target.default_ipqos_option);
    appendTransportSshOptions(ssh_argv, &arg_index, target.options);
    ssh_argv[arg_index] = "-T";
    ssh_argv[arg_index + 1] = target.host;
    ssh_argv[ssh_argv.len - 1] = remote_command;
    daemon_log.infof(allocator, "ssh transport starting host={s} bootstrap={}", .{ target.host, bootstrap });

    var child = std.process.Child.init(ssh_argv, allocator);
    child.expand_arg0 = .expand;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = env_map;
    try child.spawn();
    daemon_log.infof(allocator, "ssh transport started host={s}", .{target.host});
    var connection = SshTransportProcess{ .child = child };
    errdefer connection.terminate();
    const stderr_file = connection.child.stderr.?;
    connection.child.stderr = null;
    connection.stderr_fd = stderr_file.handle;
    try setNonBlockingFd(connection.stderr_fd);
    return connection;
}

pub fn setNonBlockingFd(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.FcntlFailed;
    const nonblocking_flag = @as(c_int, @bitCast(c.O{ .NONBLOCK = true }));
    if ((flags & nonblocking_flag) != 0) return;
    if (c.fcntl(fd, c.F.SETFL, flags | nonblocking_flag) < 0) return error.FcntlFailed;
}

fn closeChildStdin(child: *std.process.Child) void {
    if (child.stdin) |*stdin| {
        stdin.close();
        child.stdin = null;
    }
}

test "default ssh options append resolved interactive IPQoS value" {
    var parsed = Target{
        .options = &.{},
        .host = "example.com",
        .default_ipqos_option = "-oIPQoS=af21",
    };
    try std.testing.expectEqual(@as(usize, 1), defaultSshOptionsLen(parsed));

    var argv: [4][]const u8 = undefined;
    var index: usize = 0;
    appendDefaultSshOptions(&argv, &index, parsed.default_ipqos_option);
    try std.testing.expectEqual(@as(usize, 1), index);
    try std.testing.expectEqualStrings("-oIPQoS=af21", argv[0]);

    parsed.default_ipqos_option = null;
    try std.testing.expectEqual(@as(usize, 0), defaultSshOptionsLen(parsed));
}
