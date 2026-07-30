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

pub const PaneSurfaceEntry = struct {
    pane_id: ids.PaneId,
    surface: PaneSurface,
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
    const placements = [_]placement_mod.Placement{placement};
    const surfaces = [_]PaneSurfaceEntry{.{
        .pane_id = placement.pane_id,
        .surface = surface,
    }};
    try drawWorkspaceSurfaces(
        canvas,
        &placements,
        &surfaces,
        0,
        session_name,
        workspace_number,
        pane_number,
    );
}

pub fn drawWorkspaceSurfaces(
    canvas: *Canvas,
    placements: []const placement_mod.Placement,
    surfaces: []const PaneSurfaceEntry,
    focused_pane: usize,
    session_name: []const u8,
    workspace_number: usize,
    pane_number: usize,
) !void {
    canvas.clear();
    for (placements) |placement| {
        const focused = placement.pane_index == focused_pane;
        drawPaneBorder(canvas, placement, focused);
        const surface = findSurface(surfaces, placement.pane_id) orelse continue;
        drawClippedSurface(canvas, placement, surface);
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

fn findSurface(
    surfaces: []const PaneSurfaceEntry,
    pane_id: ids.PaneId,
) ?PaneSurface {
    for (surfaces) |entry| {
        if (entry.pane_id == pane_id) return entry.surface;
    }
    return null;
}

fn drawClippedSurface(
    canvas: *Canvas,
    placement: placement_mod.Placement,
    surface: PaneSurface,
) void {
    if (placement.visible.height <= 2 or placement.outer_width <= 2) return;
    const content_top = placement.visible.y + 1;
    const copy_rows = @min(surface.rows, placement.visible.height - 2);
    const content_screen_left = placement.screen_x + 1;
    const content_screen_right = placement.screen_x + placement.outer_width - 1;
    const visible_left = @max(@as(i32, 0), content_screen_left);
    const visible_right = @min(@as(i32, canvas.width), content_screen_right);
    if (visible_left >= visible_right) return;

    for (0..copy_rows) |row| {
        var screen_x = visible_left;
        while (screen_x < visible_right) : (screen_x += 1) {
            const source_column: u16 = @intCast(screen_x - content_screen_left);
            if (source_column >= surface.cols) continue;
            var source = surface.cellAt(source_column, @intCast(row));
            if (source.width == .continuation and
                (source_column == 0 or screen_x == visible_left))
            {
                source = cell_mod.Cell.blank();
            } else if (source.width == .wide and screen_x + 1 >= visible_right) {
                source = cell_mod.Cell.blank();
            }
            canvas.set(
                screen_x,
                content_top + @as(i32, @intCast(row)),
                source,
            );
        }
    }
}

fn drawPaneBorder(
    canvas: *Canvas,
    placement: placement_mod.Placement,
    focused: bool,
) void {
    const left = placement.screen_x;
    const right = left + placement.outer_width - 1;
    const top = placement.visible.y;
    const bottom = top + placement.visible.height - 1;

    canvas.set(left, top, borderCell("┌", focused));
    canvas.set(right, top, borderCell("┐", focused));
    canvas.set(left, bottom, borderCell("└", focused));
    canvas.set(right, bottom, borderCell("┘", focused));
    var x = left + 1;
    while (x < right) : (x += 1) {
        canvas.set(x, top, borderCell("─", focused));
        canvas.set(x, bottom, borderCell("─", focused));
    }
    var y = top + 1;
    while (y < bottom) : (y += 1) {
        canvas.set(left, y, borderCell("│", focused));
        canvas.set(right, y, borderCell("│", focused));
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

fn borderCell(text: []const u8, focused: bool) cell_mod.Cell {
    var result = cell(text);
    result.style.dim = !focused;
    result.style.bold = focused;
    return result;
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

test "status reports active workspace and focused pane numbers" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 20, 4);
    defer canvas.deinit(allocator);
    try drawWorkspaceSurfaces(
        &canvas,
        &.{},
        &.{},
        0,
        "work",
        2,
        3,
    );
    var dump: std.Io.Writer.Allocating = .init(allocator);
    defer dump.deinit();
    try canvas.writeTextDump(&dump.writer);
    try std.testing.expect(
        std.mem.indexOf(u8, dump.written(), "work 2:3") != null,
    );
}
