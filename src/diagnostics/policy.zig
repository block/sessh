const std = @import("std");

const config = @import("../core/config.zig");
const client_ui = @import("../session/client_ui.zig");
const stream_runtime = @import("../stream/runtime.zig");

pub fn terminalPresentation(
    filter_level: config.FilterLevel,
    diagnostics_level: config.DiagnosticsLevel,
    diagnostics_output_is_tty: bool,
) client_ui.ReconnectPresentation {
    if (diagnostics_level == .jsonl) return .jsonl;
    if (!diagnostics_output_is_tty) return .stderr_plain;
    return switch (diagnostics_level) {
        .jsonl => unreachable,
        .line => .stderr_plain,
        .title => .title,
        .status => switch (filter_level) {
            .unhygienic => .none,
            .hygienic, .emulated => .title,
        },
        .overlay => switch (filter_level) {
            .unhygienic => .none,
            .hygienic => .title,
            .emulated => .overlay,
        },
    };
}

pub fn streamStatusMode(
    filter_level: config.FilterLevel,
    diagnostics_level: config.DiagnosticsLevel,
    has_daemon_control: bool,
    diagnostics_output_is_tty: bool,
) stream_runtime.StreamReconnectStatusMode {
    if (diagnostics_level == .jsonl) return .jsonl;
    if (!diagnostics_output_is_tty) return .stderr_plain;
    if (diagnostics_level == .line) return .stderr_plain;
    if (diagnostics_level == .title) return .title;
    if (has_daemon_control) return .client_control;
    return switch (filter_level) {
        .unhygienic => .disabled,
        .hygienic, .emulated => .status_line,
    };
}

test "stream status mode follows diagnostics level" {
    try std.testing.expectEqual(stream_runtime.StreamReconnectStatusMode.jsonl, streamStatusMode(.emulated, .jsonl, true, true));
    try std.testing.expectEqual(stream_runtime.StreamReconnectStatusMode.stderr_plain, streamStatusMode(.emulated, .line, true, true));
    try std.testing.expectEqual(stream_runtime.StreamReconnectStatusMode.stderr_plain, streamStatusMode(.emulated, .overlay, true, false));
    try std.testing.expectEqual(stream_runtime.StreamReconnectStatusMode.title, streamStatusMode(.hygienic, .title, true, true));
    try std.testing.expectEqual(stream_runtime.StreamReconnectStatusMode.client_control, streamStatusMode(.emulated, .overlay, true, true));
    try std.testing.expectEqual(stream_runtime.StreamReconnectStatusMode.status_line, streamStatusMode(.emulated, .overlay, false, true));
    try std.testing.expectEqual(stream_runtime.StreamReconnectStatusMode.status_line, streamStatusMode(.hygienic, .status, false, true));
}

test "terminal presentation follows diagnostics level" {
    try std.testing.expectEqual(
        client_ui.ReconnectPresentation.overlay,
        terminalPresentation(.emulated, .overlay, true),
    );
    try std.testing.expectEqual(
        client_ui.ReconnectPresentation.title,
        terminalPresentation(.emulated, .status, true),
    );
    try std.testing.expectEqual(
        client_ui.ReconnectPresentation.title,
        terminalPresentation(.hygienic, .overlay, true),
    );
    try std.testing.expectEqual(
        client_ui.ReconnectPresentation.stderr_plain,
        terminalPresentation(.emulated, .overlay, false),
    );
    try std.testing.expectEqual(
        client_ui.ReconnectPresentation.jsonl,
        terminalPresentation(.emulated, .jsonl, false),
    );
}
