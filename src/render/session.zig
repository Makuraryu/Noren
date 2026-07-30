const std = @import("std");
const terminal_mod = @import("../terminal/backend.zig");
const cell_mod = @import("../terminal/cell.zig");
const canvas_mod = @import("canvas.zig");
const compositor = @import("compositor.zig");
const ansi = @import("ansi.zig");
const placement_mod = @import("../layout/placement.zig");
const ids = @import("../core/ids.zig");

pub const Renderer = struct {
    previous: ?canvas_mod.Canvas = null,

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        if (self.previous) |*canvas| canvas.deinit(allocator);
        self.* = .{};
    }

    pub fn frameAlloc(
        self: *Renderer,
        allocator: std.mem.Allocator,
        backend: *const terminal_mod.TerminalBackend,
        outer_cols: u16,
        outer_rows: u16,
        session_name: []const u8,
        force_full: bool,
    ) ![]u8 {
        if (outer_cols < 3 or outer_rows < 4) return error.TerminalTooSmall;
        var canvas = try canvas_mod.Canvas.init(allocator, outer_cols, outer_rows);
        errdefer canvas.deinit(allocator);
        const cells = try allocator.alloc(
            cell_mod.Cell,
            @as(usize, backend.rows) * backend.cols,
        );
        defer allocator.free(cells);
        for (0..backend.rows) |row| {
            for (0..backend.cols) |column| {
                cells[row * backend.cols + column] = backend.cellAt(
                    @intCast(column),
                    @intCast(row),
                );
            }
        }
        const pane_outer_width = backend.cols + 2;
        const pane_outer_rows = backend.rows + 2;
        const placement: placement_mod.Placement = .{
            .pane_id = @as(ids.PaneId, @enumFromInt(1)),
            .pane_index = 0,
            .world_x = 0,
            .screen_x = 0,
            .outer_width = pane_outer_width,
            .visible = .{
                .x = 0,
                .y = 0,
                .width = @min(canvas.width, pane_outer_width),
                .height = @min(canvas.height -| 1, pane_outer_rows),
            },
        };
        try compositor.drawPaneSurface(
            &canvas,
            placement,
            .{ .cells = cells, .cols = backend.cols, .rows = backend.rows },
            session_name,
            1,
            1,
        );
        const child_cursor = backend.cursor();
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        const cursor: ansi.Cursor = .{
            .x = child_cursor.col + 1,
            .y = child_cursor.row + 1,
            .visible = child_cursor.visible and
                child_cursor.col < backend.cols and
                child_cursor.row < backend.rows,
        };
        if (!force_full and self.previous != null) {
            try ansi.writeDiff(&output.writer, &self.previous.?, &canvas, cursor);
            const full_frame_threshold =
                @as(usize, canvas.width) * canvas.height * 12;
            if (output.written().len > full_frame_threshold) {
                output.clearRetainingCapacity();
                try ansi.writeFull(&output.writer, &canvas, cursor, false);
            }
        } else {
            try ansi.writeFull(&output.writer, &canvas, cursor, true);
        }
        const bytes = try allocator.dupe(u8, output.written());
        if (self.previous) |*previous| previous.deinit(allocator);
        self.previous = canvas;
        return bytes;
    }
};
