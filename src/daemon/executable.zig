const std = @import("std");
const posix = std.posix;

pub fn daemonPathFor(allocator: std.mem.Allocator, exe: []const u8) ![]u8 {
    if (!std.mem.eql(u8, std.fs.path.basename(exe), "sessh")) {
        return allocator.dupe(u8, exe);
    }

    const dir = std.fs.path.dirname(exe) orelse return allocator.dupe(u8, exe);
    const candidate = try std.fs.path.join(allocator, &.{ dir, "sesshd" });
    errdefer allocator.free(candidate);
    posix.access(candidate, posix.X_OK) catch {
        allocator.free(candidate);
        return allocator.dupe(u8, exe);
    };
    return candidate;
}

test "daemon path prefers sibling sesshd for packaged sessh executable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var sessh = try tmp.dir.createFile("sessh", .{ .mode = 0o700 });
    sessh.close();
    var sesshd = try tmp.dir.createFile("sesshd", .{ .mode = 0o700 });
    sesshd.close();

    const tmp_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const sessh_path = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "sessh" });
    defer std.testing.allocator.free(sessh_path);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ tmp_path, "sesshd" });
    defer std.testing.allocator.free(expected);

    const actual = try daemonPathFor(std.testing.allocator, sessh_path);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "daemon path leaves development executable unchanged" {
    const actual = try daemonPathFor(std.testing.allocator, "/tmp/sessh-dev");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("/tmp/sessh-dev", actual);
}
