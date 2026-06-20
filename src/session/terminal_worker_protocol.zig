const std = @import("std");

const protocol = @import("../protocol/mod.zig");

const pb = protocol.pb;

pub const PendingClientFrame = union(enum) {
    continue_reading,
    transport_control: protocol.TransportControl,
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
) !PendingClientFrame {
    // A pending client has not proven whether it is opening a session, resizing
    // one, or sending transport control. Decode only enough to route the first
    // meaningful action.
    switch (frame.message_type) {
        .daemon_tunnel => {
            return if (try protocol.decodeTransportControlFrame(allocator, frame.message_type, frame.payload)) |control|
                .{ .transport_control = control }
            else
                .continue_reading;
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
    var decoded = try decodePendingClientFrame(allocator, &frame);
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
    var decoded = try decodePendingClientFrame(allocator, &frame);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(PendingClientFrame.unexpected_first_action, decoded);
}

test "pending client protocol decodes transport control without writing" {
    const allocator = std.testing.allocator;
    const payload = try protocol.encodeDaemonTunnelPayload(allocator, .{ .ping = .{} });
    defer allocator.free(payload);

    var frame = protocol.OwnedFrame{
        .message_type = .daemon_tunnel,
        .payload = payload,
    };
    var decoded = try decodePendingClientFrame(allocator, &frame);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(PendingClientFrame{ .transport_control = .ping }, decoded);
}
