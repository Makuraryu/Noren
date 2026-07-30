const std = @import("std");

pub const Config = struct {
    server: Server = .{},
    session: Session = .{},
    workspace: Workspace = .{},
    pane: Pane = .{},
    input: Input = .{},
    render: Render = .{},
    status: Status = .{},
    security: Security = .{},
    resources: Resources = .{},

    pub const Server = struct {
        socket_name: []const u8 = "default",
        exit_empty: bool = true,
    };

    pub const Session = struct {
        destroy_unattached: bool = false,
        exit_on_last_pane: bool = true,
    };

    pub const Workspace = struct {
        gap: u16 = 0,
        reveal_margin: u16 = 0,
    };

    pub const Pane = struct {
        default_width: u16 = 80,
        min_outer_width: u16 = 3,
        max_outer_width: u16 = 4096,
        scrollback_lines: u32 = 10_000,
    };

    pub const Input = struct {
        prefix: []const u8 = "C-b",
        send_prefix: []const u8 = "C-b",
        escape_timeout_ms: u16 = 10,
        prefix_timeout_ms: u16 = 1000,
    };

    pub const Render = struct {
        max_fps: u16 = 60,
    };

    pub const Status = struct {
        enabled: bool = true,
        height: u16 = 1,
        format: []const u8 = "{time} {session} {workspace}:{pane}",
    };

    pub const Security = struct {
        allow_osc52: bool = false,
        max_control_string_bytes: usize = 1024 * 1024,
    };

    pub const Resources = struct {
        max_sessions: usize = 64,
        max_workspaces_per_session: usize = 128,
        max_panes_per_session: usize = 256,
        max_clients: usize = 32,
        client_outbound_bytes: usize = 4 * 1024 * 1024,
        pane_input_bytes: usize = 1024 * 1024,
        frame_payload_bytes: usize = 16 * 1024 * 1024,
    };

    pub fn validate(self: Config) !void {
        if (self.server.socket_name.len == 0 or self.server.socket_name.len > 64) {
            return error.InvalidSocketName;
        }
        for (self.server.socket_name) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') {
                return error.InvalidSocketName;
            }
        }
        if (self.workspace.reveal_margin != 0) return error.RevealMarginMustBeZero;
        if (self.pane.min_outer_width < 3) return error.InvalidMinimumPaneWidth;
        if (self.pane.max_outer_width < self.pane.min_outer_width or
            self.pane.max_outer_width > 16_384)
        {
            return error.InvalidMaximumPaneWidth;
        }
        if (self.pane.default_width < self.pane.min_outer_width or
            self.pane.default_width > self.pane.max_outer_width)
        {
            return error.InvalidDefaultPaneWidth;
        }
        if (self.pane.scrollback_lines > 1_000_000) return error.ScrollbackLimitTooHigh;
        if (self.input.escape_timeout_ms == 0 or self.input.prefix_timeout_ms == 0) {
            return error.InvalidInputTimeout;
        }
        if (self.render.max_fps == 0 or self.render.max_fps > 240) {
            return error.InvalidFrameRate;
        }
        if (self.status.height > 16) return error.StatusTooTall;
        if (self.security.max_control_string_bytes == 0 or
            self.security.max_control_string_bytes > 16 * 1024 * 1024)
        {
            return error.InvalidControlStringLimit;
        }
        if (self.resources.max_sessions == 0 or
            self.resources.max_workspaces_per_session == 0 or
            self.resources.max_panes_per_session == 0 or
            self.resources.max_clients == 0)
        {
            return error.InvalidResourceLimit;
        }
        if (self.resources.frame_payload_bytes == 0 or
            self.resources.frame_payload_bytes > 16 * 1024 * 1024)
        {
            return error.InvalidFrameLimit;
        }
    }
};

test "default configuration preserves product invariants" {
    const config: Config = .{};
    try config.validate();
    try std.testing.expectEqual(@as(u16, 0), config.workspace.gap);
    try std.testing.expectEqual(@as(u16, 0), config.workspace.reveal_margin);
    try std.testing.expectEqual(@as(u16, 3), config.pane.min_outer_width);
}

test "configuration rejects non-zero reveal margin" {
    var config: Config = .{};
    config.workspace.reveal_margin = 1;
    try std.testing.expectError(error.RevealMarginMustBeZero, config.validate());
}
