const std = @import("std");
const cell_mod = @import("cell.zig");

const c = @cImport({
    @cInclude("libvterm_bridge.h");
});

pub const Cursor = struct {
    row: u16,
    col: u16,
    visible: bool,
};

pub const MouseEvent = struct {
    row: u16,
    col: u16,
    button: u8,
    pressed: bool,
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const TerminalBackend = struct {
    handle: *c.NorenVTerm,
    rows: u16,
    cols: u16,

    pub fn init(rows: u16, cols: u16) !TerminalBackend {
        if (rows == 0 or cols == 0) return error.InvalidTerminalSize;
        const handle = c.noren_vterm_new(rows, cols) orelse
            return error.TerminalBackendInitFailed;
        return .{ .handle = handle, .rows = rows, .cols = cols };
    }

    pub fn deinit(self: *TerminalBackend) void {
        c.noren_vterm_free(self.handle);
        self.* = undefined;
    }

    pub fn feed(self: *TerminalBackend, bytes: []const u8) !void {
        const consumed = c.noren_vterm_feed(self.handle, bytes.ptr, bytes.len);
        if (consumed != bytes.len) return error.TerminalInputNotConsumed;
    }

    pub fn resize(self: *TerminalBackend, rows: u16, cols: u16) !void {
        if (rows == 0 or cols == 0) return error.InvalidTerminalSize;
        c.noren_vterm_resize(self.handle, rows, cols);
        self.rows = rows;
        self.cols = cols;
    }

    pub fn cellAt(self: *const TerminalBackend, x: u16, y: u16) cell_mod.Cell {
        if (x >= self.cols or y >= self.rows) return cell_mod.Cell.blank();
        var source: c.NorenVTermCell = undefined;
        if (c.noren_vterm_get_cell(self.handle, y, x, &source) == 0) {
            return cell_mod.Cell.blank();
        }
        if (source.width == 0) {
            return .{ .width = .continuation };
        }

        const style: cell_mod.Style = .{
            .foreground = convertColor(source.foreground),
            .background = convertColor(source.background),
            .bold = source.attrs & c.NOREN_CELL_BOLD != 0,
            .italic = source.attrs & c.NOREN_CELL_ITALIC != 0,
            .underline = source.attrs & c.NOREN_CELL_UNDERLINE != 0,
            .inverse = source.attrs & c.NOREN_CELL_REVERSE != 0,
            .strike = source.attrs & c.NOREN_CELL_STRIKE != 0,
        };
        var utf8: [24]u8 = undefined;
        var length: usize = 0;
        for (source.chars) |raw_codepoint| {
            if (raw_codepoint == 0) break;
            const codepoint: u21 = @intCast(raw_codepoint);
            const written = std.unicode.utf8Encode(codepoint, utf8[length..]) catch continue;
            length += written;
        }
        if (length == 0) {
            var blank = cell_mod.Cell.blank();
            blank.style = style;
            return blank;
        }
        const grapheme = cell_mod.Grapheme.fromUtf8(utf8[0..length]) catch
            cell_mod.Grapheme.fromUtf8("�") catch unreachable;
        return .{
            .grapheme = grapheme,
            .width = if (source.width == 2) .wide else .narrow,
            .style = style,
        };
    }

    pub fn cursor(self: *const TerminalBackend) Cursor {
        var row: c_int = 0;
        var col: c_int = 0;
        var visible: c_int = 0;
        c.noren_vterm_get_cursor(self.handle, &row, &col, &visible);
        return .{
            .row = @intCast(@max(row, 0)),
            .col = @intCast(@max(col, 0)),
            .visible = visible != 0,
        };
    }

    pub fn mouse(self: *TerminalBackend, event: MouseEvent) void {
        var modifiers: c_int = 0;
        if (event.shift) modifiers |= c.NOREN_MOD_SHIFT;
        if (event.alt) modifiers |= c.NOREN_MOD_ALT;
        if (event.ctrl) modifiers |= c.NOREN_MOD_CTRL;
        c.noren_vterm_mouse(
            self.handle,
            event.row,
            event.col,
            event.button,
            @intFromBool(event.pressed),
            modifiers,
        );
    }

    pub fn title(self: *const TerminalBackend) []const u8 {
        return std.mem.span(c.noren_vterm_title(self.handle));
    }

    pub fn takeDamage(self: *TerminalBackend) bool {
        return c.noren_vterm_take_damage(self.handle) != 0;
    }

    pub fn takeOutput(self: *TerminalBackend, out: []u8) []u8 {
        const length = c.noren_vterm_read_output(self.handle, out.ptr, out.len);
        return out[0..length];
    }
};

fn convertColor(color: c.NorenVTermColor) cell_mod.Color {
    return switch (color.kind) {
        c.NOREN_COLOR_INDEXED => .{ .indexed = color.first },
        c.NOREN_COLOR_RGB => .{ .rgb = .{
            .r = color.first,
            .g = color.second,
            .b = color.third,
        } },
        else => .default,
    };
}

test "libvterm backend parses UTF-8 styles title and wide cells" {
    var backend = try TerminalBackend.init(4, 12);
    defer backend.deinit();
    try backend.feed("A\x1b[31mB\x1b[0m中\x1b]2;work\x07");

    try std.testing.expectEqualStrings("A", backend.cellAt(0, 0).grapheme.slice());
    const red = backend.cellAt(1, 0);
    try std.testing.expectEqualStrings("B", red.grapheme.slice());
    try std.testing.expect(red.style.foreground == .indexed);
    try std.testing.expectEqualStrings("中", backend.cellAt(2, 0).grapheme.slice());
    try std.testing.expect(backend.cellAt(2, 0).width == .wide);
    try std.testing.expect(backend.cellAt(3, 0).width == .continuation);
    try std.testing.expectEqualStrings("work", backend.title());
    try std.testing.expect(backend.takeDamage());
    try std.testing.expect(!backend.takeDamage());
}

test "libvterm backend keeps alternate and main screens separate" {
    var backend = try TerminalBackend.init(3, 8);
    defer backend.deinit();
    try backend.feed("main");
    try backend.feed("\x1b[?1049h\x1b[H");
    try backend.feed("alt");
    try std.testing.expectEqualStrings("a", backend.cellAt(0, 0).grapheme.slice());
    try backend.feed("\x1b[?1049l");
    try std.testing.expectEqualStrings("m", backend.cellAt(0, 0).grapheme.slice());
}

test "libvterm backend tracks cursor visibility property changes" {
    var backend = try TerminalBackend.init(3, 8);
    defer backend.deinit();
    try std.testing.expect(backend.cursor().visible);
    try backend.feed("\x1b[?25l");
    try std.testing.expect(!backend.cursor().visible);
    try std.testing.expect(backend.takeDamage());
    try backend.feed("\x1b[?25h");
    try std.testing.expect(backend.cursor().visible);
    try std.testing.expect(backend.takeDamage());
}

test "libvterm backend emits mouse input only when the app enables it" {
    var backend = try TerminalBackend.init(4, 12);
    defer backend.deinit();
    var output: [64]u8 = undefined;

    backend.mouse(.{ .row = 1, .col = 2, .button = 1, .pressed = true });
    try std.testing.expectEqual(@as(usize, 0), backend.takeOutput(&output).len);
    backend.mouse(.{ .row = 1, .col = 2, .button = 1, .pressed = false });
    try std.testing.expectEqual(@as(usize, 0), backend.takeOutput(&output).len);

    try backend.feed("\x1b[?1000h\x1b[?1006h");
    backend.mouse(.{
        .row = 1,
        .col = 2,
        .button = 1,
        .pressed = true,
        .ctrl = true,
    });
    try std.testing.expectEqualStrings(
        "\x1b[<16;3;2M",
        backend.takeOutput(&output),
    );
}

test "libvterm blank cells occupy one rendered column" {
    var backend = try TerminalBackend.init(3, 8);
    defer backend.deinit();

    const blank = backend.cellAt(5, 1);
    try std.testing.expect(blank.width == .narrow);
    try std.testing.expectEqualStrings(" ", blank.grapheme.slice());
}
