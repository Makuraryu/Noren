const std = @import("std");

pub const State = enum { normal, awaiting_command };

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
                self.state = .normal;
                if (byte == self.prefix_byte) return .{ .command = .send_prefix };
                return .{ .command = switch (byte) {
                    'c' => .new_pane,
                    'x' => .close_pane,
                    'h' => .focus_left,
                    'l' => .focus_right,
                    'k' => .focus_up,
                    'j' => .focus_down,
                    'n' => .new_workspace,
                    'd' => .detach,
                    's' => .sessions,
                    ':' => .command_prompt,
                    'r' => .reload,
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
}
