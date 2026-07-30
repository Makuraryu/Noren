const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;
const cell_mod = @import("../terminal/cell.zig");

pub const Cursor = struct {
    x: u16,
    y: u16,
    visible: bool,
};

pub fn writeFull(
    writer: *std.Io.Writer,
    canvas: *const Canvas,
    cursor: Cursor,
    clear: bool,
) !void {
    if (clear) try writer.writeAll("\x1b[0m\x1b[2J");
    var active_style: cell_mod.Style = .{};
    var style_known = false;
    for (0..canvas.height) |row| {
        try writer.print("\x1b[{d};1H", .{row + 1});
        for (0..canvas.width) |column| {
            const current = canvas.get(@intCast(column), @intCast(row));
            if (current.width == .continuation) continue;
            if (!style_known or !std.meta.eql(active_style, current.style)) {
                try writeStyle(writer, current.style);
                active_style = current.style;
                style_known = true;
            }
            switch (current.width) {
                .empty => try writer.writeByte(' '),
                .narrow => if (current.grapheme.len == 0)
                    try writer.writeByte(' ')
                else
                    try writer.writeAll(current.grapheme.slice()),
                .wide => if (current.grapheme.len == 0)
                    try writer.writeAll("  ")
                else
                    try writer.writeAll(current.grapheme.slice()),
                .continuation => unreachable,
            }
        }
    }
    try writer.writeAll("\x1b[0m");
    if (cursor.visible and cursor.x < canvas.width and cursor.y < canvas.height) {
        try writer.print(
            "\x1b[{d};{d}H\x1b[?25h",
            .{ cursor.y + 1, cursor.x + 1 },
        );
    } else {
        try writer.writeAll("\x1b[?25l");
    }
}

pub fn writeDiff(
    writer: *std.Io.Writer,
    previous: *const Canvas,
    current: *const Canvas,
    cursor: Cursor,
) !void {
    if (previous.width != current.width or previous.height != current.height) {
        return writeFull(writer, current, cursor, true);
    }
    for (0..current.height) |row| {
        for (0..current.width) |column| {
            const before = previous.get(@intCast(column), @intCast(row));
            const after = current.get(@intCast(column), @intCast(row));
            if (std.meta.eql(before, after) or after.width == .continuation) continue;
            try writer.print("\x1b[{d};{d}H", .{ row + 1, column + 1 });
            try writeStyle(writer, after.style);
            switch (after.width) {
                .empty => try writer.writeByte(' '),
                .narrow => if (after.grapheme.len == 0)
                    try writer.writeByte(' ')
                else
                    try writer.writeAll(after.grapheme.slice()),
                .wide => if (after.grapheme.len == 0)
                    try writer.writeAll("  ")
                else
                    try writer.writeAll(after.grapheme.slice()),
                .continuation => unreachable,
            }
        }
    }
    try writer.writeAll("\x1b[0m");
    if (cursor.visible and cursor.x < current.width and cursor.y < current.height) {
        try writer.print(
            "\x1b[{d};{d}H\x1b[?25h",
            .{ cursor.y + 1, cursor.x + 1 },
        );
    } else {
        try writer.writeAll("\x1b[?25l");
    }
}

test "diff renderer emits only changed cells" {
    const allocator = std.testing.allocator;
    var previous = try Canvas.init(allocator, 3, 1);
    defer previous.deinit(allocator);
    var current = try Canvas.init(allocator, 3, 1);
    defer current.deinit(allocator);
    previous.cells[0] = try cell_mod.Cell.fromUtf8("A");
    current.cells[0] = previous.cells[0];
    current.cells[1] = try cell_mod.Cell.fromUtf8("B");

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeDiff(
        &output.writer,
        &previous,
        &current,
        .{ .x = 0, .y = 0, .visible = false },
    );
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "A") == null);
}

test "renderer advances across malformed empty graphemes defensively" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 1, 1);
    defer canvas.deinit(allocator);
    canvas.cells[0] = .{ .width = .narrow };

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeFull(
        &output.writer,
        &canvas,
        .{ .x = 0, .y = 0, .visible = false },
        false,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, output.written(), "\x1b[0m ") != null,
    );
}

fn writeStyle(writer: *std.Io.Writer, style: cell_mod.Style) !void {
    try writer.writeAll("\x1b[0");
    if (style.bold) try writer.writeAll(";1");
    if (style.dim) try writer.writeAll(";2");
    if (style.italic) try writer.writeAll(";3");
    if (style.underline) try writer.writeAll(";4");
    if (style.inverse) try writer.writeAll(";7");
    if (style.strike) try writer.writeAll(";9");
    try writeColor(writer, style.foreground, true);
    try writeColor(writer, style.background, false);
    try writer.writeByte('m');
}

fn writeColor(
    writer: *std.Io.Writer,
    color: cell_mod.Color,
    foreground: bool,
) !void {
    switch (color) {
        .default => {},
        .indexed => |index| try writer.print(
            ";{d};5;{d}",
            .{ if (foreground) @as(u8, 38) else 48, index },
        ),
        .rgb => |rgb| try writer.print(
            ";{d};2;{d};{d};{d}",
            .{ if (foreground) @as(u8, 38) else 48, rgb.r, rgb.g, rgb.b },
        ),
    }
}

test "full renderer emits absolute cursor and structured SGR" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 2, 1);
    defer canvas.deinit(allocator);
    canvas.cells[0] = try cell_mod.Cell.fromUtf8("A");
    canvas.cells[0].style.bold = true;
    canvas.cells[1] = try cell_mod.Cell.fromUtf8("B");

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try writeFull(
        &output.writer,
        &canvas,
        .{ .x = 1, .y = 0, .visible = true },
        true,
    );
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[0;1mA") != null);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "\x1b[1;2H\x1b[?25h"));
}
