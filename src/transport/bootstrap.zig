const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;

const client_ui = @import("../session/client_ui.zig");
const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const remote_shell = @import("remote_shell.zig");

const max_artifact_bytes = 64 * 1024 * 1024;
const max_artifact_manifest_bytes = 16 * 1024;
const artifact_manifest_filename = "artifacts.manifest";

pub const ReconnectIoContext = struct {
    reconnect_ui: ?*client_ui.ReconnectUi = null,
    poll_reconnect_input: bool = false,

    pub fn shouldCancel(self: ReconnectIoContext) !bool {
        const reconnect_ui = self.reconnect_ui orelse return false;
        if (!self.poll_reconnect_input) return reconnect_ui.isCancelled();
        return reconnect_ui.pollClientHangup(0);
    }
};

pub const ArtifactSet = struct {
    allocator: std.mem.Allocator,
    artifact_set_id: []u8,
    entries: []ArtifactEntry,

    pub fn deinit(self: *ArtifactSet) void {
        self.allocator.free(self.artifact_set_id);
        for (self.entries) |*entry| entry.deinit(self.allocator);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn sendExec(
        self: *const ArtifactSet,
        fd: c.fd_t,
        entrypoint: remote_shell.Entrypoint,
        entrypoint_args: []const []const u8,
        reconnect_io: ReconnectIoContext,
    ) !void {
        try writeAllMaybeCancellable(fd, "EXEC ", reconnect_io);
        try writeAllMaybeCancellable(fd, self.artifact_set_id, reconnect_io);
        for (self.entries) |entry| {
            try writeAllMaybeCancellable(fd, " ", reconnect_io);
            try writeAllMaybeCancellable(fd, &entry.hash_hex, reconnect_io);
        }
        try writeAllMaybeCancellable(fd, " --", reconnect_io);
        try writeAllMaybeCancellable(fd, " ", reconnect_io);
        try writeAllMaybeCancellable(fd, entrypoint.arg(), reconnect_io);
        for (entrypoint_args) |arg| {
            try writeAllMaybeCancellable(fd, " ", reconnect_io);
            try self.writeExecArg(fd, arg, reconnect_io);
        }
        try writeAllMaybeCancellable(fd, "\n", reconnect_io);
    }

    pub fn sendExecArgs(
        self: *const ArtifactSet,
        fd: c.fd_t,
        exec_args: []const []const u8,
        reconnect_io: ReconnectIoContext,
    ) !void {
        try writeAllMaybeCancellable(fd, "EXEC ", reconnect_io);
        try writeAllMaybeCancellable(fd, self.artifact_set_id, reconnect_io);
        for (self.entries) |entry| {
            try writeAllMaybeCancellable(fd, " ", reconnect_io);
            try writeAllMaybeCancellable(fd, &entry.hash_hex, reconnect_io);
        }
        try writeAllMaybeCancellable(fd, " --", reconnect_io);
        for (exec_args) |arg| {
            try writeAllMaybeCancellable(fd, " ", reconnect_io);
            try self.writeExecArg(fd, arg, reconnect_io);
        }
        try writeAllMaybeCancellable(fd, "\n", reconnect_io);
    }

    fn writeExecArg(
        self: *const ArtifactSet,
        fd: c.fd_t,
        arg: []const u8,
        reconnect_io: ReconnectIoContext,
    ) !void {
        if (!remote_shell.needsEncodedExecArg(arg)) {
            try writeAllMaybeCancellable(fd, arg, reconnect_io);
            return;
        }

        const encoded = try self.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(arg.len));
        defer self.allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, arg);
        try writeAllMaybeCancellable(fd, remote_shell.bootstrap_exec_encoded_arg_prefix, reconnect_io);
        try writeAllMaybeCancellable(fd, encoded, reconnect_io);
    }

    pub fn find(self: *const ArtifactSet, platform: Platform) ?*const ArtifactEntry {
        for (self.entries) |*entry| {
            if (platformsEqual(entry.platform(), platform)) return entry;
        }
        return null;
    }
};

pub const ArtifactEntry = struct {
    id: []u8,
    os: []u8,
    arch: []u8,
    path: []u8,
    hash_hex: [64]u8,

    fn deinit(self: *ArtifactEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.os);
        allocator.free(self.arch);
        allocator.free(self.path);
        self.* = undefined;
    }

    fn platform(self: *const ArtifactEntry) Platform {
        return .{ .os = self.os, .arch = self.arch };
    }
};

pub const Platform = struct {
    os: []const u8,
    arch: []const u8,
};

const PackagedArtifactTarget = struct {
    os: []const u8,
    arch: []const u8,
    filename: []const u8,
    path: []const u8,
};

const packaged_artifact_targets = [_]PackagedArtifactTarget{
    .{ .os = "macos", .arch = "aarch64", .filename = "sessh-macos-aarch64", .path = "macos-aarch64/sessh" },
    .{ .os = "macos", .arch = "x86_64", .filename = "sessh-macos-x86_64", .path = "macos-x86_64/sessh" },
    .{ .os = "linux", .arch = "arm32", .filename = "sessh-linux-arm32", .path = "linux-arm32/sessh" },
    .{ .os = "linux", .arch = "aarch64", .filename = "sessh-linux-aarch64", .path = "linux-aarch64/sessh" },
    .{ .os = "linux", .arch = "x86_64", .filename = "sessh-linux-x86_64", .path = "linux-x86_64/sessh" },
    .{ .os = "linux", .arch = "x86", .filename = "sessh-linux-x86", .path = "linux-x86/sessh" },
    .{ .os = "linux", .arch = "riscv64", .filename = "sessh-linux-riscv64", .path = "linux-riscv64/sessh" },
};

pub fn loadArtifactSet(allocator: std.mem.Allocator) !ArtifactSet {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    if (isDevelopmentExecutable(exe_path)) {
        return loadDevelopmentArtifactSet(allocator, exe_path);
    }

    return loadPackagedArtifactSet(allocator, exe_path) catch |err| switch (err) {
        error.NoPackagedArtifacts => loadDevelopmentArtifactSet(allocator, exe_path),
        else => err,
    };
}

fn isDevelopmentExecutable(exe_path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(exe_path), "sessh-dev");
}

fn loadPackagedArtifactSet(allocator: std.mem.Allocator, exe_path: []const u8) !ArtifactSet {
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidExePath;
    if (try loadPackagedArtifactSetFromDir(allocator, exe_dir)) |artifact_set| {
        return artifact_set;
    }

    const artifact_root = std.fs.path.dirname(exe_dir) orelse return error.NoPackagedArtifacts;
    if (try loadPackagedArtifactSetFromDir(allocator, artifact_root)) |artifact_set| {
        return artifact_set;
    }

    const libexec_dir = try std.fs.path.join(allocator, &.{ artifact_root, "libexec", "sessh" });
    defer allocator.free(libexec_dir);
    if (try loadPackagedArtifactSetFromDir(allocator, libexec_dir)) |artifact_set| {
        return artifact_set;
    }

    return error.NoPackagedArtifacts;
}

fn loadPackagedArtifactSetFromDir(allocator: std.mem.Allocator, artifact_dir: []const u8) !?ArtifactSet {
    if (try loadPackagedArtifactManifest(allocator, artifact_dir)) |artifact_set| {
        return artifact_set;
    }

    var found_any = false;
    for (packaged_artifact_targets) |target| {
        const path = try std.fs.path.join(allocator, &.{ artifact_dir, target.path });
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        file.close();
        found_any = true;
        break;
    }
    if (!found_any) return null;

    var entries = try allocator.alloc(ArtifactEntry, packaged_artifact_targets.len);
    errdefer allocator.free(entries);
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |*entry| entry.deinit(allocator);
    }

    for (packaged_artifact_targets, 0..) |target, i| {
        const path = try std.fs.path.join(allocator, &.{ artifact_dir, target.path });
        errdefer allocator.free(path);

        entries[i] = try loadArtifactEntryForPlatform(allocator, path, .{
            .os = target.os,
            .arch = target.arch,
        });
        allocator.free(path);
        initialized += 1;
    }

    return .{
        .allocator = allocator,
        .artifact_set_id = try allocator.dupe(u8, config.version),
        .entries = entries,
    };
}

fn loadPackagedArtifactManifest(allocator: std.mem.Allocator, artifact_dir: []const u8) !?ArtifactSet {
    const manifest_path = try std.fs.path.join(allocator, &.{ artifact_dir, artifact_manifest_filename });
    defer allocator.free(manifest_path);

    const file = std.fs.openFileAbsolute(manifest_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_artifact_manifest_bytes);
    defer allocator.free(bytes);

    return try parsePackagedArtifactManifest(allocator, artifact_dir, bytes);
}

fn parsePackagedArtifactManifest(
    allocator: std.mem.Allocator,
    artifact_dir: []const u8,
    bytes: []const u8,
) !ArtifactSet {
    var entries = try allocator.alloc(ArtifactEntry, packaged_artifact_targets.len);
    errdefer allocator.free(entries);
    var seen = [_]bool{false} ** packaged_artifact_targets.len;
    errdefer {
        for (seen, 0..) |entry_seen, i| {
            if (entry_seen) entries[i].deinit(allocator);
        }
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, ' ');
        const filename = fields.next() orelse return error.InvalidArtifactManifest;
        const hash_hex = fields.next() orelse return error.InvalidArtifactManifest;
        if (fields.next() != null) return error.InvalidArtifactManifest;

        const target_index = packagedArtifactTargetIndex(filename) orelse return error.InvalidArtifactManifest;
        if (seen[target_index]) return error.InvalidArtifactManifest;
        const target = packaged_artifact_targets[target_index];
        if (!isLowerSha256Hex(hash_hex)) return error.InvalidArtifactManifest;

        const path = try std.fs.path.join(allocator, &.{ artifact_dir, target.path });
        entries[target_index] = try artifactEntryFromManifest(allocator, path, target, hash_hex);
        seen[target_index] = true;
    }

    for (seen) |entry_seen| {
        if (!entry_seen) return error.InvalidArtifactManifest;
    }

    return .{
        .allocator = allocator,
        .artifact_set_id = try allocator.dupe(u8, config.version),
        .entries = entries,
    };
}

fn artifactEntryFromManifest(
    allocator: std.mem.Allocator,
    path: []u8,
    target: PackagedArtifactTarget,
    hash_text: []const u8,
) !ArtifactEntry {
    errdefer allocator.free(path);

    const id = try std.fmt.allocPrint(
        allocator,
        "sessh-{s}-{s}-{s}",
        .{ config.version, target.os, target.arch },
    );
    errdefer allocator.free(id);

    const os = try allocator.dupe(u8, target.os);
    errdefer allocator.free(os);
    const arch = try allocator.dupe(u8, target.arch);
    errdefer allocator.free(arch);

    var hash_hex: [64]u8 = undefined;
    @memcpy(hash_hex[0..], hash_text);

    return .{
        .id = id,
        .os = os,
        .arch = arch,
        .path = path,
        .hash_hex = hash_hex,
    };
}

fn loadDevelopmentArtifactSet(allocator: std.mem.Allocator, exe_path: []const u8) !ArtifactSet {
    const entry = try loadCurrentArtifactEntry(allocator, exe_path);
    errdefer {
        var mutable = entry;
        mutable.deinit(allocator);
    }

    const entries = try allocator.alloc(ArtifactEntry, 1);
    entries[0] = entry;
    errdefer allocator.free(entries);

    return .{
        .allocator = allocator,
        .artifact_set_id = try allocator.dupe(u8, config.version),
        .entries = entries,
    };
}

fn loadCurrentArtifactEntry(allocator: std.mem.Allocator, exe_path: []const u8) !ArtifactEntry {
    return loadArtifactEntryForPlatform(allocator, exe_path, localPlatform());
}

fn loadArtifactEntryForPlatform(
    allocator: std.mem.Allocator,
    path: []const u8,
    platform: Platform,
) !ArtifactEntry {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_artifact_bytes);
    defer allocator.free(bytes);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    return .{
        .id = try std.fmt.allocPrint(
            allocator,
            "sessh-{s}-{s}-{s}",
            .{ config.version, platform.os, platform.arch },
        ),
        .os = try allocator.dupe(u8, platform.os),
        .arch = try allocator.dupe(u8, platform.arch),
        .path = try allocator.dupe(u8, path),
        .hash_hex = std.fmt.bytesToHex(digest, .lower),
    };
}

pub fn sendUpload(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    artifact: *const ArtifactEntry,
    reconnect_io: ReconnectIoContext,
) !void {
    const file = try std.fs.openFileAbsolute(artifact.path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_artifact_bytes);
    defer allocator.free(bytes);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual_hash = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual_hash, &artifact.hash_hex)) return error.ArtifactHashMismatch;

    const encoded = try allocator.alloc(
        u8,
        std.base64.standard.Encoder.calcSize(bytes.len),
    );
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);

    try writeAllMaybeCancellable(fd, "UPLOAD ", reconnect_io);
    try writeAllMaybeCancellable(fd, artifact.id, reconnect_io);
    try writeAllMaybeCancellable(fd, " ", reconnect_io);
    try writeAllMaybeCancellable(fd, &artifact.hash_hex, reconnect_io);
    try writeAllMaybeCancellable(fd, " ", reconnect_io);
    try writeAllMaybeCancellable(fd, encoded, reconnect_io);
    try writeAllMaybeCancellable(fd, "\n", reconnect_io);
}

pub fn parseMissingPlatform(line: []const u8) !Platform {
    if (!std.mem.startsWith(u8, line, "MISSING ")) return error.InvalidMissingResponse;
    var fields = std.mem.splitScalar(u8, line["MISSING ".len..], ' ');
    const os = fields.next() orelse return error.InvalidMissingResponse;
    const arch = fields.next() orelse return error.InvalidMissingResponse;
    if (fields.next() != null or os.len == 0 or arch.len == 0) return error.InvalidMissingResponse;
    return .{ .os = os, .arch = arch };
}

fn localPlatform() Platform {
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        else => "unsupported",
    };
    const arch = switch (builtin.cpu.arch) {
        .x86 => "x86",
        .x86_64 => "x86_64",
        .arm => "arm32",
        .aarch64 => "aarch64",
        .riscv64 => "riscv64",
        else => "unsupported",
    };
    return .{ .os = os, .arch = arch };
}

fn platformsEqual(a: Platform, b: Platform) bool {
    return std.mem.eql(u8, a.os, b.os) and std.mem.eql(u8, a.arch, b.arch);
}

pub fn artifactFilenameForPlatform(platform: Platform) ?[]const u8 {
    for (packaged_artifact_targets) |target| {
        if (platformsEqual(.{ .os = target.os, .arch = target.arch }, platform)) {
            return target.filename;
        }
    }
    return null;
}

fn packagedArtifactTargetIndex(filename: []const u8) ?usize {
    for (packaged_artifact_targets, 0..) |target, i| {
        if (std.mem.eql(u8, target.filename, filename)) return i;
    }
    return null;
}

fn isLowerSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn writeAllMaybeCancellable(
    fd: c.fd_t,
    bytes: []const u8,
    reconnect_io: ReconnectIoContext,
) !void {
    if (reconnect_io.reconnect_ui == null) {
        try io.writeAll(fd, bytes);
        return;
    }

    // BLOCKING_POLL: foreground SSH bootstrap write. The short timeout exists
    // only so reconnect UI cancellation can be observed while the pipe blocks.
    var written: usize = 0;
    while (written < bytes.len) {
        var pollfds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.OUT,
            .revents = 0,
        }};
        const ready = try posix.poll(&pollfds, 50);
        if (try reconnect_io.shouldCancel()) return error.ReconnectCancelled;
        if (ready == 0) continue;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) return error.WriteFailed;
        if ((pollfds[0].revents & posix.POLL.OUT) == 0) continue;

        const chunk_len = @min(bytes.len - written, 4096);
        const n = c.write(fd, bytes[written..].ptr, chunk_len);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

pub fn readBootstrapLine(
    allocator: std.mem.Allocator,
    fd: c.fd_t,
    reconnect_io: ReconnectIoContext,
) ![]u8 {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    // BLOCKING_POLL: foreground SSH bootstrap read. With reconnect UI active,
    // the finite timeout lets local cancellation interleave with pipe reads.
    while (line.items.len < 4096) {
        var pollfds = [_]posix.pollfd{.{
            .fd = fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try posix.poll(&pollfds, if (reconnect_io.reconnect_ui == null) -1 else 50);
        if (try reconnect_io.shouldCancel()) return error.ReconnectCancelled;
        if (ready == 0) continue;
        if ((pollfds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0 and
            (pollfds[0].revents & posix.POLL.IN) == 0)
        {
            if (line.items.len == 0) return error.EndOfStream;
            return try line.toOwnedSlice(allocator);
        }
        if ((pollfds[0].revents & posix.POLL.IN) == 0) continue;
        var byte: [1]u8 = undefined;
        const n = c.read(fd, &byte, 1);
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

test "readBootstrapLine returns the first line without the newline" {
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);

    try io.writeAll(fds[1], "MISSING linux x86_64\nextra\n");
    const line = try readBootstrapLine(std.testing.allocator, fds[0], .{});
    defer std.testing.allocator.free(line);

    try std.testing.expectEqualStrings("MISSING linux x86_64", line);
}

test "parseMissingPlatform parses canonical platform fields" {
    const platform = try parseMissingPlatform("MISSING macos aarch64");

    try std.testing.expectEqualStrings("macos", platform.os);
    try std.testing.expectEqualStrings("aarch64", platform.arch);
}

test "artifactFilenameForPlatform maps canonical platform fields to packaged names" {
    try std.testing.expectEqualStrings(
        "sessh-linux-aarch64",
        artifactFilenameForPlatform(.{ .os = "linux", .arch = "aarch64" }) orelse return error.MissingArtifactName,
    );
    try std.testing.expectEqualStrings(
        "sessh-macos-x86_64",
        artifactFilenameForPlatform(.{ .os = "macos", .arch = "x86_64" }) orelse return error.MissingArtifactName,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), artifactFilenameForPlatform(.{
        .os = "linux",
        .arch = "sparc",
    }));
}

test "packaged artifact manifest supplies hashes without hashing artifact contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const zero_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(std.testing.allocator);
    for (packaged_artifact_targets) |target| {
        if (std.fs.path.dirname(target.path)) |dir| try tmp.dir.makePath(dir);
        try tmp.dir.writeFile(.{ .sub_path = target.path, .data = "x" });
        try manifest.writer(std.testing.allocator).print(
            "{s} {s}\n",
            .{ target.filename, zero_hash },
        );
    }
    try tmp.dir.writeFile(.{ .sub_path = artifact_manifest_filename, .data = manifest.items });

    const artifact_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(artifact_dir);
    var artifact_set = (try loadPackagedArtifactSetFromDir(std.testing.allocator, artifact_dir)) orelse {
        return error.MissingArtifactSet;
    };
    defer artifact_set.deinit();

    const entry = artifact_set.find(.{ .os = "linux", .arch = "x86_64" }) orelse {
        return error.MissingArtifactEntry;
    };
    try std.testing.expectEqualStrings(zero_hash, entry.hash_hex[0..]);
}

test "packaged artifact set loads from platform executable directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const zero_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(std.testing.allocator);
    for (packaged_artifact_targets) |target| {
        if (std.fs.path.dirname(target.path)) |dir| try tmp.dir.makePath(dir);
        try tmp.dir.writeFile(.{ .sub_path = target.path, .data = "x" });
        try manifest.writer(std.testing.allocator).print(
            "{s} {s}\n",
            .{ target.filename, zero_hash },
        );
    }
    try tmp.dir.writeFile(.{ .sub_path = artifact_manifest_filename, .data = manifest.items });

    const artifact_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(artifact_dir);
    const exe_path = try std.fs.path.join(std.testing.allocator, &.{ artifact_dir, "macos-aarch64", "sessh" });
    defer std.testing.allocator.free(exe_path);

    var artifact_set = try loadPackagedArtifactSet(std.testing.allocator, exe_path);
    defer artifact_set.deinit();

    const entry = artifact_set.find(.{ .os = "linux", .arch = "x86_64" }) orelse {
        return error.MissingArtifactEntry;
    };
    try std.testing.expectEqualStrings(zero_hash, entry.hash_hex[0..]);
}

test "sessh-dev uses development artifact upload" {
    try std.testing.expect(isDevelopmentExecutable("/tmp/sessh-dev"));
    try std.testing.expect(isDevelopmentExecutable("/tmp/build/bin/sessh-dev"));
    try std.testing.expect(!isDevelopmentExecutable("/tmp/build/bin/sessh"));
    try std.testing.expect(!isDevelopmentExecutable("/tmp/libexec/sessh/macos-aarch64/sessh"));
}
