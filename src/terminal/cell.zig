const std = @import("std");

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Style = struct {
    foreground: Color = .default,
    background: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strike: bool = false,
};

pub const CellWidth = enum(u2) {
    empty = 0,
    narrow = 1,
    wide = 2,
    continuation = 3,
};

pub const Grapheme = struct {
    bytes: [24]u8 = [_]u8{0} ** 24,
    len: u8 = 0,

    pub fn fromUtf8(text: []const u8) !Grapheme {
        if (text.len > 24) return error.GraphemeTooLong;
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        var result: Grapheme = .{};
        @memcpy(result.bytes[0..text.len], text);
        result.len = @intCast(text.len);
        return result;
    }

    pub fn slice(self: *const Grapheme) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Cell = struct {
    grapheme: Grapheme = .{},
    width: CellWidth = .empty,
    style: Style = .{},
    hyperlink: ?u32 = null,

    pub fn blank() Cell {
        return .{
            .grapheme = Grapheme.fromUtf8(" ") catch unreachable,
            .width = .narrow,
        };
    }

    pub fn fromUtf8(text: []const u8) !Cell {
        return .{
            .grapheme = try Grapheme.fromUtf8(text),
            .width = .narrow,
        };
    }
};

test "cell retains a combining grapheme as one value" {
    const cell = try Cell.fromUtf8("e\u{301}");
    try std.testing.expectEqualStrings("e\u{301}", cell.grapheme.slice());
}
