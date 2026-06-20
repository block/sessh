const std = @import("std");

pub fn main() !void {
    // Build-time helper: write the bootstrap artifact manifest consumed by
    // sessh's remote installer. Each row binds an artifact filename to the hash
    // the client will verify before upload/use.
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2 or (args.len - 2) % 2 != 0) return error.InvalidArgs;

    var output = try createOutputFile(args[1]);
    defer output.close();

    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        const filename = args[i];
        const artifact_path = args[i + 1];
        const artifact_hash = try sha256FileHex(artifact_path);

        var line_buf: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buf,
            "{s} {s}\n",
            .{ filename, &artifact_hash },
        );
        try output.writeAll(line);
    }
}

fn sha256FileHex(path: []const u8) ![64]u8 {
    var file = try openInputFile(path);
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn openInputFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, .{});
    }
    return std.fs.cwd().openFile(path, .{});
}

fn createOutputFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, .{ .truncate = true });
    }
    return std.fs.cwd().createFile(path, .{ .truncate = true });
}
