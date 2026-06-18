const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const guid_ref = @import("../core/guid.zig");
const daemon_identity = @import("../daemon/identity.zig");
const daemon_log = @import("../daemon/log.zig");
const protocol = @import("../protocol/mod.zig");
const socket_transport = @import("../transport/socket.zig");

const proxy_mux_stream_id: u64 = 1;

// `sessh-proxy-remote` is the remote endpoint for one proxy byte stream. The
// local helper is `sessh-proxy`; this module only tracks/connects the remote
// process that opens localhost:sshd on the far side of the daemon tunnel.

// POSIX WNOHANG. Zig 0.15 does not expose a portable constant, and our
// supported Unix targets use the stable POSIX value.
const wait_nohang: c_int = 1;

pub const Process = struct {
    allocator: std.mem.Allocator,
    guid: []u8,
    socket_path: []u8,
    start_time: ?[]u8 = null,
    pid: c.pid_t = 0,
    owned_child: bool = false,

    fn deinit(self: *Process) void {
        self.allocator.free(self.guid);
        self.allocator.free(self.socket_path);
        if (self.start_time) |start_time| self.allocator.free(start_time);
        self.* = undefined;
    }
};

const ProcessIdentityJson = struct {
    pid: u64,
    start_time: []const u8,
};

// PROCESS_GLOBAL_REGISTRY: the local daemon tracks process-isolated proxy
// remotes here so shutdown and cleanup can see whether useful proxy work still
// exists. The daemon is single-threaded; mutations happen from dispatcher-owned
// callbacks.
var processes: std.ArrayList(*Process) = .empty;

pub fn connectOrStart(
    allocator: std.mem.Allocator,
    exe: []const u8,
    guid: []const u8,
    proxy_host: []const u8,
    proxy_port: u16,
) !*Process {
    pruneExited();
    const canonical = try guid_ref.canonicalProxyGuid(allocator, guid);
    defer allocator.free(canonical);

    if (lookup(canonical)) |control| {
        daemon_log.infof(allocator, "proxy remote reusing registered process guid={s}", .{canonical});
        return control;
    }

    const socket_path = try socketPath(allocator, exe, canonical);
    defer allocator.free(socket_path);

    if (connectProcessPath(socket_path)) |fd| {
        _ = c.close(fd);
        daemon_log.infof(allocator, "proxy remote rediscovered process guid={s}", .{canonical});
        return registerExisting(allocator, canonical, socket_path);
    } else |err| switch (err) {
        error.SocketDirMissing, error.SocketPathMissing, error.ConnectFailed => {},
        else => return err,
    }

    daemon_log.infof(allocator, "proxy remote starting process guid={s}", .{canonical});
    return start(allocator, exe, canonical, socket_path, proxy_host, proxy_port);
}

pub fn connect(control: *Process) !c.fd_t {
    return connectProcess(control) catch |err| switch (err) {
        error.SocketPathMissing, error.ConnectFailed => {
            forget(control.guid);
            return error.StreamNotFound;
        },
        else => return err,
    };
}

pub fn connectStarted(control: *Process) !c.fd_t {
    return connectProcess(control) catch |err| switch (err) {
        error.SocketPathMissing, error.ConnectFailed => {
            forget(control.guid);
            return error.StreamNotFound;
        },
        else => return err,
    };
}

pub fn requestCleanup(allocator: std.mem.Allocator, guid: []const u8) !void {
    const canonical = try guid_ref.canonicalProxyGuid(allocator, guid);
    defer allocator.free(canonical);
    const control = lookup(canonical) orelse return error.StreamNotFound;
    const fd = connect(control) catch |err| switch (err) {
        error.SocketPathMissing, error.ConnectFailed, error.StreamNotFound => {
            terminateAndForget(control);
            return;
        },
        else => return err,
    };
    defer _ = c.close(fd);
    protocol.sendMuxStreamFrame(allocator, fd, .{
        .stream_id = proxy_mux_stream_id,
        .message = .{ .reset = .{
            .code = "CLEANUP_REQUESTED",
            .message = "remote cleanup requested",
        } },
    }) catch {};
    terminateAndForget(control);
}

pub fn forget(guid: []const u8) void {
    for (processes.items, 0..) |control, index| {
        if (std.mem.eql(u8, control.guid, guid)) {
            removeAt(index, false);
            return;
        }
    }
}

pub fn terminate(guid: []const u8) void {
    for (processes.items, 0..) |control, index| {
        if (std.mem.eql(u8, control.guid, guid)) {
            removeAt(index, true);
            return;
        }
    }
}

pub fn activeCount() usize {
    pruneExited();
    return processes.items.len;
}

fn connectProcess(control: *const Process) !c.fd_t {
    return connectProcessPath(control.socket_path);
}

fn connectProcessPath(socket_path: []const u8) !c.fd_t {
    return socket_transport.connectSocket(socket_path);
}

fn start(
    allocator: std.mem.Allocator,
    exe: []const u8,
    guid: []const u8,
    socket_path: []u8,
    proxy_host: []const u8,
    proxy_port: u16,
) !*Process {
    try socket_transport.ensureSocketDir(allocator, socket_path);
    const listen_fd = try socket_transport.listenSocket(socket_path);
    errdefer _ = c.close(listen_fd);
    try socket_transport.clearCloseOnExec(listen_fd);

    const control = try allocator.create(Process);
    errdefer allocator.destroy(control);
    const control_guid = try allocator.dupe(u8, guid);
    errdefer allocator.free(control_guid);
    const control_socket_path = try allocator.dupe(u8, socket_path);
    errdefer allocator.free(control_socket_path);
    control.* = .{
        .allocator = allocator,
        .guid = control_guid,
        .socket_path = control_socket_path,
    };

    try register(control);
    errdefer unregister(control);

    const port_arg = try std.fmt.allocPrint(allocator, "{}", .{proxy_port});
    defer allocator.free(port_arg);
    const listen_fd_arg = try std.fmt.allocPrint(allocator, "{}", .{listen_fd});
    defer allocator.free(listen_fd_arg);
    const argv = [_][]const u8{ exe, listen_fd_arg, socket_path, guid, proxy_host, port_arg };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    errdefer posix.kill(@intCast(child.id), posix.SIG.HUP) catch {};
    _ = c.close(listen_fd);
    control.pid = @intCast(child.id);
    control.owned_child = true;
    control.start_time = try daemon_identity.processStartTime(allocator, @intCast(control.pid));
    try writeIdentityFile(allocator, control.socket_path, control.pid, control.start_time.?);
    return control;
}

fn registerExisting(
    allocator: std.mem.Allocator,
    guid: []u8,
    socket_path: []u8,
) !*Process {
    const control = try allocator.create(Process);
    errdefer allocator.destroy(control);
    const control_guid = try allocator.dupe(u8, guid);
    errdefer allocator.free(control_guid);
    const control_socket_path = try allocator.dupe(u8, socket_path);
    errdefer allocator.free(control_socket_path);
    control.* = .{
        .allocator = allocator,
        .guid = control_guid,
        .socket_path = control_socket_path,
        .pid = 0,
    };
    if (readIdentityFile(allocator, socket_path)) |identity| {
        control.pid = @intCast(identity.pid);
        control.start_time = identity.start_time;
    } else |err| switch (err) {
        error.FileNotFound, error.InvalidProcessIdentity => {},
        else => return err,
    }

    try register(control);
    return control;
}

fn socketPath(allocator: std.mem.Allocator, exe: []const u8, guid: []const u8) ![]u8 {
    const exe_dir = std.fs.path.dirname(exe) orelse return error.InvalidRemoteProcessExecutablePath;
    const namespace = std.fs.path.basename(exe_dir);
    const root = try socket_transport.shortRuntimeRoot(allocator);
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}/{s}/proxy-{s}.sock", .{ root, namespace, guid });
}

fn register(control: *Process) !void {
    for (processes.items) |existing| {
        if (std.mem.eql(u8, existing.guid, control.guid)) return error.StreamExists;
    }
    try processes.append(app_allocator.allocator(), control);
}

fn unregister(control: *Process) void {
    for (processes.items, 0..) |existing, index| {
        if (existing == control) {
            _ = processes.orderedRemove(index);
            return;
        }
    }
}

fn terminateAndForget(control: *Process) void {
    for (processes.items, 0..) |existing, index| {
        if (existing == control) {
            removeAt(index, true);
            return;
        }
    }
}

fn removeAt(index: usize, should_terminate: bool) void {
    const control = processes.orderedRemove(index);
    if (should_terminate) {
        std.fs.deleteFileAbsolute(control.socket_path) catch {};
        deleteIdentityFile(control.allocator, control.socket_path);
        signalProcess(control);
    }
    if (control.owned_child) _ = reapChild(control.pid);
    const allocator = control.allocator;
    control.deinit();
    allocator.destroy(control);
}

fn lookup(guid: []const u8) ?*Process {
    for (processes.items) |control| {
        if (std.mem.eql(u8, control.guid, guid)) return control;
    }
    return null;
}

fn pruneExited() void {
    var index: usize = 0;
    while (index < processes.items.len) {
        const control = processes.items[index];
        if (processExited(control)) {
            _ = processes.orderedRemove(index);
            std.fs.deleteFileAbsolute(control.socket_path) catch {};
            deleteIdentityFile(control.allocator, control.socket_path);
            const allocator = control.allocator;
            control.deinit();
            allocator.destroy(control);
            continue;
        }
        index += 1;
    }
}

fn processExited(control: *Process) bool {
    if (control.owned_child) return reapChild(control.pid);
    if (control.pid <= 0) return false;
    const start_time = control.start_time orelse return false;
    return !daemon_identity.processIdentityMatches(control.allocator, @intCast(control.pid), start_time);
}

fn signalProcess(control: *Process) void {
    if (control.pid <= 0) return;
    if (!control.owned_child) {
        const start_time = control.start_time orelse return;
        if (!daemon_identity.processIdentityMatches(control.allocator, @intCast(control.pid), start_time)) return;
    }
    posix.kill(control.pid, posix.SIG.HUP) catch {};
}

fn reapChild(pid: c.pid_t) bool {
    if (pid == 0) return false;
    if (pid < 0) return true;
    var status: c_int = 0;
    const result = c.waitpid(pid, &status, wait_nohang);
    if (result == pid) return true;
    if (result < 0) return switch (posix.errno(result)) {
        .CHILD => true,
        else => false,
    };
    return false;
}

fn identityPath(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.pid.json", .{socket_path});
}

fn writeIdentityFile(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    pid: c.pid_t,
    start_time: []const u8,
) !void {
    const path = try identityPath(allocator, socket_path);
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{}", .{ path, c.getpid() });
    defer allocator.free(tmp_path);

    std.fs.deleteFileAbsolute(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    errdefer std.fs.deleteFileAbsolute(tmp_path) catch {};

    var json_writer: std.Io.Writer.Allocating = .init(allocator);
    defer json_writer.deinit();
    try std.json.Stringify.value(ProcessIdentityJson{
        .pid = @intCast(pid),
        .start_time = start_time,
    }, .{}, &json_writer.writer);
    try json_writer.writer.writeByte('\n');
    const bytes = try json_writer.toOwnedSlice();
    defer allocator.free(bytes);

    var file = try std.fs.createFileAbsolute(tmp_path, .{
        .read = false,
        .truncate = true,
        .mode = 0o600,
    });
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
    try std.fs.renameAbsolute(tmp_path, path);
}

fn readIdentityFile(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
) !struct { pid: u64, start_time: []u8 } {
    const path = try identityPath(allocator, socket_path);
    defer allocator.free(path);
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(ProcessIdentityJson, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.pid == 0 or parsed.value.pid > @as(u64, @intCast(std.math.maxInt(c.pid_t)))) return error.InvalidProcessIdentity;
    const start_time = try allocator.dupe(u8, parsed.value.start_time);
    errdefer allocator.free(start_time);
    if (!daemon_identity.processIdentityMatches(allocator, parsed.value.pid, start_time)) {
        return error.InvalidProcessIdentity;
    }
    return .{
        .pid = parsed.value.pid,
        .start_time = start_time,
    };
}

fn deleteIdentityFile(allocator: std.mem.Allocator, socket_path: []const u8) void {
    const path = identityPath(allocator, socket_path) catch return;
    defer allocator.free(path);
    std.fs.deleteFileAbsolute(path) catch {};
}
