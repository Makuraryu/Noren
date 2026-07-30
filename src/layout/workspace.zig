const std = @import("std");
const ids = @import("../core/ids.zig");
const model = @import("../core/model.zig");
const placement = @import("placement.zig");
const reveal = @import("reveal.zig");

pub const PaneSnapshot = struct {
    id: ids.PaneId,
    outer_width: u16,
};

pub const WorkspaceSnapshot = struct {
    panes: []const PaneSnapshot,
    focused_pane: usize,
    camera_x: i64,
    gap: u16 = 0,
};

pub fn snapshotFromModel(
    allocator: std.mem.Allocator,
    server: *const model.ServerModel,
    workspace: *const model.Workspace,
) !WorkspaceSnapshot {
    const panes = try allocator.alloc(PaneSnapshot, workspace.panes.items.len);
    errdefer allocator.free(panes);
    for (workspace.panes.items, panes) |pane_id, *output| {
        const pane = server.panes.get(pane_id) orelse return error.MissingPane;
        output.* = .{ .id = pane.id, .outer_width = pane.outer_width };
    }
    return .{
        .panes = panes,
        .focused_pane = workspace.focused_pane,
        .camera_x = workspace.camera_x,
    };
}

pub fn placeWorkspace(
    allocator: std.mem.Allocator,
    workspace: WorkspaceSnapshot,
    viewport: placement.Rect,
) !std.ArrayList(placement.Placement) {
    var result: std.ArrayList(placement.Placement) = .empty;
    errdefer result.deinit(allocator);

    var world_x: i64 = 0;
    for (workspace.panes, 0..) |pane, index| {
        const screen_x_i64 = world_x - workspace.camera_x + viewport.x;
        const pane_right = screen_x_i64 + pane.outer_width;
        const viewport_right = @as(i64, viewport.x) + viewport.width;
        const visible_left = @max(screen_x_i64, viewport.x);
        const visible_right = @min(pane_right, viewport_right);

        if (visible_left < visible_right and viewport.height > 0) {
            try result.append(allocator, .{
                .pane_id = pane.id,
                .pane_index = index,
                .world_x = world_x,
                .screen_x = @intCast(screen_x_i64),
                .outer_width = pane.outer_width,
                .visible = .{
                    .x = @intCast(visible_left),
                    .y = viewport.y,
                    .width = @intCast(visible_right - visible_left),
                    .height = viewport.height,
                },
            });
        }
        world_x += pane.outer_width + workspace.gap;
    }

    return result;
}

pub fn revealForSnapshot(
    allocator: std.mem.Allocator,
    workspace: WorkspaceSnapshot,
    viewport_width: u16,
    direction: ?model.Direction,
) !i64 {
    const geometries = try allocator.alloc(reveal.PaneGeometry, workspace.panes.len);
    defer allocator.free(geometries);
    for (workspace.panes, geometries) |pane, *geometry| {
        geometry.* = .{ .outer_width = pane.outer_width };
    }
    return reveal.revealFocused(
        geometries,
        workspace.focused_pane,
        workspace.camera_x,
        viewport_width,
        direction,
        workspace.gap,
    );
}

test "placement clips without changing pane geometry" {
    const panes = [_]PaneSnapshot{
        .{ .id = @enumFromInt(1), .outer_width = 20 },
        .{ .id = @enumFromInt(2), .outer_width = 20 },
    };
    var placements = try placeWorkspace(
        std.testing.allocator,
        .{ .panes = &panes, .focused_pane = 1, .camera_x = 10 },
        .{ .x = 0, .y = 0, .width = 20, .height = 8 },
    );
    defer placements.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), placements.items.len);
    try std.testing.expectEqual(@as(u16, 10), placements.items[0].visible.width);
    try std.testing.expectEqual(@as(u16, 10), placements.items[1].visible.width);
}
