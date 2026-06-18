const std = @import("std");

pub const guid_body_len = 36;
pub const session_guid_prefix = "s-";
pub const proxy_guid_prefix = "p-";
pub const session_guid_len = session_guid_prefix.len + guid_body_len;
pub const proxy_guid_len = proxy_guid_prefix.len + guid_body_len;

fn isValidGuidBody(guid: []const u8) bool {
    if (guid.len != guid_body_len) return false;
    for (guid, 0..) |byte, i| {
        switch (i) {
            8, 13, 18, 23 => if (byte != '-') return false,
            else => if (!std.ascii.isHex(byte)) return false,
        }
    }
    return true;
}

pub fn isValidSessionGuid(guid: []const u8) bool {
    return std.mem.startsWith(u8, guid, session_guid_prefix) and
        isValidGuidBody(guid[session_guid_prefix.len..]);
}

pub fn isValidProxyGuid(guid: []const u8) bool {
    return std.mem.startsWith(u8, guid, proxy_guid_prefix) and
        isValidGuidBody(guid[proxy_guid_prefix.len..]);
}

pub fn isValidGuid(guid: []const u8) bool {
    return isValidSessionGuid(guid) or isValidProxyGuid(guid);
}

pub fn canonicalSessionGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (isValidSessionGuid(guid)) {
        const out = try allocator.alloc(u8, session_guid_len);
        out[0] = session_guid_prefix[0];
        out[1] = session_guid_prefix[1];
        for (guid[session_guid_prefix.len..], 0..) |byte, i| {
            out[session_guid_prefix.len + i] = std.ascii.toLower(byte);
        }
        return out;
    }
    return error.InvalidSessionId;
}

pub fn canonicalProxyGuid(allocator: std.mem.Allocator, guid: []const u8) ![]u8 {
    if (!isValidProxyGuid(guid)) return error.InvalidProxyId;
    const out = try allocator.alloc(u8, proxy_guid_len);
    out[0] = proxy_guid_prefix[0];
    out[1] = proxy_guid_prefix[1];
    for (guid[proxy_guid_prefix.len..], 0..) |byte, i| {
        out[proxy_guid_prefix.len + i] = std.ascii.toLower(byte);
    }
    return out;
}

pub fn generateSessionGuid(allocator: std.mem.Allocator) ![]u8 {
    return generatePrefixedUuid(allocator, session_guid_prefix);
}

pub fn generateProxyGuid(allocator: std.mem.Allocator) ![]u8 {
    return generatePrefixedUuid(allocator, proxy_guid_prefix);
}

fn generatePrefixedUuid(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const compact = std.fmt.bytesToHex(bytes, .lower);

    const out = try allocator.alloc(u8, prefix.len + guid_body_len);
    @memcpy(out[0..prefix.len], prefix);
    var src: usize = 0;
    for (out[prefix.len..], 0..) |*byte, i| {
        switch (i) {
            8, 13, 18, 23 => byte.* = '-',
            else => {
                byte.* = compact[src];
                src += 1;
            },
        }
    }
    return out;
}

test "validates session and proxy ids" {
    try std.testing.expect(isValidSessionGuid("s-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(isValidProxyGuid("p-550e8400-e29b-41d4-a716-446655440000"));
    const generated_session = try generateSessionGuid(std.testing.allocator);
    defer std.testing.allocator.free(generated_session);
    try std.testing.expect(isValidSessionGuid(generated_session));
    const generated_proxy = try generateProxyGuid(std.testing.allocator);
    defer std.testing.allocator.free(generated_proxy);
    try std.testing.expect(isValidProxyGuid(generated_proxy));
    try std.testing.expectError(error.InvalidSessionId, canonicalSessionGuid(std.testing.allocator, "550e8400e29b41d4a716446655440000"));
    try std.testing.expect(!isValidSessionGuid("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidSessionGuid("x-550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(!isValidSessionGuid(""));
    try std.testing.expect(!isValidSessionGuid("s1"));
    try std.testing.expect(!isValidSessionGuid("s-550e8400-e29b-41d4-a716-44665544000z"));
}
