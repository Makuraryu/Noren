const std = @import("std");
const model = @import("../core/model.zig");

pub const PaneGeometry = struct {
    outer_width: u16,
};

/// Return the minimal legal camera position that reveals the focused pane.
/// No safety margin is applied (INV-006).
pub fn revealFocused(
    panes: []const PaneGeometry,
    focused_index: usize,
    current_camera: i64,
    viewport_width: u16,
    direction: ?model.Direction,
    gap: u16,
) i64 {
    if (panes.len == 0 or focused_index >= panes.len or viewport_width == 0) return 0;

    var pane_left: i64 = 0;
    for (panes[0..focused_index]) |pane| {
        pane_left += @as(i64, pane.outer_width) + gap;
    }
    const pane_right = pane_left + panes[focused_index].outer_width;
    const world_right = worldWidth(panes, gap);
    const max_camera = @max(@as(i64, 0), world_right - viewport_width);

    var camera = std.math.clamp(current_camera, 0, max_camera);
    const pane_width = panes[focused_index].outer_width;
    if (pane_width > viewport_width) {
        if (direction == .right) {
            camera = pane_left;
        } else if (direction == .left) {
            camera = pane_right - viewport_width;
        } else {
            const viewport_right = camera + viewport_width;
            if (pane_right <= camera) camera = pane_right - viewport_width;
            if (pane_left >= viewport_right) camera = pane_left;
        }
    } else if (pane_left < camera) {
        camera = pane_left;
    } else if (pane_right > camera + viewport_width) {
        camera = pane_right - viewport_width;
    }

    return std.math.clamp(camera, 0, max_camera);
}

pub fn worldWidth(panes: []const PaneGeometry, gap: u16) i64 {
    if (panes.len == 0) return 0;
    var width: i64 = 0;
    for (panes) |pane| width += pane.outer_width;
    width += @as(i64, gap) * @as(i64, @intCast(panes.len - 1));
    return width;
}

test "minimal reveal moves only as far as needed" {
    const panes = [_]PaneGeometry{
        .{ .outer_width = 20 },
        .{ .outer_width = 20 },
        .{ .outer_width = 20 },
    };
    try std.testing.expectEqual(@as(i64, 0), revealFocused(&panes, 0, 0, 30, .right, 0));
    try std.testing.expectEqual(@as(i64, 10), revealFocused(&panes, 1, 0, 30, .right, 0));
    try std.testing.expectEqual(@as(i64, 30), revealFocused(&panes, 2, 10, 30, .right, 0));
}

test "wide panes align by focus direction" {
    const panes = [_]PaneGeometry{
        .{ .outer_width = 10 },
        .{ .outer_width = 50 },
        .{ .outer_width = 10 },
    };
    try std.testing.expectEqual(@as(i64, 10), revealFocused(&panes, 1, 0, 20, .right, 0));
    try std.testing.expectEqual(@as(i64, 40), revealFocused(&panes, 1, 50, 20, .left, 0));
}
