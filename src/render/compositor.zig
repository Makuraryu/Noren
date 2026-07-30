const std = @import("std");
const ids = @import("../core/ids.zig");
const placement_mod = @import("../layout/placement.zig");
const Canvas = @import("canvas.zig").Canvas;
const cell_mod = @import("../terminal/cell.zig");

pub const PaneSurface = struct {
    cells: []const cell_mod.Cell,
    cols: u16,
    rows: u16,

    pub fn cellAt(self: PaneSurface, x: u16, y: u16) cell_mod.Cell {
        return self.cells[@as(usize, y) * self.cols + x];
    }
};

pub fn drawWorkspace(
    canvas: *Canvas,
    placements: []const placement_mod.Placement,
    focused_pane: usize,
    session_name: []const u8,
    workspace_number: usize,
    pane_number: usize,
) !void {
    canvas.clear();
    for (placements) |placement| {
        drawPaneBorder(canvas, placement, placement.pane_index == focused_pane);
    }
    if (canvas.height > 0) {
        var status_buffer: [256]u8 = undefined;
        const status = try std.fmt.bufPrint(
            &status_buffer,
            "{s} {d}:{d}",
            .{ session_name, workspace_number, pane_number },
        );
        drawText(canvas, 0, canvas.height - 1, status);
    }
}

pub fn drawPaneSurface(
    canvas: *Canvas,
    placement: placement_mod.Placement,
    surface: PaneSurface,
    session_name: []const u8,
    workspace_number: usize,
    pane_number: usize,
) !void {
    canvas.clear();
    drawPaneBorder(canvas, placement, true);

    const content_left = placement.screen_x + 1;
    const content_top = placement.visible.y + 1;
    const visible_content_cols = placement.visible.width -| 2;
    const visible_content_rows = placement.visible.height -| 2;
    const copy_cols = @min(surface.cols, visible_content_cols);
    const copy_rows = @min(surface.rows, visible_content_rows);
    for (0..copy_rows) |row| {
        for (0..copy_cols) |column| {
            const source = surface.cellAt(@intCast(column), @intCast(row));
            if (source.width == .wide and column + 1 >= copy_cols) {
                canvas.set(
                    content_left + @as(i32, @intCast(column)),
                    content_top + @as(i32, @intCast(row)),
                    cell_mod.Cell.blank(),
                );
                continue;
            }
            canvas.set(
                content_left + @as(i32, @intCast(column)),
                content_top + @as(i32, @intCast(row)),
                source,
            );
        }
    }

    if (canvas.height > 0) {
        var status_buffer: [256]u8 = undefined;
        const status = try std.fmt.bufPrint(
            &status_buffer,
            "{s} {d}:{d}",
            .{ session_name, workspace_number, pane_number },
        );
        drawText(canvas, 0, canvas.height - 1, status);
        for (0..canvas.width) |column| {
            const index = @as(usize, canvas.height - 1) * canvas.width + column;
            canvas.cells[index].style.inverse = true;
        }
    }
}

fn drawPaneBorder(
    canvas: *Canvas,
    placement: placement_mod.Placement,
    focused: bool,
) void {
    _ = focused;
    const left = placement.screen_x;
    const right = left + placement.outer_width - 1;
    const top = placement.visible.y;
    const bottom = top + placement.visible.height - 1;

    canvas.set(left, top, cell("┌"));
    canvas.set(right, top, cell("┐"));
    canvas.set(left, bottom, cell("└"));
    canvas.set(right, bottom, cell("┘"));
    var x = left + 1;
    while (x < right) : (x += 1) {
        canvas.set(x, top, cell("─"));
        canvas.set(x, bottom, cell("─"));
    }
    var y = top + 1;
    while (y < bottom) : (y += 1) {
        canvas.set(left, y, cell("│"));
        canvas.set(right, y, cell("│"));
    }
}

fn drawText(canvas: *Canvas, start_x: i32, y: i32, text: []const u8) void {
    var view = std.unicode.Utf8View.init(text) catch return;
    var iterator = view.iterator();
    var x = start_x;
    while (iterator.nextCodepointSlice()) |codepoint| : (x += 1) {
        canvas.set(x, y, cell(codepoint));
        if (x >= canvas.width - 1) break;
    }
}

fn cell(text: []const u8) cell_mod.Cell {
    return cell_mod.Cell.fromUtf8(text) catch cell_mod.Cell.blank();
}

test "gap zero preserves two independent pane borders" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 12, 5);
    defer canvas.deinit(allocator);
    const placements = [_]placement_mod.Placement{
        .{
            .pane_id = @as(ids.PaneId, @enumFromInt(1)),
            .pane_index = 0,
            .world_x = 0,
            .screen_x = 0,
            .outer_width = 6,
            .visible = .{ .x = 0, .y = 0, .width = 6, .height = 4 },
        },
        .{
            .pane_id = @as(ids.PaneId, @enumFromInt(2)),
            .pane_index = 1,
            .world_x = 6,
            .screen_x = 6,
            .outer_width = 6,
            .visible = .{ .x = 6, .y = 0, .width = 6, .height = 4 },
        },
    };
    try drawWorkspace(&canvas, &placements, 1, "work", 1, 2);
    try std.testing.expectEqualStrings("│", canvas.get(5, 1).grapheme.slice());
    try std.testing.expectEqualStrings("│", canvas.get(6, 1).grapheme.slice());
}
