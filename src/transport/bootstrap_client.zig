const std = @import("std");
const c = std.c;
const posix = std.posix;

const app_allocator = @import("../core/app_allocator.zig");
const io = @import("../core/io.zig");
const client_ui = @import("../session/client_ui.zig");
const protocol = @import("../protocol/mod.zig");
const transport_bootstrap = @import("bootstrap.zig");
const remote_shell = @import("remote_shell.zig");

pub const ArtifactSet = transport_bootstrap.ArtifactSet;
pub const ArtifactEntry = transport_bootstrap.ArtifactEntry;
pub const Entrypoint = remote_shell.Entrypoint;

pub fn buildExecBytes(
    allocator: std.mem.Allocator,
    artifacts: *const ArtifactSet,
    entrypoint: Entrypoint,
    entrypoint_args: []const []const u8,
) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "EXEC ");
    try bytes.appendSlice(allocator, artifacts.artifact_set_id);
    for (artifacts.entries) |entry| {
        try bytes.append(allocator, ' ');
        try bytes.appendSlice(allocator, &entry.hash_hex);
    }
    try bytes.appendSlice(allocator, " -- ");
    try bytes.appendSlice(allocator, entrypoint.arg());
    for (entrypoint_args) |arg| {
        try bytes.append(allocator, ' ');
        try appendExecArg(allocator, &bytes, arg);
    }
    try bytes.append(allocator, '\n');
    return bytes.toOwnedSlice(allocator);
}

fn appendExecArg(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), arg: []const u8) !void {
    if (!remote_shell.needsEncodedExecArg(arg)) {
        try bytes.appendSlice(allocator, arg);
        return;
    }
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(arg.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, arg);
    try bytes.appendSlice(allocator, remote_shell.bootstrap_exec_encoded_arg_prefix);
    try bytes.appendSlice(allocator, encoded);
}

pub fn buildUploadBytes(
    allocator: std.mem.Allocator,
    artifact: *const ArtifactEntry,
) ![]u8 {
    const file = try std.fs.openFileAbsolute(artifact.path, .{});
    defer file.close();
    const file_bytes = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(file_bytes);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(file_bytes, &digest, .{});
    const actual_hash = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual_hash, &artifact.hash_hex)) return error.ArtifactHashMismatch;

    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(file_bytes.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, file_bytes);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "UPLOAD ");
    try bytes.appendSlice(allocator, artifact.id);
    try bytes.append(allocator, ' ');
    try bytes.appendSlice(allocator, &artifact.hash_hex);
    try bytes.append(allocator, ' ');
    try bytes.appendSlice(allocator, encoded);
    try bytes.append(allocator, '\n');
    return bytes.toOwnedSlice(allocator);
}

pub fn readLineWithSshStderr(
    allocator: std.mem.Allocator,
    stdout_fd: c.fd_t,
    stderr_fd: c.fd_t,
    client_fd: c.fd_t,
    reconnect_ui: ?*client_ui.ReconnectUi,
    poll_reconnect_input: bool,
) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    var stderr_open = stderr_fd >= 0;

    // BLOCKING_POLL: foreground SSH bootstrap read that also drains ssh
    // stderr. With reconnect UI active, the finite timeout lets local
    // cancellation interleave with pipe reads.
    while (line.items.len < 4096) {
        var pollfds = [_]posix.pollfd{
            .{
                .fd = stdout_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            },
            .{
                .fd = if (stderr_open) stderr_fd else -1,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };
        const ready = try posix.poll(&pollfds, if (reconnect_ui == null) -1 else 50);
        if (reconnect_ui) |ui| {
            if (try reconnectShouldCancel(ui, poll_reconnect_input)) return error.ReconnectCancelled;
        }
        if (ready == 0) continue;

        if (stderr_open and pollfds[1].revents != 0) {
            stderr_open = try forwardSshStderrFromFd(allocator, stderr_fd, client_fd);
        }

        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
            (pollfds[0].revents & posix.POLL.IN) == 0)
        {
            if (line.items.len == 0) return error.EndOfStream;
            return try line.toOwnedSlice(allocator);
        }
        if ((pollfds[0].revents & posix.POLL.IN) == 0) continue;

        var byte: [1]u8 = undefined;
        const n = c.read(stdout_fd, &byte, 1);
        if (n < 0) return error.ReadFailed;
        if (n == 0) {
            if (line.items.len == 0) return error.EndOfStream;
            return try line.toOwnedSlice(allocator);
        }
        if (byte[0] == '\n') return try line.toOwnedSlice(allocator);
        try line.append(allocator, byte[0]);
    }

    return error.BootstrapLineTooLong;
}

fn reconnectShouldCancel(reconnect_ui: *client_ui.ReconnectUi, poll_reconnect_input: bool) !bool {
    if (!poll_reconnect_input) return reconnect_ui.isCancelled();
    return reconnect_ui.pollClientHangup(0);
}

pub fn forwardSshStderrFromFd(allocator: std.mem.Allocator, fd: c.fd_t, client_fd: c.fd_t) !bool {
    if (fd < 0) return false;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) switch (posix.errno(n)) {
            .AGAIN => return true,
            .INTR => continue,
            else => return error.ReadFailed,
        };
        if (n == 0) return false;
        if (client_fd >= 0) {
            protocol.sendSshTransportStderrFrame(allocator, client_fd, buf[0..@intCast(n)]) catch {};
        }
    }
}

const Status = enum {
    binary_bootstrapping,
    daemon_connecting,
};

fn statusBytes(status: Status) []const u8 {
    return switch (status) {
        .binary_bootstrapping => "\rsessh: bootstrapping...",
        .daemon_connecting => "\r\x1b[K",
    };
}

fn sendStatus(client_status_fd: c.fd_t, status: Status) !void {
    if (client_status_fd >= 0) {
        switch (status) {
            .binary_bootstrapping => try protocol.sendSshTransportBinaryBootstrappingFrame(app_allocator.allocator(), client_status_fd),
            .daemon_connecting => try protocol.sendSshTransportDaemonConnectingFrame(app_allocator.allocator(), client_status_fd),
        }
    } else {
        try io.writeAll(2, statusBytes(status));
    }
}

pub fn showStatus(visible: *bool, reconnect_ui: ?*client_ui.ReconnectUi, client_status_fd: c.fd_t) !void {
    if (reconnect_ui != null or visible.*) return;
    try sendStatus(client_status_fd, .binary_bootstrapping);
    visible.* = true;
}

pub fn clearStatus(visible: *bool, client_status_fd: c.fd_t) void {
    if (!visible.*) return;
    sendStatus(client_status_fd, .daemon_connecting) catch {};
    visible.* = false;
}

test "buildExecBytes writes role entrypoint and encodes reserved args" {
    const hash = [_]u8{'0'} ** 64;
    const entries = [_]ArtifactEntry{.{
        .id = @constCast("sessh-test"),
        .os = @constCast("linux"),
        .arch = @constCast("x86_64"),
        .path = @constCast("/tmp/sessh-test"),
        .hash_hex = hash,
    }};
    const artifacts = ArtifactSet{
        .allocator = std.testing.allocator,
        .artifact_set_id = @constCast("test-set"),
        .entries = @constCast(entries[0..]),
    };
    const bytes = try buildExecBytes(std.testing.allocator, &artifacts, .broker, &.{ "3.dev.test", "b64:literal" });
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualStrings(
        "EXEC test-set 0000000000000000000000000000000000000000000000000000000000000000 -- sessh-broker 3.dev.test b64:YjY0OmxpdGVyYWw=\n",
        bytes,
    );
}
