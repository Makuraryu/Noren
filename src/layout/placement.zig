const ids = @import("../core/ids.zig");

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u16,
    height: u16,
};

pub const Placement = struct {
    pane_id: ids.PaneId,
    pane_index: usize,
    world_x: i64,
    screen_x: i32,
    outer_width: u16,
    visible: Rect,

    pub fn contains(self: Placement, x: i32, y: i32) bool {
        return x >= self.visible.x and y >= self.visible.y and
            x < self.visible.x + self.visible.width and
            y < self.visible.y + self.visible.height;
    }

    pub fn contentPoint(self: Placement, x: i32, y: i32) ?ContentPoint {
        const content_left = self.screen_x + 1;
        const content_top = self.visible.y + 1;
        const content_right = self.screen_x + self.outer_width - 1;
        const content_bottom = self.visible.y + self.visible.height - 1;
        if (x < content_left or x >= content_right or
            y < content_top or y >= content_bottom) return null;
        return .{
            .col = @intCast(x - content_left),
            .row = @intCast(y - content_top),
        };
    }
};

pub const ContentPoint = struct {
    col: u16,
    row: u16,
};
