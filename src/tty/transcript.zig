const std = @import("std");
const c = std.c;
const posix = std.posix;

const config = @import("../core/config.zig");
const io = @import("../core/io.zig");
const process_exit = @import("../core/process_exit.zig");

pub const Stream = enum {
    outer_in,
    outer_out,
    inner_in,
    inner_out,
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    started_at_unix_ms: u64,
    session_guid: std.ArrayList(u8) = .empty,
    outer_in: std.ArrayList(u8) = .empty,
    outer_out: std.ArrayList(u8) = .empty,
    inner_in: std.ArrayList(u8) = .empty,
    inner_out: std.ArrayList(u8) = .empty,
    record_error: ?anyerror = null,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Recorder {
        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
            .started_at_unix_ms = nowUnixMs(),
        };
    }

    pub fn deinit(self: *Recorder) void {
        self.allocator.free(self.path);
        self.session_guid.deinit(self.allocator);
        self.outer_in.deinit(self.allocator);
        self.outer_out.deinit(self.allocator);
        self.inner_in.deinit(self.allocator);
        self.inner_out.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn warnEnabled(self: *const Recorder) !void {
        try io.writeAll(posix.STDERR_FILENO, "sessh: WARNING: tty transcript capture is enabled.\r\n");
        try io.writeAll(posix.STDERR_FILENO, "sessh: WARNING: captured data may include passwords, tokens, pasted text, private keys, terminal output, and command history.\r\n");
        try io.writeAll(posix.STDERR_FILENO, "sessh: WARNING: transcript bytes are buffered in memory and written only on clean exit to: ");
        try io.writeAll(posix.STDERR_FILENO, self.path);
        try io.writeAll(posix.STDERR_FILENO, "\r\n");
    }

    pub fn record(self: *Recorder, stream: Stream, bytes: []const u8) void {
        if (bytes.len == 0 or self.record_error != null or self.finished) return;
        const target = switch (stream) {
            .outer_in => &self.outer_in,
            .outer_out => &self.outer_out,
            .inner_in => &self.inner_in,
            .inner_out => &self.inner_out,
        };
        target.appendSlice(self.allocator, bytes) catch |err| {
            self.record_error = err;
        };
    }

    pub fn setSessionGuid(self: *Recorder, guid: []const u8) void {
        if (self.record_error != null) return;
        self.session_guid.clearRetainingCapacity();
        self.session_guid.appendSlice(self.allocator, guid) catch |err| {
            self.record_error = err;
        };
    }

    pub fn finish(self: *Recorder) !void {
        if (self.finished) return;
        if (self.record_error) |err| return err;

        const manifest = try self.manifestJson();
        defer self.allocator.free(manifest);

        const tar_bytes = try self.tarBytes(manifest);
        defer self.allocator.free(tar_bytes);

        try writeGzipFile(self.path, tar_bytes);
        self.finished = true;
    }

    fn manifestJson(self: *const Recorder) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        try out.appendSlice(self.allocator, "{\n");
        const json = JsonManifestWriter{ .out = &out, .allocator = self.allocator };
        try json.appendNumber(.{ .key = "format_version", .value = 1, .trailing_comma = true });
        try json.appendNumber(.{ .key = "started_at_unix_ms", .value = self.started_at_unix_ms, .trailing_comma = true });
        try json.appendString(.{ .key = "sessh_version", .value = config.version, .trailing_comma = true });
        try json.appendNumber(.{ .key = "protocol_major", .value = config.protocol_major, .trailing_comma = true });
        try json.appendNumber(.{ .key = "protocol_minor", .value = config.protocol_minor, .trailing_comma = true });
        if (self.session_guid.items.len > 0) {
            try json.appendString(.{ .key = "session_guid", .value = self.session_guid.items, .trailing_comma = true });
        }
        try out.appendSlice(self.allocator, "  \"streams\": {\n");
        try appendStreamManifest(&out, self.allocator, .{
            .filename = "outer.in.bin",
            .direction = "outer-to-client",
            .byte_count = self.outer_in.items.len,
            .comma = true,
        });
        try appendStreamManifest(&out, self.allocator, .{
            .filename = "outer.out.bin",
            .direction = "client-to-outer",
            .byte_count = self.outer_out.items.len,
            .comma = true,
        });
        try appendStreamManifest(&out, self.allocator, .{
            .filename = "inner.in.bin",
            .direction = "worker-to-pty",
            .byte_count = self.inner_in.items.len,
            .comma = true,
        });
        try appendStreamManifest(&out, self.allocator, .{
            .filename = "inner.out.bin",
            .direction = "pty-to-worker",
            .byte_count = self.inner_out.items.len,
            .comma = false,
        });
        try out.appendSlice(self.allocator, "  }\n");
        try out.appendSlice(self.allocator, "}\n");
        return out.toOwnedSlice(self.allocator);
    }

    fn tarBytes(self: *const Recorder, manifest: []const u8) ![]u8 {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();

        var tar_writer = std.tar.Writer{
            .underlying_writer = &writer.writer,
            .mtime_now = @divTrunc(self.started_at_unix_ms, 1000),
        };
        const options = std.tar.Writer.Options{
            .mode = 0o600,
            .mtime = @divTrunc(self.started_at_unix_ms, 1000),
        };
        try tar_writer.writeFileBytes("manifest.json", manifest, options);
        try tar_writer.writeFileBytes("outer.in.bin", self.outer_in.items, options);
        try tar_writer.writeFileBytes("outer.out.bin", self.outer_out.items, options);
        try tar_writer.writeFileBytes("inner.in.bin", self.inner_in.items, options);
        try tar_writer.writeFileBytes("inner.out.bin", self.inner_out.items, options);
        try tar_writer.finishPedantically();

        return writer.toOwnedSlice();
    }
};

var active_recorder: ?*Recorder = null;

pub fn activate(recorder: *Recorder) void {
    active_recorder = recorder;
    io.setReadHook(recordReadHook);
    io.setWriteHook(recordWriteHook);
}

pub fn deactivate() void {
    io.setReadHook(null);
    io.setWriteHook(null);
    active_recorder = null;
}

pub fn enabled() bool {
    return active_recorder != null;
}

fn recordOuterIn(bytes: []const u8) void {
    if (active_recorder) |recorder| recorder.record(.outer_in, bytes);
}

pub fn recordInnerIn(bytes: []const u8) void {
    if (active_recorder) |recorder| recorder.record(.inner_in, bytes);
}

pub fn recordInnerOut(bytes: []const u8) void {
    if (active_recorder) |recorder| recorder.record(.inner_out, bytes);
}

pub fn setSessionGuid(guid: []const u8) void {
    if (active_recorder) |recorder| recorder.setSessionGuid(guid);
}

fn finishActive() !void {
    if (active_recorder) |recorder| try recorder.finish();
}

pub fn finishActiveOrReport() !void {
    finishActive() catch |err| {
        try io.stderrPrint("sessh: failed to write tty transcript: {t}\n", .{err});
        return process_exit.request(1);
    };
}

fn recordReadHook(fd: c.fd_t, bytes: []const u8) void {
    if (fd == 0) recordOuterIn(bytes);
}

fn recordWriteHook(fd: c.fd_t, bytes: []const u8) void {
    if (fd == 1) {
        if (active_recorder) |recorder| recorder.record(.outer_out, bytes);
    }
}

const JsonManifestWriter = struct {
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn appendNumber(self: JsonManifestWriter, options: anytype) !void {
        try self.out.appendSlice(self.allocator, "  ");
        try appendJsonString(self.out, self.allocator, options.key);
        try self.out.appendSlice(self.allocator, ": ");
        try self.out.writer(self.allocator).print("{}", .{options.value});
        try self.out.appendSlice(self.allocator, if (options.trailing_comma) ",\n" else "\n");
    }

    const StringField = struct {
        key: []const u8,
        value: []const u8,
        trailing_comma: bool,
    };

    fn appendString(self: JsonManifestWriter, field: StringField) !void {
        try self.out.appendSlice(self.allocator, "  ");
        try appendJsonString(self.out, self.allocator, field.key);
        try self.out.appendSlice(self.allocator, ": ");
        try appendJsonString(self.out, self.allocator, field.value);
        try self.out.appendSlice(self.allocator, if (field.trailing_comma) ",\n" else "\n");
    }
};

const StreamManifestEntry = struct {
    filename: []const u8,
    direction: []const u8,
    byte_count: usize,
    comma: bool,
};

fn appendStreamManifest(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    entry: StreamManifestEntry,
) !void {
    try out.appendSlice(allocator, "    ");
    try appendJsonString(out, allocator, entry.filename);
    try out.appendSlice(allocator, ": { \"direction\": ");
    try appendJsonString(out, allocator, entry.direction);
    try out.appendSlice(allocator, ", \"bytes\": ");
    try out.writer(allocator).print("{}", .{entry.byte_count});
    try out.appendSlice(allocator, if (entry.comma) " },\n" else " }\n");
}

fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                try out.appendSlice(allocator, "\\u00");
                try out.append(allocator, hexDigit(byte >> 4));
                try out.append(allocator, hexDigit(byte & 0x0f));
            },
            else => try out.append(allocator, byte),
        }
    }
    try out.append(allocator, '"');
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

fn writeGzipFile(path: []const u8, bytes: []const u8) !void {
    var file = try createArchiveFile(path);
    var keep_file = false;
    defer file.close();
    errdefer if (!keep_file) deleteArchiveFile(path) catch {};

    try file.writeAll(&[_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff });

    var crc = std.hash.Crc32.init();
    crc.update(bytes);

    var offset: usize = 0;
    while (true) {
        const remaining = bytes.len - offset;
        const chunk_len = @min(remaining, 0xffff);
        const final = offset + chunk_len == bytes.len;
        var header: [5]u8 = undefined;
        header[0] = if (final) 0x01 else 0x00;
        writeU16Le(header[1..3], @intCast(chunk_len));
        writeU16Le(header[3..5], ~@as(u16, @intCast(chunk_len)));
        try file.writeAll(&header);
        try file.writeAll(bytes[offset .. offset + chunk_len]);
        offset += chunk_len;
        if (final) break;
    }

    var footer: [8]u8 = undefined;
    writeU32Le(footer[0..4], crc.final());
    writeU32Le(footer[4..8], @truncate(bytes.len));
    try file.writeAll(&footer);
    keep_file = true;
}

fn createArchiveFile(path: []const u8) !std.fs.File {
    const flags = std.fs.File.CreateFlags{
        .truncate = true,
        .exclusive = true,
        .mode = 0o600,
    };
    if (std.fs.path.isAbsolute(path)) return std.fs.createFileAbsolute(path, flags);
    return std.fs.cwd().createFile(path, flags);
}

fn deleteArchiveFile(path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) return std.fs.deleteFileAbsolute(path);
    return std.fs.cwd().deleteFile(path);
}

fn writeU16Le(bytes: []u8, value: u16) void {
    bytes[0] = @intCast(value & 0xff);
    bytes[1] = @intCast((value >> 8) & 0xff);
}

fn writeU32Le(bytes: []u8, value: u32) void {
    bytes[0] = @intCast(value & 0xff);
    bytes[1] = @intCast((value >> 8) & 0xff);
    bytes[2] = @intCast((value >> 16) & 0xff);
    bytes[3] = @intCast((value >> 24) & 0xff);
}

fn nowUnixMs() u64 {
    return @intCast(std.time.milliTimestamp());
}

test "json string escaping handles control bytes" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try appendJsonString(&out, std.testing.allocator, "a\"b\\\n\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\\\n\\u0001\"", out.items);
}
