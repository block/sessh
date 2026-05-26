const std = @import("std");

pub const id_width = 8;
pub const host_width = 24;

pub fn writeHeader(writer: anytype) !void {
    try writePadded(writer, "ID", id_width);
    try writer.writeAll("  ");
    try writePadded(writer, "HOST", host_width);
    try writer.writeAll("  GUID\n");
}

pub fn writeRow(writer: anytype, id: []const u8, host: []const u8, guid: []const u8) !void {
    try writePadded(writer, id, id_width);
    try writer.writeAll("  ");
    try writePadded(writer, host, host_width);
    try writer.writeAll("  ");
    try writer.writeAll(guid);
    try writer.writeAll("\n");
}

fn writePadded(writer: anytype, value: []const u8, width: usize) !void {
    try writer.writeAll(value);
    var i = value.len;
    while (i < width) : (i += 1) {
        try writer.writeAll(" ");
    }
}

pub const Row = struct {
    id: []const u8,
    host: []const u8,
    guid: []const u8,
};

pub fn parseRow(line: []const u8) ?Row {
    var fields = std.mem.tokenizeAny(u8, line, " \t\r");
    const id = fields.next() orelse return null;
    if (std.mem.eql(u8, id, "ID")) return null;
    const host = fields.next() orelse return null;
    const guid = fields.next() orelse return null;
    return .{
        .id = id,
        .host = host,
        .guid = guid,
    };
}
