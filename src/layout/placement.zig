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
};
