const std = @import("std");

pub const id_width = 8;
pub const host_width = 24;
pub const version_width = 12;

pub fn writeHeader(writer: anytype) !void {
    try writePadded(writer, "ID", id_width);
    try writer.writeAll("  ");
    try writePadded(writer, "HOST", host_width);
    try writer.writeAll("  ");
    try writePadded(writer, "VERSION", version_width);
    try writer.writeAll("  GUID\n");
}

pub fn writeRow(writer: anytype, id: []const u8, host: []const u8, version: []const u8, guid: []const u8) !void {
    try writePadded(writer, id, id_width);
    try writer.writeAll("  ");
    try writePadded(writer, host, host_width);
    try writer.writeAll("  ");
    try writePadded(writer, if (version.len == 0) "???" else version, version_width);
    try writer.writeAll("  ");
    try writer.writeAll(guid);
    try writer.writeAll("\n");
}

pub fn writeJsonlRow(writer: anytype, id: []const u8, host: []const u8, version: []const u8, guid: []const u8) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"host\":");
    try writeJsonString(writer, host);
    try writer.writeAll(",\"version\":");
    try writeJsonString(writer, version);
    try writer.writeAll(",\"guid\":");
    try writeJsonString(writer, guid);
    try writer.writeAll("}\n");
}

fn writePadded(writer: anytype, value: []const u8, width: usize) !void {
    try writer.writeAll(value);
    var i = value.len;
    while (i < width) : (i += 1) {
        try writer.writeAll(" ");
    }
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeAll("\"");
}

pub const Row = struct {
    id: []const u8,
    host: []const u8,
    version: []const u8,
    guid: []const u8,
};

pub fn parseRow(line: []const u8) ?Row {
    var fields = std.mem.tokenizeAny(u8, line, " \t\r");
    const id = fields.next() orelse return null;
    if (std.mem.eql(u8, id, "ID")) return null;
    const host = fields.next() orelse return null;
    const version = fields.next() orelse return null;
    const guid = fields.next() orelse return null;
    return .{
        .id = id,
        .host = host,
        .version = version,
        .guid = guid,
    };
}

test "writeJsonlRow escapes fields" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try writeJsonlRow(out.writer(std.testing.allocator), "s1", "work\\host", "0.5\nx", "s-guid");
    try std.testing.expectEqualStrings(
        "{\"id\":\"s1\",\"host\":\"work\\\\host\",\"version\":\"0.5\\nx\",\"guid\":\"s-guid\"}\n",
        out.items,
    );
}

test "parseRow requires version column" {
    try std.testing.expect(parseRow("s1 . s-guid") == null);
    const row = parseRow("s1 . 0.5.0-dev s-guid") orelse return error.MissingRow;
    try std.testing.expectEqualStrings("s1", row.id);
    try std.testing.expectEqualStrings(".", row.host);
    try std.testing.expectEqualStrings("0.5.0-dev", row.version);
    try std.testing.expectEqualStrings("s-guid", row.guid);
}
