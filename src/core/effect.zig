const ids = @import("ids.zig");
const model = @import("model.zig");

pub const Signal = enum { hup, term, kill };

pub const Effect = union(enum) {
    spawn_pane: struct {
        pane_id: ids.PaneId,
        size: model.Size,
    },
    resize_pty: struct {
        pane_id: ids.PaneId,
        size: model.Size,
    },
    signal_process_group: struct {
        pane_id: ids.PaneId,
        signal: Signal,
    },
    arm_close_timer: struct {
        pane_id: ids.PaneId,
        delay_ms: u32,
    },
    request_full_redraw: ids.ClientId,
    disconnect_client: ids.ClientId,
};
