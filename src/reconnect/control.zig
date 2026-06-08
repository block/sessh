pub const ctrl_c: u8 = 0x03;
pub const ctrl_r: u8 = 0x12;

pub const InputAction = enum {
    none,
    reconnect_now,
};

pub const ScanOptions = struct {};

/// Interprets local reconnect UI control keys. Callers decide when reconnect UI
/// is active; outside that window these bytes should continue to mean whatever
/// the remote program normally does with them.
pub fn scanInput(bytes: []const u8, options: ScanOptions) InputAction {
    _ = options;
    for (bytes) |byte| {
        if (byte == ctrl_r) return .reconnect_now;
    }
    return .none;
}

test "scanInput recognizes reconnect controls only when requested" {
    try @import("std").testing.expectEqual(InputAction.none, scanInput("abc", .{}));
    try @import("std").testing.expectEqual(InputAction.reconnect_now, scanInput(&.{ctrl_r}, .{}));
    try @import("std").testing.expectEqual(InputAction.none, scanInput(&.{ctrl_c}, .{}));
}
