const std = @import("std");

const transport_bootstrap = @import("bootstrap.zig");
const remote_shell = @import("remote_shell.zig");

pub const ArtifactSet = transport_bootstrap.ArtifactSet;
pub const ArtifactEntry = transport_bootstrap.ArtifactEntry;
pub const Entrypoint = remote_shell.Entrypoint;

pub const BuildExecBytesOptions = struct {
    allocator: std.mem.Allocator,
    artifacts: *const ArtifactSet,
    entrypoint: Entrypoint,
    entrypoint_args: []const []const u8 = &.{},
};

pub fn buildExecBytes(options: BuildExecBytesOptions) ![]u8 {
    const allocator = options.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "EXEC ");
    try bytes.appendSlice(allocator, options.artifacts.artifact_set_id);
    for (options.artifacts.entries) |entry| {
        try bytes.append(allocator, ' ');
        try bytes.appendSlice(allocator, &entry.hash_hex);
    }
    try bytes.appendSlice(allocator, " -- ");
    try bytes.appendSlice(allocator, options.entrypoint.arg());
    for (options.entrypoint_args) |arg| {
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
    // Upload messages are shell-script lines: verify the local artifact hash,
    // base64 the bytes, and include the artifact id so the remote bootstrapper
    // can store it under a deterministic name.
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
    const bytes = try buildExecBytes(.{
        .allocator = std.testing.allocator,
        .artifacts = &artifacts,
        .entrypoint = .bridge,
        .entrypoint_args = &.{ "3.dev.test", "b64:literal" },
    });
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualStrings(
        "EXEC test-set 0000000000000000000000000000000000000000000000000000000000000000 -- sessh-bridge 3.dev.test b64:YjY0OmxpdGVyYWw=\n",
        bytes,
    );
}
