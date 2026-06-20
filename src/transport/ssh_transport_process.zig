// Spawns and tracks the OpenSSH process that carries one pooled daemon tunnel.
// Higher-level pooling decides when to reuse or reconnect; this module owns the
// process argv, fd setup, and exit-status polling.
const std = @import("std");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const core_fds = @import("../core/fds.zig");
const process_wait = @import("../core/waitpid.zig");
const daemon_log = @import("../daemon/log.zig");
const ssh_opts = @import("ssh_options.zig");

const appendTransportSshOptions = ssh_opts.appendTransportSshOptions;
const transportSshOptionsLen = ssh_opts.transportSshOptionsLen;

pub const Target = struct {
    options: []const []const u8,
    host: []const u8,
    default_ipqos_option: ?[]const u8 = null,
    resolved_user: []const u8 = "",
    resolved_host: []const u8 = "",
    resolved_port: []const u8 = config.default_ssh_port,
};

pub const SshTransportProcess = struct {
    process: std.process.Child,
    stderr_fd: c.fd_t = -1,

    pub fn closeStdin(self: *SshTransportProcess) void {
        closeProcessStdin(&self.process);
    }

    pub fn closeStderr(self: *SshTransportProcess) void {
        if (self.stderr_fd >= 0) {
            posix.close(self.stderr_fd);
            self.stderr_fd = -1;
        }
    }

    pub fn stdinFd(self: *const SshTransportProcess) c.fd_t {
        return self.process.stdin.?.handle;
    }

    pub fn stdoutFd(self: *const SshTransportProcess) c.fd_t {
        return self.process.stdout.?.handle;
    }

    pub fn wait(self: *SshTransportProcess) !std.process.Child.Term {
        return self.process.wait();
    }

    pub fn pollExit(self: *SshTransportProcess) ?std.process.Child.Term {
        if (self.process.term) |term| {
            return term catch .{ .Unknown = 0 };
        }
        var status: c_int = 0;
        const result = c.waitpid(self.process.id, &status, process_wait.nohang);
        if (result == 0) return null;
        if (result < 0) {
            return switch (posix.errno(result)) {
                .INTR => null,
                else => .{ .Unknown = 0 },
            };
        }
        const term = process_wait.termFromStatus(@bitCast(status));
        self.process.term = term;
        self.process.id = undefined;
        return term;
    }

    pub fn terminate(self: *SshTransportProcess) void {
        self.closeStdin();
        _ = self.process.kill() catch {
            _ = self.process.wait() catch {};
        };
        self.closeStderr();
    }
};

pub fn defaultSshOptionsLen(target: Target) usize {
    return if (target.default_ipqos_option == null) 0 else 1;
}

pub fn appendDefaultSshOptions(ssh_argv: [][]const u8, start_index: usize, default_ipqos_option: ?[]const u8) usize {
    var arg_index = start_index;
    if (default_ipqos_option) |option| {
        ssh_argv[arg_index] = option;
        arg_index += 1;
    }
    return arg_index;
}

pub const SpawnOptions = struct {
    allocator: std.mem.Allocator,
    target: Target,
    remote_command: []const u8,
    env_map: ?*const std.process.EnvMap,
    bootstrap: bool,
};

pub fn spawnSshTransportProcess(options: SpawnOptions) !SshTransportProcess {
    // Start the daemon-owned OpenSSH process that carries the sessh mux tunnel.
    // It always runs `ssh -T <host> <remote-command>` because sessh, not
    // OpenSSH, owns terminal allocation and logical stream multiplexing.
    const allocator = options.allocator;
    const target = options.target;
    const remote_command = options.remote_command;
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
    arg_index = appendDefaultSshOptions(ssh_argv, arg_index, target.default_ipqos_option);
    arg_index = appendTransportSshOptions(ssh_argv, arg_index, target.options);
    ssh_argv[arg_index] = "-T";
    ssh_argv[arg_index + 1] = target.host;
    ssh_argv[ssh_argv.len - 1] = remote_command;
    daemon_log.infof(allocator, "ssh transport starting host={s} bootstrap={}", .{ target.host, options.bootstrap });

    var process = std.process.Child.init(ssh_argv, allocator);
    process.expand_arg0 = .expand;
    process.stdin_behavior = .Pipe;
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;
    process.env_map = options.env_map;
    try process.spawn();
    daemon_log.infof(allocator, "ssh transport started host={s}", .{target.host});
    var connection = SshTransportProcess{ .process = process };
    errdefer connection.terminate();
    const stderr_file = connection.process.stderr.?;
    connection.process.stderr = null;
    connection.stderr_fd = stderr_file.handle;
    try core_fds.setNonBlocking(connection.stderr_fd);
    return connection;
}

fn closeProcessStdin(process: *std.process.Child) void {
    if (process.stdin) |*stdin| {
        stdin.close();
        process.stdin = null;
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
    const index = appendDefaultSshOptions(&argv, 0, parsed.default_ipqos_option);
    try std.testing.expectEqual(@as(usize, 1), index);
    try std.testing.expectEqualStrings("-oIPQoS=af21", argv[0]);

    parsed.default_ipqos_option = null;
    try std.testing.expectEqual(@as(usize, 0), defaultSshOptionsLen(parsed));
}
