const std = @import("std");

pub const id_width = 10;
pub const attached_width = 8;
pub const input_width = 8;
pub const host_width = 24;
pub const version_width = 12;
pub const ended_width = 8;
pub const status_width = 10;
pub const type_width = 16;
pub const created_width = 8;

pub fn writeHeader(writer: anytype) !void {
    try writePadded(writer, "ID", id_width);
    try writer.writeAll("  ");
    try writePadded(writer, "ATTACHED", attached_width);
    try writer.writeAll("  ");
    try writePadded(writer, "INPUT", input_width);
    try writer.writeAll("  ");
    try writePadded(writer, "HOST", host_width);
    try writer.writeAll("  ");
    try writer.writeAll("VERSION\n");
}

pub fn writeExitedHeader(writer: anytype) !void {
    try writePadded(writer, "ID", id_width);
    try writer.writeAll("  ");
    try writePadded(writer, "ENDED", ended_width);
    try writer.writeAll("  ");
    try writePadded(writer, "HOST", host_width);
    try writer.writeAll("  ");
    try writePadded(writer, "STATUS", status_width);
    try writer.writeAll("  ");
    try writer.writeAll("VERSION\n");
}

pub fn writeAllHeader(writer: anytype) !void {
    try writePadded(writer, "ID", id_width);
    try writer.writeAll("  ");
    try writePadded(writer, "TYPE", type_width);
    try writer.writeAll("  ");
    try writePadded(writer, "CREATED", created_width);
    try writer.writeAll("  ");
    try writer.writeAll("INFO\n");
}

pub fn writeRow(writer: anytype, id: []const u8, attached: []const u8, input: []const u8, host: []const u8, version: []const u8) !void {
    try writePadded(writer, id, id_width);
    try writer.writeAll("  ");
    try writePadded(writer, attached, attached_width);
    try writer.writeAll("  ");
    try writePadded(writer, input, input_width);
    try writer.writeAll("  ");
    try writePadded(writer, host, host_width);
    try writer.writeAll("  ");
    try writer.writeAll(if (version.len == 0) "???" else version);
    try writer.writeAll("\n");
}

pub fn writeExitedRow(writer: anytype, id: []const u8, ended: []const u8, host: []const u8, status: []const u8, version: []const u8) !void {
    try writePadded(writer, id, id_width);
    try writer.writeAll("  ");
    try writePadded(writer, ended, ended_width);
    try writer.writeAll("  ");
    try writePadded(writer, host, host_width);
    try writer.writeAll("  ");
    try writePadded(writer, status, status_width);
    try writer.writeAll("  ");
    try writer.writeAll(if (version.len == 0) "???" else version);
    try writer.writeAll("\n");
}

pub fn writeAllRow(writer: anytype, id: []const u8, type_name: []const u8, created: []const u8, info: []const u8) !void {
    try writePadded(writer, id, id_width);
    try writer.writeAll("  ");
    try writePadded(writer, type_name, type_width);
    try writer.writeAll("  ");
    try writePadded(writer, created, created_width);
    try writer.writeAll("  ");
    try writer.writeAll(info);
    try writer.writeAll("\n");
}

pub fn writeJsonlRow(writer: anytype, id: []const u8, host: []const u8, version: []const u8, guid: []const u8, attached_count: ?u32, last_input_at_unix_ms: ?u64) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"host\":");
    try writeJsonString(writer, host);
    try writer.writeAll(",\"version\":");
    try writeJsonString(writer, version);
    try writer.writeAll(",\"guid\":");
    try writeJsonString(writer, guid);
    try writer.writeAll(",\"attached_count\":");
    if (attached_count) |count| {
        try writer.print("{}", .{count});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"last_input_at_unix_ms\":");
    if (last_input_at_unix_ms) |ts| {
        try writer.print("{}", .{ts});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}\n");
}

pub fn writeAllJsonlRow(writer: anytype, id: []const u8, guid: []const u8, type_name: []const u8, created_at_unix_ms: ?u64, info: []const u8) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"guid\":");
    try writeJsonString(writer, guid);
    try writer.writeAll(",\"type\":");
    try writeJsonString(writer, type_name);
    try writer.writeAll(",\"created_at_unix_ms\":");
    if (created_at_unix_ms) |ts| {
        try writer.print("{}", .{ts});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"info\":");
    try writeJsonString(writer, info);
    try writer.writeAll("}\n");
}

pub const JsonExitStatus = struct {
    kind: []const u8,
    status: i32,
};

pub fn writeExitedJsonlRow(
    writer: anytype,
    id: []const u8,
    aliases: []const []const u8,
    host: []const u8,
    version: []const u8,
    guid: []const u8,
    ended_at_unix_ms: u64,
    end_reason: []const u8,
    exit_status: ?JsonExitStatus,
) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"aliases\":[");
    for (aliases, 0..) |alias, i| {
        if (i > 0) try writer.writeAll(",");
        try writeJsonString(writer, alias);
    }
    try writer.writeAll("],\"host\":");
    try writeJsonString(writer, host);
    try writer.writeAll(",\"version\":");
    try writeJsonString(writer, version);
    try writer.writeAll(",\"guid\":");
    try writeJsonString(writer, guid);
    try writer.writeAll(",\"ended_at_unix_ms\":");
    try writer.print("{}", .{ended_at_unix_ms});
    try writer.writeAll(",\"end_reason\":");
    try writeJsonString(writer, end_reason);
    try writer.writeAll(",\"exit_status\":");
    if (exit_status) |status| {
        try writer.writeAll("{\"kind\":");
        try writeJsonString(writer, status.kind);
        try writer.writeAll(",\"status\":");
        try writer.print("{}", .{status.status});
        try writer.writeAll("}");
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}\n");
}

pub fn writeKillJsonlRow(writer: anytype, guid: []const u8, status: []const u8, ended_at_unix_ms: ?u64, reason: []const u8) !void {
    try writer.writeAll("{\"guid\":");
    try writeJsonString(writer, guid);
    try writer.writeAll(",\"status\":");
    try writeJsonString(writer, status);
    try writer.writeAll(",\"ended_at_unix_ms\":");
    if (ended_at_unix_ms) |ts| {
        try writer.print("{}", .{ts});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"reason\":");
    try writeJsonString(writer, reason);
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
    attached: []const u8,
    input: []const u8,
    host: []const u8,
    version: []const u8,
};

pub fn parseRow(line: []const u8) ?Row {
    if (line.len < version_offset) return null;
    const id = std.mem.trim(u8, line[0..id_width], " \t\r");
    if (std.mem.eql(u8, id, "ID")) return null;
    const attached = std.mem.trim(u8, line[attached_offset .. attached_offset + attached_width], " \t\r");
    const input = std.mem.trim(u8, line[input_offset .. input_offset + input_width], " \t\r");
    const host = std.mem.trim(u8, line[host_offset .. host_offset + host_width], " \t\r");
    const version = std.mem.trim(u8, line[version_offset..], " \t\r");
    return .{
        .id = id,
        .attached = attached,
        .input = input,
        .host = host,
        .version = version,
    };
}

const attached_offset = id_width + 2;
const input_offset = attached_offset + attached_width + 2;
const host_offset = input_offset + input_width + 2;
const version_offset = host_offset + host_width + 2;

test "writeJsonlRow escapes fields" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try writeJsonlRow(out.writer(std.testing.allocator), "s1", "work\\host", "0.5\nx", "s-guid", 2, 1234);
    try std.testing.expectEqualStrings(
        "{\"id\":\"s1\",\"host\":\"work\\\\host\",\"version\":\"0.5\\nx\",\"guid\":\"s-guid\",\"attached_count\":2,\"last_input_at_unix_ms\":1234}\n",
        out.items,
    );
}

test "writeExitedJsonlRow writes tombstone fields" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try writeExitedJsonlRow(
        out.writer(std.testing.allocator),
        "s1",
        &.{ "s1", "old" },
        "work\\host",
        "0.5\nx",
        "s-guid",
        1234,
        "process_exited",
        .{ .kind = "exited", .status = 7 },
    );
    try std.testing.expectEqualStrings(
        "{\"id\":\"s1\",\"aliases\":[\"s1\",\"old\"],\"host\":\"work\\\\host\",\"version\":\"0.5\\nx\",\"guid\":\"s-guid\",\"ended_at_unix_ms\":1234,\"end_reason\":\"process_exited\",\"exit_status\":{\"kind\":\"exited\",\"status\":7}}\n",
        out.items,
    );
}

test "writeAllJsonlRow writes mixed runtime identity fields" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try writeAllJsonlRow(out.writer(std.testing.allocator), "c-12345678", "c-guid", "outgoing-client", 1234, "host=work\\host");
    try std.testing.expectEqualStrings(
        "{\"id\":\"c-12345678\",\"guid\":\"c-guid\",\"type\":\"outgoing-client\",\"created_at_unix_ms\":1234,\"info\":\"host=work\\\\host\"}\n",
        out.items,
    );
}

test "parseRow requires list columns" {
    try std.testing.expect(parseRow("s1 . 0.5.0-dev") == null);
    var buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(
        &buf,
        "{s:<10}  {s:<8}  {s:<8}  {s:<24}  {s}",
        .{ "s1", "1", "2s ago", ".", "0.5.0-dev" },
    );
    const row = parseRow(line) orelse return error.MissingRow;
    try std.testing.expectEqualStrings("s1", row.id);
    try std.testing.expectEqualStrings("1", row.attached);
    try std.testing.expectEqualStrings("2s ago", row.input);
    try std.testing.expectEqualStrings(".", row.host);
    try std.testing.expectEqualStrings("0.5.0-dev", row.version);
}
