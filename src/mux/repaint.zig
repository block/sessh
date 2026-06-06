const mux_cli = @import("cli.zig");
const mux_client_control = @import("client_control.zig");

pub fn parse(scratch: *mux_cli.Scratch, args: []const []const u8) !mux_cli.ClientControl {
    return mux_client_control.parse(scratch, args, true, null);
}
