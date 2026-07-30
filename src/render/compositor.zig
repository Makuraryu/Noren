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

pub const StatusInfo = struct {
    session_name: []const u8,
    time_text: []const u8,
    workspace_number: usize,
    pane_number: usize,
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
        try drawStatusBar(canvas, canvas.height - 1, .{
            .session_name = session_name,
            .time_text = "--:--",
            .workspace_number = workspace_number,
            .pane_number = pane_number,
        });
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
        "--:--",
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
    time_text: []const u8,
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
        try drawStatusBar(canvas, canvas.height - 1, .{
            .session_name = session_name,
            .time_text = time_text,
            .workspace_number = workspace_number,
            .pane_number = pane_number,
        });
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

const Nord = struct {
    const polar_night = rgb(46, 52, 64);
    const polar_night_light = rgb(67, 76, 94);
    const snow_storm = rgb(236, 239, 244);
    const frost_cyan = rgb(136, 192, 208);
    const frost_blue = rgb(129, 161, 193);
    const aurora_green = rgb(163, 190, 140);
};

fn drawStatusBar(canvas: *Canvas, y: i32, info: StatusInfo) !void {
    const background = Nord.polar_night;
    for (0..canvas.width) |column| {
        canvas.set(
            @intCast(column),
            y,
            styledCell(" ", Nord.snow_storm, background),
        );
    }

    var session_buffer: [256]u8 = undefined;
    const session_text = try std.fmt.bufPrint(
        &session_buffer,
        "session:{s}",
        .{info.session_name},
    );
    var workspace_buffer: [64]u8 = undefined;
    const workspace_text = try std.fmt.bufPrint(
        &workspace_buffer,
        "{d}:{d}",
        .{ info.workspace_number, info.pane_number },
    );

    var left: i32 = 0;
    left = drawCapsule(
        canvas,
        left,
        y,
        "Ctrl+b",
        Nord.frost_cyan,
        Nord.polar_night,
        background,
    ) + 1;
    _ = drawCapsule(
        canvas,
        left,
        y,
        session_text,
        Nord.frost_blue,
        Nord.polar_night,
        background,
    );

    const workspace_width = capsuleWidth(workspace_text);
    const workspace_start: i32 = @max(
        @as(i32, 0),
        @as(i32, canvas.width) - @as(i32, @intCast(workspace_width)),
    );
    const time_start: i32 = @max(
        @as(i32, 0),
        workspace_start - 1 -
            @as(i32, @intCast(capsuleWidth(info.time_text))),
    );
    _ = drawCapsule(
        canvas,
        time_start,
        y,
        info.time_text,
        Nord.polar_night_light,
        Nord.snow_storm,
        background,
    );
    _ = drawCapsule(
        canvas,
        workspace_start,
        y,
        workspace_text,
        Nord.aurora_green,
        Nord.polar_night,
        background,
    );
}

fn drawCapsule(
    canvas: *Canvas,
    start_x: i32,
    y: i32,
    text: []const u8,
    capsule_color: cell_mod.Color,
    text_color: cell_mod.Color,
    background: cell_mod.Color,
) i32 {
    var x = start_x;
    canvas.set(x, y, styledCell("", capsule_color, background));
    x += 1;
    canvas.set(x, y, styledCell(" ", text_color, capsule_color));
    x += 1;
    x = drawStyledText(canvas, x, y, text, text_color, capsule_color);
    canvas.set(x, y, styledCell(" ", text_color, capsule_color));
    x += 1;
    canvas.set(x, y, styledCell("", capsule_color, background));
    return x + 1;
}

fn drawStyledText(
    canvas: *Canvas,
    start_x: i32,
    y: i32,
    text: []const u8,
    foreground: cell_mod.Color,
    background: cell_mod.Color,
) i32 {
    var view = std.unicode.Utf8View.init(text) catch return start_x;
    var iterator = view.iterator();
    var x = start_x;
    while (iterator.nextCodepointSlice()) |codepoint| : (x += 1) {
        canvas.set(x, y, styledCell(codepoint, foreground, background));
    }
    return x;
}

fn capsuleWidth(text: []const u8) usize {
    var view = std.unicode.Utf8View.init(text) catch return text.len + 4;
    var iterator = view.iterator();
    var count: usize = 4;
    while (iterator.nextCodepointSlice()) |_| count += 1;
    return count;
}

fn styledCell(
    text: []const u8,
    foreground: cell_mod.Color,
    background: cell_mod.Color,
) cell_mod.Cell {
    var result = cell(text);
    result.style.foreground = foreground;
    result.style.background = background;
    result.style.bold = true;
    return result;
}

fn rgb(r: u8, g: u8, b: u8) cell_mod.Color {
    return .{ .rgb = .{ .r = r, .g = g, .b = b } };
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
    var canvas = try Canvas.init(allocator, 80, 4);
    defer canvas.deinit(allocator);
    try drawWorkspaceSurfaces(
        &canvas,
        &.{},
        &.{},
        0,
        "work",
        "12:34",
        2,
        3,
    );
    var dump: std.Io.Writer.Allocating = .init(allocator);
    defer dump.deinit();
    try canvas.writeTextDump(&dump.writer);
    try std.testing.expect(std.mem.indexOf(u8, dump.written(), "Ctrl+b") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, dump.written(), "session:work") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, dump.written(), "12:34") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump.written(), "2:3") != null);
    const key_background = canvas.get(2, 3).style.background.rgb;
    try std.testing.expectEqual(@as(u8, 136), key_background.r);
    try std.testing.expectEqual(@as(u8, 192), key_background.g);
    try std.testing.expectEqual(@as(u8, 208), key_background.b);
    try std.testing.expectEqualStrings(
        "",
        canvas.get(canvas.width - 1, 3).grapheme.slice(),
    );
}
