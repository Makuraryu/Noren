const std = @import("std");

pub const Attach = struct {
    target: []const u8,
    rows: u16,
    cols: u16,
};

pub const Resize = struct {
    rows: u16,
    cols: u16,
};

pub const Attached = struct {
    session: []const u8,
};

pub const Command = struct {
    command: []const u8,
    value: ?[]const u8 = null,
};

pub const MouseInput = struct {
    x: u16,
    y: u16,
    button: u8,
    pressed: bool,
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub fn encode(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}

pub fn decode(
    comptime T: type,
    allocator: std.mem.Allocator,
    payload: []const u8,
) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, payload, .{
        .ignore_unknown_fields = true,
    });
}

test "control messages are JSON and round trip" {
    const allocator = std.testing.allocator;
    const bytes = try encode(allocator, Attach{
        .target = "work",
        .rows = 24,
        .cols = 80,
    });
    defer allocator.free(bytes);
    var parsed = try decode(Attach, allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("work", parsed.value.target);
    try std.testing.expectEqual(@as(u16, 24), parsed.value.rows);
}

test "mouse input round trips with zero-based coordinates" {
    const allocator = std.testing.allocator;
    const bytes = try encode(allocator, MouseInput{
        .x = 12,
        .y = 7,
        .button = 1,
        .pressed = true,
        .ctrl = true,
    });
    defer allocator.free(bytes);
    var parsed = try decode(MouseInput, allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u16, 12), parsed.value.x);
    try std.testing.expectEqual(@as(u8, 1), parsed.value.button);
    try std.testing.expect(parsed.value.ctrl);
}
