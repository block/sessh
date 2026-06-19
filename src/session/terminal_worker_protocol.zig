const std = @import("std");
const c = std.c;

const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;

pub const PendingClientFrame = union(enum) {
    continue_reading,
    terminal_item: pb.TerminalEmulatorItem,
    unexpected_empty_terminal_item,
    unexpected_first_terminal_item,
    unexpected_first_action,

    pub fn deinit(self: *PendingClientFrame, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .terminal_item => |*item| item.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

pub const FirstTerminalItemKind = enum {
    resize,
    open,
    debug_sever_connection_request,
    debug_unresponsive_connection_request,
    session_hangup_request,
    unexpected,
};

pub fn decodePendingClientFrame(
    allocator: std.mem.Allocator,
    frame: *const protocol.OwnedFrame,
    control_fd: c.fd_t,
) !PendingClientFrame {
    switch (frame.message_type) {
        .daemon_tunnel => {
            _ = try protocol.handleTransportControlFrame(frame.message_type, frame.payload, control_fd);
            return .continue_reading;
        },
        .client_remote => {
            var item = try protocol.decodeClientRemoteTerminalEmulatorItem(allocator, frame.payload);
            errdefer item.deinit(allocator);
            if (item.payload == null) return .unexpected_empty_terminal_item;
            return .{ .terminal_item = item };
        },
        else => return .unexpected_first_action,
    }
}

pub fn classifyFirstTerminalItem(item: *const pb.TerminalEmulatorItem) FirstTerminalItemKind {
    return switch (item.payload orelse return .unexpected) {
        .resize => .resize,
        .open => .open,
        .debug_sever_connection_request => .debug_sever_connection_request,
        .debug_unresponsive_connection_request => .debug_unresponsive_connection_request,
        .session_hangup_request => .session_hangup_request,
        else => .unexpected,
    };
}

test "pending client protocol decodes terminal open item" {
    const allocator = std.testing.allocator;
    const item_payload = try protocol.encodeTerminalEmulatorItemPayload(allocator, .{ .payload = .{ .open = .{
        .session_guid = "s-11111111-1111-4111-8111-111111111111",
        .resize = .{ .terminal_rows = 24, .terminal_cols = 80 },
    } } });
    defer allocator.free(item_payload);

    var frame = protocol.OwnedFrame{
        .message_type = .client_remote,
        .payload = item_payload,
    };
    var decoded = try decodePendingClientFrame(allocator, &frame, -1);
    defer decoded.deinit(allocator);

    switch (decoded) {
        .terminal_item => |*item| try std.testing.expectEqual(FirstTerminalItemKind.open, classifyFirstTerminalItem(item)),
        else => return error.ExpectedTerminalItem,
    }
}

test "pending client protocol rejects non terminal first action" {
    const allocator = std.testing.allocator;
    const payload = try protocol.encodeClientDaemonPayload(allocator, .{ .retry_now = .{} });
    defer allocator.free(payload);

    var frame = protocol.OwnedFrame{
        .message_type = .client_daemon,
        .payload = payload,
    };
    var decoded = try decodePendingClientFrame(allocator, &frame, -1);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(PendingClientFrame.unexpected_first_action, decoded);
}
