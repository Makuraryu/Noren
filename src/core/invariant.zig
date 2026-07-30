const std = @import("std");
const model = @import("model.zig");
const ids = @import("ids.zig");

pub const InvariantError = error{
    SessionWithoutWorkspace,
    ActiveWorkspaceOutOfBounds,
    MissingWorkspace,
    WorkspaceOwnedByMultipleSessions,
    WorkspaceWithoutPane,
    FocusedPaneOutOfBounds,
    MissingPane,
    PaneOwnedByMultipleWorkspaces,
    PaneWorkspaceMismatch,
    PaneWidthOutOfBounds,
    InvalidLogicalPaneSize,
    MissingClient,
    ClientAttachmentMismatch,
    SizeOwnerNotAttached,
    SizeOwnerReadOnly,
    OrphanWorkspace,
    OrphanPane,
    OrphanAttachedClient,
};

/// Validate ownership and all model-side product invariants after an Action
/// batch. This intentionally does no allocation so it is safe to enable in
/// Debug builds on every reducer turn.
pub fn assertInvariants(server: *const model.ServerModel) InvariantError!void {
    var seen_workspaces: usize = 0;
    var seen_panes: usize = 0;

    var session_it = server.sessions.valueIterator();
    while (session_it.next()) |session| {
        if (session.workspaces.items.len == 0) return error.SessionWithoutWorkspace;
        if (session.active_workspace >= session.workspaces.items.len) {
            return error.ActiveWorkspaceOutOfBounds;
        }

        for (session.workspaces.items, 0..) |workspace_id, index| {
            const workspace = server.workspaces.get(workspace_id) orelse
                return error.MissingWorkspace;
            seen_workspaces += 1;

            for (session.workspaces.items[0..index]) |prior| {
                if (prior == workspace_id) return error.WorkspaceOwnedByMultipleSessions;
            }
            if (workspace.panes.items.len == 0) return error.WorkspaceWithoutPane;
            if (workspace.focused_pane >= workspace.panes.items.len) {
                return error.FocusedPaneOutOfBounds;
            }

            for (workspace.panes.items, 0..) |pane_id, pane_index| {
                const pane = server.panes.get(pane_id) orelse return error.MissingPane;
                seen_panes += 1;
                for (workspace.panes.items[0..pane_index]) |prior| {
                    if (prior == pane_id) return error.PaneOwnedByMultipleWorkspaces;
                }
                if (pane.workspace_id != workspace_id) return error.PaneWorkspaceMismatch;
                if (pane.outer_width < server.limits.min_outer_width or
                    pane.outer_width > server.limits.max_outer_width)
                {
                    return error.PaneWidthOutOfBounds;
                }
                if (pane.logical_cols != pane.outer_width - 2 or pane.logical_rows == 0) {
                    return error.InvalidLogicalPaneSize;
                }
            }
        }

        for (session.clients.items, 0..) |client_id, client_index| {
            const client = server.clients.get(client_id) orelse return error.MissingClient;
            for (session.clients.items[0..client_index]) |prior| {
                if (prior == client_id) return error.ClientAttachmentMismatch;
            }
            if (client.attached_session != session.id) return error.ClientAttachmentMismatch;
        }

        if (session.size_owner) |owner_id| {
            const owner = server.clients.get(owner_id) orelse return error.MissingClient;
            if (owner.read_only) return error.SizeOwnerReadOnly;
            if (owner.attached_session != session.id or
                indexOf(ids.ClientId, session.clients.items, owner_id) == null)
            {
                return error.SizeOwnerNotAttached;
            }
        }
    }

    if (seen_workspaces != server.workspaces.count()) return error.OrphanWorkspace;
    if (seen_panes != server.panes.count()) return error.OrphanPane;

    var client_it = server.clients.valueIterator();
    while (client_it.next()) |client| {
        if (client.attached_session) |session_id| {
            const session = server.sessions.get(session_id) orelse
                return error.OrphanAttachedClient;
            if (indexOf(ids.ClientId, session.clients.items, client.id) == null) {
                return error.ClientAttachmentMismatch;
            }
        }
    }
}

fn indexOf(comptime T: type, items: []const T, needle: T) ?usize {
    for (items, 0..) |item, index| {
        if (item == needle) return index;
    }
    return null;
}

test "invariants detect a dangling pane reference" {
    const allocator = std.testing.allocator;
    var server = model.ServerModel.init();
    defer server.deinit(allocator);
    const session_id = try server.createSession(allocator, "work", 80, 24);
    try assertInvariants(&server);

    const workspace = server.activeWorkspace(session_id).?;
    const pane_id = workspace.panes.items[0];
    _ = server.panes.remove(pane_id);
    try std.testing.expectError(error.MissingPane, assertInvariants(&server));
}
