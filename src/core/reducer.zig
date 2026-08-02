const std = @import("std");
const ids = @import("ids.zig");
const model = @import("model.zig");
const action_mod = @import("action.zig");
const effect_mod = @import("effect.zig");
const invariant = @import("invariant.zig");

pub const ReducerError = error{
    ReadOnlyClient,
    SessionNotFound,
    WorkspaceNotFound,
    PaneNotFound,
    ClientNotFound,
    InvalidDirection,
    PaneLimitReached,
    WorkspaceLimitReached,
    ClientAlreadyAttached,
    ClientNotAttached,
    InvalidPaneState,
};

pub fn apply(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    origin: action_mod.Origin,
    action: action_mod.Action,
    effects: *std.ArrayList(effect_mod.Effect),
) !void {
    try authorize(server, origin, action);

    switch (action) {
        .new_pane => |data| try newPane(allocator, server, data, effects),
        .pane_spawned => |pane_id| {
            const pane = server.panes.getPtr(pane_id) orelse return error.PaneNotFound;
            if (pane.state != .pending) return error.InvalidPaneState;
            pane.state = .running;
        },
        .pane_spawn_failed => |pane_id| try removePane(allocator, server, pane_id),
        .close_pane => |pane_id| try beginClose(allocator, server, pane_id, effects),
        .close_deadline => |pane_id| try advanceClose(
            allocator,
            server,
            pane_id,
            effects,
        ),
        .pane_process_exited => |pane_id| try processExited(
            allocator,
            server,
            pane_id,
            effects,
        ),
        .pane_drained => |pane_id| try removePane(allocator, server, pane_id),
        .resize_pane => |data| try resizePane(allocator, server, data, effects),
        .focus_pane => |data| try focusPane(server, data),
        .select_pane => |data| try selectPane(server, data),
        .scroll_camera => |data| try scrollCamera(server, data),
        .new_workspace => |data| try newWorkspace(allocator, server, data, effects),
        .focus_workspace => |data| try focusWorkspace(server, data.session_id, data.direction),
        .rename_session => |data| try renameSession(allocator, server, data),
        .attach_client => |data| try attachClient(allocator, server, data, effects),
        .detach_client => |client_id| try detachClient(
            allocator,
            server,
            client_id,
            effects,
            false,
        ),
        .take_size_ownership => |client_id| try takeSizeOwnership(
            allocator,
            server,
            client_id,
            effects,
        ),
        .client_resized => |data| try clientResized(
            allocator,
            server,
            data,
            effects,
        ),
    }

    if (@import("builtin").mode == .Debug) try invariant.assertInvariants(server);
}

fn authorize(
    server: *const model.ServerModel,
    origin: action_mod.Origin,
    action: action_mod.Action,
) !void {
    const client_id = switch (origin) {
        .client => |id| id,
        else => return,
    };
    const client = server.clients.get(client_id) orelse return error.ClientNotFound;
    if (!client.read_only) return;

    switch (action) {
        .detach_client => |target| if (target == client_id) return,
        else => {},
    }
    return error.ReadOnlyClient;
}

fn newPane(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    data: action_mod.NewPane,
    effects: *std.ArrayList(effect_mod.Effect),
) !void {
    const session = server.sessions.getPtr(data.session_id) orelse
        return error.SessionNotFound;
    if (server.countSessionPanes(session) >= server.limits.max_panes_per_session) {
        return error.PaneLimitReached;
    }
    const workspace_id = session.workspaces.items[session.active_workspace];
    const workspace = server.workspaces.getPtr(workspace_id) orelse
        return error.WorkspaceNotFound;
    const pane_id = try server.ids.next(ids.PaneId);
    const width = std.math.clamp(
        data.outer_width,
        server.limits.min_outer_width,
        server.limits.max_outer_width,
    );
    const pane = model.Pane.init(
        pane_id,
        workspace_id,
        width,
        session.canonical_outer_rows - 2,
    );
    const insert_at = workspace.focused_pane + 1;
    try workspace.panes.insert(allocator, insert_at, pane_id);
    errdefer _ = workspace.panes.orderedRemove(insert_at);
    try server.panes.put(allocator, pane_id, pane);
    workspace.focused_pane = insert_at;
    revealFocused(server, workspace, data.viewport_width, .right);
    try effects.append(allocator, .{ .spawn_pane = .{
        .pane_id = pane_id,
        .size = .{ .cols = pane.logical_cols, .rows = pane.logical_rows },
    } });
}

fn newWorkspace(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    data: action_mod.NewWorkspace,
    effects: *std.ArrayList(effect_mod.Effect),
) !void {
    const session = server.sessions.getPtr(data.session_id) orelse
        return error.SessionNotFound;
    if (session.workspaces.items.len >= server.limits.max_workspaces_per_session) {
        return error.WorkspaceLimitReached;
    }
    if (server.countSessionPanes(session) >= server.limits.max_panes_per_session) {
        return error.PaneLimitReached;
    }

    const workspace_id = try server.ids.next(ids.WorkspaceId);
    const pane_id = try server.ids.next(ids.PaneId);
    const width = std.math.clamp(
        data.outer_width,
        server.limits.min_outer_width,
        server.limits.max_outer_width,
    );
    var workspace: model.Workspace = .{ .id = workspace_id };
    errdefer workspace.deinit(allocator);
    try workspace.panes.append(allocator, pane_id);
    const pane = model.Pane.init(
        pane_id,
        workspace_id,
        width,
        session.canonical_outer_rows - 2,
    );

    const insert_at = session.active_workspace + 1;
    try session.workspaces.insert(allocator, insert_at, workspace_id);
    errdefer _ = session.workspaces.orderedRemove(insert_at);
    try server.workspaces.put(allocator, workspace_id, workspace);
    errdefer _ = server.workspaces.remove(workspace_id);
    try server.panes.put(allocator, pane_id, pane);
    session.active_workspace = insert_at;
    try effects.append(allocator, .{ .spawn_pane = .{
        .pane_id = pane_id,
        .size = .{ .cols = pane.logical_cols, .rows = pane.logical_rows },
    } });
}

fn beginClose(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    pane_id: ids.PaneId,
    effects: *std.ArrayList(effect_mod.Effect),
) !void {
    const pane = server.panes.getPtr(pane_id) orelse return error.PaneNotFound;
    if (pane.state != .running and pane.state != .pending) return error.InvalidPaneState;
    pane.state = .closing_hup;
    try effects.append(allocator, .{ .signal_process_group = .{
        .pane_id = pane_id,
        .signal = .hup,
    } });
    try effects.append(allocator, .{ .arm_close_timer = .{
        .pane_id = pane_id,
        .delay_ms = 1000,
    } });
}

fn advanceClose(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    pane_id: ids.PaneId,
    effects: *std.ArrayList(effect_mod.Effect),
) !void {
    const pane = server.panes.getPtr(pane_id) orelse return error.PaneNotFound;
    switch (pane.state) {
        .closing_hup => {
            pane.state = .closing_term;
            try effects.append(allocator, .{ .signal_process_group = .{
                .pane_id = pane_id,
                .signal = .term,
            } });
            try effects.append(allocator, .{ .arm_close_timer = .{
                .pane_id = pane_id,
                .delay_ms = 2000,
            } });
        },
        .closing_term => {
            pane.state = .closing_kill;
            try effects.append(allocator, .{ .signal_process_group = .{
                .pane_id = pane_id,
                .signal = .kill,
            } });
            try effects.append(allocator, .{ .arm_close_timer = .{
                .pane_id = pane_id,
                .delay_ms = 100,
            } });
        },
        .closing_kill => {
            pane.state = .draining;
            try effects.append(allocator, .{ .arm_close_timer = .{
                .pane_id = pane_id,
                .delay_ms = 100,
            } });
        },
        .draining => {},
        else => return error.InvalidPaneState,
    }
}

fn processExited(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    pane_id: ids.PaneId,
    effects: *std.ArrayList(effect_mod.Effect),
) !void {
    const pane = server.panes.getPtr(pane_id) orelse return error.PaneNotFound;
    pane.state = .draining;
    try effects.append(allocator, .{ .arm_close_timer = .{
        .pane_id = pane_id,
        .delay_ms = 100,
    } });
}

fn resizePane(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    data: action_mod.ResizePane,
    effects: *std.ArrayList(effect_mod.Effect),
) !void {
    const workspace = server.activeWorkspace(data.session_id) orelse
        return error.SessionNotFound;
    const pane_id = workspace.panes.items[workspace.focused_pane];
    const pane = server.panes.getPtr(pane_id) orelse return error.PaneNotFound;
    const old_width = pane.outer_width;
    const requested = @as(i64, old_width) + data.delta;
    pane.outer_width = @intCast(std.math.clamp(
        requested,
        server.limits.min_outer_width,
        server.limits.max_outer_width,
    ));
    pane.logical_cols = pane.outer_width - 2;
    revealFocused(server, workspace, data.viewport_width, null);

    if (pane.outer_width != old_width) {
        try effects.append(allocator, .{ .resize_pty = .{
            .pane_id = pane.id,
            .size = .{ .cols = pane.logical_cols, .rows = pane.logical_rows },
        } });
    }
}

fn focusPane(server: *model.ServerModel, data: action_mod.FocusPane) !void {
    const workspace = server.activeWorkspace(data.session_id) orelse
        return error.SessionNotFound;
    switch (data.direction) {
        .left => if (workspace.focused_pane > 0) {
            workspace.focused_pane -= 1;
        },
        .right => if (workspace.focused_pane + 1 < workspace.panes.items.len) {
            workspace.focused_pane += 1;
        },
        else => return error.InvalidDirection,
    }
    revealFocused(server, workspace, data.viewport_width, data.direction);
}

fn selectPane(server: *model.ServerModel, data: action_mod.SelectPane) !void {
    const workspace = server.activeWorkspace(data.session_id) orelse
        return error.SessionNotFound;
    for (workspace.panes.items, 0..) |pane_id, index| {
        if (pane_id != data.pane_id) continue;
        workspace.focused_pane = index;
        revealFocused(server, workspace, data.viewport_width, null);
        return;
    }
    return error.PaneNotFound;
}

fn scrollCamera(
    server: *model.ServerModel,
    data: action_mod.ScrollCamera,
) !void {
    const workspace = server.activeWorkspace(data.session_id) orelse
        return error.SessionNotFound;
    workspace.camera_x += data.delta;
    clampCamera(server, workspace, data.viewport_width);
}

fn focusWorkspace(
    server: *model.ServerModel,
    session_id: ids.SessionId,
    direction: model.Direction,
) !void {
    const session = server.sessions.getPtr(session_id) orelse return error.SessionNotFound;
    switch (direction) {
        .up => if (session.active_workspace > 0) {
            session.active_workspace -= 1;
        },
        .down => if (session.active_workspace + 1 < session.workspaces.items.len) {
            session.active_workspace += 1;
        },
        else => return error.InvalidDirection,
    }
}

fn renameSession(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    data: action_mod.RenameSession,
) !void {
    try model.validateSessionName(data.name);
    const session = server.sessions.getPtr(data.session_id) orelse
        return error.SessionNotFound;
    var iterator = server.sessions.valueIterator();
    while (iterator.next()) |candidate| {
        if (candidate.id != data.session_id and
            std.mem.eql(u8, candidate.name, data.name))
        {
            return error.DuplicateSessionName;
        }
    }
    if (std.mem.eql(u8, session.name, data.name)) return;
    const owned_name = try allocator.dupe(u8, data.name);
    allocator.free(session.name);
    session.name = owned_name;
}

fn removePane(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    pane_id: ids.PaneId,
) !void {
    const pane = server.panes.get(pane_id) orelse return error.PaneNotFound;
    const workspace = server.workspaces.getPtr(pane.workspace_id) orelse
        return error.WorkspaceNotFound;
    const pane_index = indexOf(ids.PaneId, workspace.panes.items, pane_id) orelse
        return error.PaneNotFound;
    const session_id = findOwningSession(server, workspace.id) orelse
        return error.SessionNotFound;

    if (workspace.panes.items.len > 1) {
        _ = workspace.panes.orderedRemove(pane_index);
        workspace.focused_pane = @min(workspace.focused_pane, workspace.panes.items.len - 1);
        _ = server.panes.remove(pane_id);
        clampCamera(server, workspace, 0);
        return;
    }

    const session = server.sessions.getPtr(session_id).?;
    const workspace_index = indexOf(
        ids.WorkspaceId,
        session.workspaces.items,
        workspace.id,
    ).?;
    _ = server.panes.remove(pane_id);

    if (session.workspaces.items.len > 1) {
        const removed_workspace_id = workspace.id;
        workspace.deinit(allocator);
        _ = server.workspaces.remove(removed_workspace_id);
        _ = session.workspaces.orderedRemove(workspace_index);
        if (session.active_workspace > workspace_index) session.active_workspace -= 1;
        session.active_workspace = @min(
            session.active_workspace,
            session.workspaces.items.len - 1,
        );
        return;
    }

    const only_workspace_id = workspace.id;
    workspace.deinit(allocator);
    _ = server.workspaces.remove(only_workspace_id);
    for (session.clients.items) |client_id| {
        if (server.clients.getPtr(client_id)) |client| client.attached_session = null;
    }
    session.deinit(allocator);
    _ = server.sessions.remove(session_id);
}

fn attachClient(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    data: action_mod.AttachClient,
    effects: *std.ArrayList(effect_mod.Effect),
) !void {
    const client = server.clients.getPtr(data.client_id) orelse return error.ClientNotFound;
    _ = server.sessions.get(data.session_id) orelse return error.SessionNotFound;

    if (client.attached_session) |current| {
        if (current == data.session_id) return error.ClientAlreadyAttached;
        try detachClient(allocator, server, data.client_id, effects, true);
    }

    if (data.detach_others) {
        const target = server.sessions.getPtr(data.session_id).?;
        var index: usize = target.clients.items.len;
        while (index > 0) {
            index -= 1;
            const other_id = target.clients.items[index];
            if (other_id == data.client_id) continue;
            if (server.clients.getPtr(other_id)) |other| other.attached_session = null;
            _ = target.clients.orderedRemove(index);
            try effects.append(allocator, .{ .disconnect_client = other_id });
        }
        target.size_owner = null;
    }

    const target = server.sessions.getPtr(data.session_id).?;
    try target.clients.append(allocator, data.client_id);
    client.attached_session = data.session_id;
    client.needs_full_redraw = true;
    server.markActivity(data.client_id);

    if (target.size_owner == null and !client.read_only) {
        target.size_owner = data.client_id;
        try applyOwnerSize(server, target, client.size, effects, allocator);
    }
    try effects.append(allocator, .{ .request_full_redraw = data.client_id });
}

fn detachClient(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    client_id: ids.ClientId,
    effects: *std.ArrayList(effect_mod.Effect),
    switching: bool,
) !void {
    const client = server.clients.getPtr(client_id) orelse return error.ClientNotFound;
    const session_id = client.attached_session orelse return error.ClientNotAttached;
    const session = server.sessions.getPtr(session_id) orelse return error.SessionNotFound;
    const client_index = indexOf(ids.ClientId, session.clients.items, client_id) orelse
        return error.ClientNotAttached;
    _ = session.clients.orderedRemove(client_index);
    client.attached_session = null;

    if (session.size_owner == client_id) {
        session.size_owner = selectSizeOwner(server, session);
        if (session.size_owner) |owner_id| {
            const owner = server.clients.get(owner_id).?;
            try applyOwnerSize(server, session, owner.size, effects, allocator);
        }
    }
    if (!switching) try effects.append(allocator, .{
        .disconnect_client = client_id,
    });
}

fn takeSizeOwnership(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    client_id: ids.ClientId,
    effects: *std.ArrayList(effect_mod.Effect),
) !void {
    const client = server.clients.get(client_id) orelse return error.ClientNotFound;
    if (client.read_only) return error.ReadOnlyClient;
    const session_id = client.attached_session orelse return error.ClientNotAttached;
    const session = server.sessions.getPtr(session_id) orelse return error.SessionNotFound;
    session.size_owner = client_id;
    try applyOwnerSize(server, session, client.size, effects, allocator);
}

fn clientResized(
    allocator: std.mem.Allocator,
    server: *model.ServerModel,
    data: action_mod.ClientResized,
    effects: *std.ArrayList(effect_mod.Effect),
) !void {
    if (data.size.cols == 0 or data.size.rows == 0) return error.InvalidSize;
    const client = server.clients.getPtr(data.client_id) orelse return error.ClientNotFound;
    client.size = data.size;
    client.needs_full_redraw = true;
    try effects.append(allocator, .{ .request_full_redraw = data.client_id });
    const session_id = client.attached_session orelse return;
    const session = server.sessions.getPtr(session_id) orelse return error.SessionNotFound;
    if (session.size_owner == data.client_id) {
        try applyOwnerSize(server, session, data.size, effects, allocator);
    }
}

fn applyOwnerSize(
    server: *model.ServerModel,
    session: *model.Session,
    size: model.Size,
    effects: *std.ArrayList(effect_mod.Effect),
    allocator: std.mem.Allocator,
) !void {
    session.canonical_cols = size.cols;
    session.canonical_outer_rows = @max(@as(u16, 3), size.rows -| 1);
    for (session.workspaces.items) |workspace_id| {
        const workspace = server.workspaces.get(workspace_id) orelse continue;
        for (workspace.panes.items) |pane_id| {
            const pane = server.panes.getPtr(pane_id) orelse continue;
            pane.logical_rows = session.canonical_outer_rows - 2;
            try effects.append(allocator, .{ .resize_pty = .{
                .pane_id = pane_id,
                .size = .{ .cols = pane.logical_cols, .rows = pane.logical_rows },
            } });
        }
    }
}

fn selectSizeOwner(
    server: *const model.ServerModel,
    session: *const model.Session,
) ?ids.ClientId {
    var chosen: ?ids.ClientId = null;
    var latest: u64 = 0;
    for (session.clients.items) |client_id| {
        const client = server.clients.get(client_id) orelse continue;
        if (client.read_only) continue;
        if (chosen == null or client.last_activity >= latest) {
            chosen = client_id;
            latest = client.last_activity;
        }
    }
    return chosen;
}

fn findOwningSession(
    server: *const model.ServerModel,
    workspace_id: ids.WorkspaceId,
) ?ids.SessionId {
    var iterator = server.sessions.valueIterator();
    while (iterator.next()) |session| {
        if (indexOf(ids.WorkspaceId, session.workspaces.items, workspace_id) != null) {
            return session.id;
        }
    }
    return null;
}

fn indexOf(comptime T: type, items: []const T, needle: T) ?usize {
    for (items, 0..) |item, index| {
        if (item == needle) return index;
    }
    return null;
}

fn revealFocused(
    server: *const model.ServerModel,
    workspace: *model.Workspace,
    viewport_width: u16,
    direction: ?model.Direction,
) void {
    if (workspace.panes.items.len == 0 or viewport_width == 0) return;
    var pane_left: i64 = 0;
    var world_right: i64 = 0;
    for (workspace.panes.items, 0..) |pane_id, index| {
        const width = (server.panes.get(pane_id) orelse continue).outer_width;
        if (index < workspace.focused_pane) pane_left += width;
        world_right += width;
    }
    const focused_id = workspace.panes.items[workspace.focused_pane];
    const pane_width = (server.panes.get(focused_id) orelse return).outer_width;
    const pane_right = pane_left + pane_width;
    const max_camera = @max(@as(i64, 0), world_right - viewport_width);
    var camera = std.math.clamp(workspace.camera_x, 0, max_camera);

    if (pane_width > viewport_width) {
        if (direction == .right) {
            camera = pane_left;
        } else if (direction == .left) {
            camera = pane_right - viewport_width;
        } else {
            if (pane_right <= camera) camera = pane_right - viewport_width;
            if (pane_left >= camera + viewport_width) camera = pane_left;
        }
    } else if (pane_left < camera) {
        camera = pane_left;
    } else if (pane_right > camera + viewport_width) {
        camera = pane_right - viewport_width;
    }
    workspace.camera_x = std.math.clamp(camera, 0, max_camera);
}

fn clampCamera(
    server: *const model.ServerModel,
    workspace: *model.Workspace,
    viewport_width: u16,
) void {
    var world_width: i64 = 0;
    for (workspace.panes.items) |pane_id| {
        if (server.panes.get(pane_id)) |pane| world_width += pane.outer_width;
    }
    workspace.camera_x = std.math.clamp(
        workspace.camera_x,
        0,
        @max(@as(i64, 0), world_width - viewport_width),
    );
}

test "session rename replaces the owned label through the reducer" {
    const allocator = std.testing.allocator;
    var server = model.ServerModel.init();
    defer server.deinit(allocator);
    const session_id = try server.createSession(allocator, "before", 80, 24);
    var effects: std.ArrayList(effect_mod.Effect) = .empty;
    defer effects.deinit(allocator);

    try apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .rename_session = .{
            .session_id = session_id,
            .name = "after",
        } },
        &effects,
    );
    try std.testing.expectEqualStrings(
        "after",
        server.sessions.get(session_id).?.name,
    );
    try std.testing.expectError(
        error.InvalidSessionName,
        apply(
            allocator,
            &server,
            .{ .server = {} },
            .{ .rename_session = .{
                .session_id = session_id,
                .name = "bad/name",
            } },
            &effects,
        ),
    );
}

test "new panes insert to the right without resizing existing panes" {
    const allocator = std.testing.allocator;
    var server = model.ServerModel.init();
    defer server.deinit(allocator);
    const session_id = try server.createSession(allocator, "work", 100, 30);
    const first_id = server.activeWorkspace(session_id).?.panes.items[0];
    const first_width = server.panes.get(first_id).?.outer_width;
    var effects: std.ArrayList(effect_mod.Effect) = .empty;
    defer effects.deinit(allocator);

    try apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .new_pane = .{ .session_id = session_id, .outer_width = 40 } },
        &effects,
    );

    const workspace = server.activeWorkspace(session_id).?;
    try std.testing.expectEqual(@as(usize, 2), workspace.panes.items.len);
    try std.testing.expectEqual(@as(usize, 1), workspace.focused_pane);
    try std.testing.expectEqual(first_width, server.panes.get(first_id).?.outer_width);
}

test "camera scroll moves one cell and clamps to workspace bounds" {
    const allocator = std.testing.allocator;
    var server = model.ServerModel.init();
    defer server.deinit(allocator);
    const session_id = try server.createSession(allocator, "work", 40, 24);
    var effects: std.ArrayList(effect_mod.Effect) = .empty;
    defer effects.deinit(allocator);

    try apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .scroll_camera = .{
            .session_id = session_id,
            .delta = 1,
            .viewport_width = 40,
        } },
        &effects,
    );
    try std.testing.expectEqual(
        @as(i64, 1),
        server.activeWorkspace(session_id).?.camera_x,
    );
    try apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .scroll_camera = .{
            .session_id = session_id,
            .delta = -10,
            .viewport_width = 40,
        } },
        &effects,
    );
    try std.testing.expectEqual(
        @as(i64, 0),
        server.activeWorkspace(session_id).?.camera_x,
    );
}

test "select pane focuses a stable Pane ID for mouse input" {
    const allocator = std.testing.allocator;
    var server = model.ServerModel.init();
    defer server.deinit(allocator);
    const session_id = try server.createSession(allocator, "work", 80, 24);
    var effects: std.ArrayList(effect_mod.Effect) = .empty;
    defer effects.deinit(allocator);
    try apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .new_pane = .{
            .session_id = session_id,
            .outer_width = 40,
            .viewport_width = 80,
        } },
        &effects,
    );
    const workspace = server.activeWorkspace(session_id).?;
    const first = workspace.panes.items[0];
    try apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .select_pane = .{
            .session_id = session_id,
            .pane_id = first,
            .viewport_width = 80,
        } },
        &effects,
    );
    try std.testing.expectEqual(@as(usize, 0), workspace.focused_pane);
}

test "non-owner resize never changes canonical pane rows" {
    const allocator = std.testing.allocator;
    var server = model.ServerModel.init();
    defer server.deinit(allocator);
    const session_id = try server.createSession(allocator, "work", 80, 24);
    const owner = try server.addClient(allocator, .{ .cols = 80, .rows = 24 }, false);
    const observer = try server.addClient(allocator, .{ .cols = 120, .rows = 50 }, false);
    var effects: std.ArrayList(effect_mod.Effect) = .empty;
    defer effects.deinit(allocator);

    try apply(allocator, &server, .{ .server = {} }, .{ .attach_client = .{
        .client_id = owner,
        .session_id = session_id,
    } }, &effects);
    try apply(allocator, &server, .{ .server = {} }, .{ .attach_client = .{
        .client_id = observer,
        .session_id = session_id,
    } }, &effects);
    effects.clearRetainingCapacity();

    try apply(allocator, &server, .{ .server = {} }, .{ .client_resized = .{
        .client_id = observer,
        .size = .{ .cols = 200, .rows = 70 },
    } }, &effects);

    const session = server.sessions.get(session_id).?;
    try std.testing.expectEqual(@as(u16, 23), session.canonical_outer_rows);
    var resize_count: usize = 0;
    for (effects.items) |item| if (item == .resize_pty) {
        resize_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), resize_count);
}
