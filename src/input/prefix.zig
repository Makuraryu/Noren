const std = @import("std");

pub const State = enum {
    normal,
    awaiting_command,
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
    resize_narrower,
    resize_wider,
    new_workspace,
    detach,
    sessions,
    command_prompt,
    reload,
    send_prefix,
};

pub const Router = struct {
    state: State = .normal,
    prefix_byte: u8 = 0x02,

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
                return .{ .command = switch (byte) {
                    'c' => .new_pane,
                    'x' => .close_pane,
                    'h' => .focus_left,
                    'l' => .focus_right,
                    'k' => .focus_up,
                    'j' => .focus_down,
                    'H' => .resize_narrower,
                    'L' => .resize_wider,
                    'n' => .new_workspace,
                    'd' => .detach,
                    's' => .sessions,
                    ':' => .command_prompt,
                    'r' => .reload,
                    else => return .{ .rejected = byte },
                } };
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
}
