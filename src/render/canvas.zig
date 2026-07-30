const std = @import("std");
const cell_mod = @import("../terminal/cell.zig");

pub const Canvas = struct {
    width: u16,
    height: u16,
    cells: []cell_mod.Cell,

    pub fn init(
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
    ) !Canvas {
        const count = try std.math.mul(usize, width, height);
        const cells = try allocator.alloc(cell_mod.Cell, count);
        var canvas: Canvas = .{ .width = width, .height = height, .cells = cells };
        canvas.clear();
        return canvas;
    }

    pub fn deinit(self: *Canvas, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn clear(self: *Canvas) void {
        @memset(self.cells, cell_mod.Cell.blank());
    }

    pub fn set(self: *Canvas, x: i32, y: i32, cell: cell_mod.Cell) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        self.cells[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))] = cell;
    }

    pub fn get(self: *const Canvas, x: u16, y: u16) cell_mod.Cell {
        return self.cells[@as(usize, y) * self.width + x];
    }

    pub fn writeTextDump(self: *const Canvas, writer: *std.Io.Writer) !void {
        for (0..self.height) |row| {
            for (0..self.width) |column| {
                const cell = self.get(@intCast(column), @intCast(row));
                switch (cell.width) {
                    .continuation => {},
                    .empty => try writer.writeByte(' '),
                    else => try writer.writeAll(cell.grapheme.slice()),
                }
            }
            try writer.writeByte('\n');
        }
    }
};
