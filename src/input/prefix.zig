const std = @import("std");

pub const State = enum {
    normal,
    awaiting_command,
    adjusting,
    awaiting_escape,
    awaiting_csi,
};

pub const Result = union(enum) {
    forward: u8,
    command: Command,
    wait,
    rejected: u8,
};

pub const Command = enum {
    new_pane,
    close_pane,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    scroll_left,
    scroll_right,
    resize_narrower,
    resize_wider,
    new_workspace,
    rename_session,
    detach,
    sessions,
    command_prompt,
    reload,
    send_prefix,
    dismiss_prefix,
};

pub const Router = struct {
    state: State = .normal,
    prefix_byte: u8 = 0x02,

    pub fn menuActive(self: *const Router) bool {
        return self.state != .normal;
    }

    pub fn feed(self: *Router, byte: u8) Result {
        switch (self.state) {
            .normal => {
                if (byte == self.prefix_byte) {
                    self.state = .awaiting_command;
                    return .wait;
                }
                return .{ .forward = byte };
            },
            .awaiting_command => {
                if (byte == 0x1b) {
                    self.state = .awaiting_escape;
                    return .wait;
                }
                self.state = .normal;
                if (byte == self.prefix_byte) return .{ .command = .send_prefix };
                if (isContinuousCommand(byte)) {
                    self.state = .adjusting;
                }
                return mapCommand(byte);
            },
            .adjusting => {
                if (isContinuousCommand(byte)) return mapCommand(byte);
                if (byte == self.prefix_byte) {
                    self.state = .normal;
                    return .{ .command = .dismiss_prefix };
                }
                if (byte == 0x1b) {
                    self.state = .awaiting_escape;
                    return .wait;
                }
                self.state = .normal;
                return mapCommand(byte);
            },
            .awaiting_escape => {
                if (byte == '[') {
                    self.state = .awaiting_csi;
                    return .wait;
                }
                self.state = .normal;
                return .{ .rejected = byte };
            },
            .awaiting_csi => {
                self.state = .normal;
                return .{ .command = switch (byte) {
                    'A' => .focus_up,
                    'B' => .focus_down,
                    'C' => .focus_right,
                    'D' => .focus_left,
                    else => return .{ .rejected = byte },
                } };
            },
        }
    }

    pub fn timeout(self: *Router) void {
        self.state = .normal;
    }
};

fn mapCommand(byte: u8) Result {
    return .{ .command = switch (byte) {
        'c' => .new_pane,
        'x' => .close_pane,
        'h' => .scroll_left,
        'l' => .scroll_right,
        'k' => .focus_up,
        'j' => .focus_down,
        '[' => .resize_narrower,
        ']' => .resize_wider,
        'n' => .new_workspace,
        ',' => .rename_session,
        'd' => .detach,
        's' => .sessions,
        ':' => .command_prompt,
        'r' => .reload,
        else => return .{ .rejected = byte },
    } };
}

fn isContinuousCommand(byte: u8) bool {
    return byte == '[' or byte == ']' or byte == 'h' or byte == 'l';
}

test "prefix router forwards ordinary bytes and maps commands" {
    var router: Router = .{};
    try std.testing.expectEqual(@as(u8, 'a'), router.feed('a').forward);
    try std.testing.expect(router.feed(0x02) == .wait);
    try std.testing.expect(router.feed('c').command == .new_pane);
    try std.testing.expect(router.feed(0x02) == .wait);
    try std.testing.expect(router.feed(0x02).command == .send_prefix);
    try std.testing.expect(router.feed(0x02) == .wait);
    try std.testing.expect(router.feed(0x1b) == .wait);
    try std.testing.expect(router.feed('[') == .wait);
    try std.testing.expect(router.feed('C').command == .focus_right);
    try std.testing.expect(router.feed(0x02) == .wait);
    try std.testing.expect(router.feed(',').command == .rename_session);
}

test "pane resize keys remain active until dismissed or another command" {
    var router: Router = .{};

    try std.testing.expect(router.feed(0x02) == .wait);
    try std.testing.expect(router.menuActive());
    try std.testing.expect(router.feed('[').command == .resize_narrower);
    try std.testing.expect(router.menuActive());
    try std.testing.expect(router.feed('[').command == .resize_narrower);
    try std.testing.expect(router.feed(']').command == .resize_wider);
    try std.testing.expect(router.menuActive());
    try std.testing.expect(router.feed(0x02).command == .dismiss_prefix);
    try std.testing.expect(!router.menuActive());

    try std.testing.expect(router.feed(0x02) == .wait);
    try std.testing.expect(router.feed(']').command == .resize_wider);
    try std.testing.expect(router.feed('c').command == .new_pane);
    try std.testing.expect(!router.menuActive());

    try std.testing.expect(router.feed(0x02) == .wait);
    try std.testing.expect(router.feed('h').command == .scroll_left);
    try std.testing.expect(router.feed('l').command == .scroll_right);
    try std.testing.expect(router.menuActive());
    try std.testing.expect(router.feed('x').command == .close_pane);
    try std.testing.expect(!router.menuActive());
}
