const ids = @import("ids.zig");
const model = @import("model.zig");

pub const Origin = union(enum) {
    client: ids.ClientId,
    cli: ids.ConnectionId,
    child_exit: ids.PaneId,
    timer: ids.TimerId,
    server: void,
};

pub const NewPane = struct {
    session_id: ids.SessionId,
    outer_width: u16,
    viewport_width: u16 = 80,
};

pub const NewWorkspace = struct {
    session_id: ids.SessionId,
    outer_width: u16,
};

pub const FocusPane = struct {
    session_id: ids.SessionId,
    direction: model.Direction,
    viewport_width: u16,
};

pub const ResizePane = struct {
    session_id: ids.SessionId,
    delta: i32,
    viewport_width: u16,
};

pub const RenameSession = struct {
    session_id: ids.SessionId,
    name: []const u8,
};

pub const AttachClient = struct {
    client_id: ids.ClientId,
    session_id: ids.SessionId,
    detach_others: bool = false,
};

pub const ClientResized = struct {
    client_id: ids.ClientId,
    size: model.Size,
};

pub const Action = union(enum) {
    new_pane: NewPane,
    pane_spawned: ids.PaneId,
    pane_spawn_failed: ids.PaneId,
    close_pane: ids.PaneId,
    close_deadline: ids.PaneId,
    pane_process_exited: ids.PaneId,
    pane_drained: ids.PaneId,
    resize_pane: ResizePane,
    focus_pane: FocusPane,

    new_workspace: NewWorkspace,
    focus_workspace: struct {
        session_id: ids.SessionId,
        direction: model.Direction,
    },
    rename_session: RenameSession,

    attach_client: AttachClient,
    detach_client: ids.ClientId,
    take_size_ownership: ids.ClientId,
    client_resized: ClientResized,
};
