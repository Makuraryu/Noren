const std = @import("std");
const terminal_mod = @import("../terminal/backend.zig");
const cell_mod = @import("../terminal/cell.zig");
const canvas_mod = @import("canvas.zig");
const compositor = @import("compositor.zig");
const ansi = @import("ansi.zig");
const placement_mod = @import("../layout/placement.zig");
const ids = @import("../core/ids.zig");

pub const BackendView = struct {
    pane_id: ids.PaneId,
    backend: *const terminal_mod.TerminalBackend,
};

pub const Renderer = struct {
    previous: ?canvas_mod.Canvas = null,

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        if (self.previous) |*canvas| canvas.deinit(allocator);
        self.* = .{};
    }

    pub fn frameAlloc(
        self: *Renderer,
        allocator: std.mem.Allocator,
        backends: []const BackendView,
        placements: []const placement_mod.Placement,
        focused_pane: usize,
        outer_cols: u16,
        outer_rows: u16,
        session_name: []const u8,
        time_text: []const u8,
        workspace_number: usize,
        pane_number: usize,
        force_full: bool,
    ) ![]u8 {
        if (outer_cols < 3 or outer_rows < 4) return error.TerminalTooSmall;
        var canvas = try canvas_mod.Canvas.init(allocator, outer_cols, outer_rows);
        errdefer canvas.deinit(allocator);

        const surfaces = try allocator.alloc(
            compositor.PaneSurfaceEntry,
            backends.len,
        );
        defer allocator.free(surfaces);
        const owned_cells = try allocator.alloc([]cell_mod.Cell, backends.len);
        defer allocator.free(owned_cells);
        var initialized: usize = 0;
        defer for (owned_cells[0..initialized]) |cells| allocator.free(cells);

        for (backends, 0..) |view, index| {
            const backend = view.backend;
            const cells = try allocator.alloc(
                cell_mod.Cell,
                @as(usize, backend.rows) * backend.cols,
            );
            owned_cells[index] = cells;
            initialized += 1;
            for (0..backend.rows) |row| {
                for (0..backend.cols) |column| {
                    cells[row * backend.cols + column] = backend.cellAt(
                        @intCast(column),
                        @intCast(row),
                    );
                }
            }
            surfaces[index] = .{
                .pane_id = view.pane_id,
                .surface = .{
                    .cells = cells,
                    .cols = backend.cols,
                    .rows = backend.rows,
                },
            };
        }

        try compositor.drawWorkspaceSurfaces(
            &canvas,
            placements,
            surfaces,
            focused_pane,
            session_name,
            time_text,
            workspace_number,
            pane_number,
        );
        const cursor = focusedCursor(
            backends,
            placements,
            focused_pane,
            outer_cols,
            outer_rows,
        );

        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
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

fn focusedCursor(
    backends: []const BackendView,
    placements: []const placement_mod.Placement,
    focused_pane: usize,
    outer_cols: u16,
    outer_rows: u16,
) ansi.Cursor {
    for (placements) |placement| {
        if (placement.pane_index != focused_pane) continue;
        for (backends) |view| {
            if (view.pane_id != placement.pane_id) continue;
            const child = view.backend.cursor();
            const x = placement.screen_x + 1 + child.col;
            const y = placement.visible.y + 1 + child.row;
            return .{
                .x = if (x < 0) 0 else @intCast(x),
                .y = if (y < 0) 0 else @intCast(y),
                .visible = child.visible and
                    child.col < view.backend.cols and
                    child.row < view.backend.rows and
                    x >= 0 and y >= 0 and
                    x < outer_cols and y < outer_rows -| 1,
            };
        }
    }
    return .{ .x = 0, .y = 0, .visible = false };
}
