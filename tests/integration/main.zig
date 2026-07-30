const std = @import("std");
const noren = @import("noren");

test "model lifecycle preserves workspace and session semantics" {
    const allocator = std.testing.allocator;
    var server = noren.core.model.ServerModel.init();
    defer server.deinit(allocator);
    var effects: std.ArrayList(noren.core.effect.Effect) = .empty;
    defer effects.deinit(allocator);

    const session_id = try server.createSession(allocator, "work", 100, 30);
    const first_pane = server.activeWorkspace(session_id).?.panes.items[0];
    try noren.core.reducer.apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .pane_spawned = first_pane },
        &effects,
    );

    try noren.core.reducer.apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .new_pane = .{
            .session_id = session_id,
            .outer_width = 36,
            .viewport_width = 60,
        } },
        &effects,
    );
    const second_pane = server.activeWorkspace(session_id).?.panes.items[1];
    try noren.core.reducer.apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .pane_spawned = second_pane },
        &effects,
    );

    try noren.core.reducer.apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .new_workspace = .{ .session_id = session_id, .outer_width = 50 } },
        &effects,
    );
    const session_after_new = server.sessions.get(session_id).?;
    try std.testing.expectEqual(@as(usize, 2), session_after_new.workspaces.items.len);
    try std.testing.expectEqual(@as(usize, 1), session_after_new.active_workspace);

    const last_workspace_pane = server.activeWorkspace(session_id).?.panes.items[0];
    try noren.core.reducer.apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .pane_spawned = last_workspace_pane },
        &effects,
    );
    try noren.core.reducer.apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .close_pane = last_workspace_pane },
        &effects,
    );
    try noren.core.reducer.apply(
        allocator,
        &server,
        .{ .child_exit = last_workspace_pane },
        .{ .pane_process_exited = last_workspace_pane },
        &effects,
    );
    try noren.core.reducer.apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .pane_drained = last_workspace_pane },
        &effects,
    );

    const final_session = server.sessions.get(session_id).?;
    try std.testing.expectEqual(@as(usize, 1), final_session.workspaces.items.len);
    try std.testing.expectEqual(@as(usize, 0), final_session.active_workspace);
    try std.testing.expectEqual(@as(usize, 2), server.countSessionPanes(&final_session));
    try noren.core.invariant.assertInvariants(&server);
}

test "size ownership transfers deterministically and excludes read-only clients" {
    const allocator = std.testing.allocator;
    var server = noren.core.model.ServerModel.init();
    defer server.deinit(allocator);
    var effects: std.ArrayList(noren.core.effect.Effect) = .empty;
    defer effects.deinit(allocator);

    const session_id = try server.createSession(allocator, "shared", 80, 24);
    const first = try server.addClient(allocator, .{ .cols = 80, .rows = 24 }, false);
    const second = try server.addClient(allocator, .{ .cols = 100, .rows = 40 }, false);
    const observer = try server.addClient(allocator, .{ .cols = 200, .rows = 70 }, true);

    for ([_]noren.core.ids.ClientId{ first, second, observer }) |client_id| {
        try noren.core.reducer.apply(
            allocator,
            &server,
            .{ .server = {} },
            .{ .attach_client = .{
                .client_id = client_id,
                .session_id = session_id,
            } },
            &effects,
        );
    }
    try std.testing.expectEqual(first, server.sessions.get(session_id).?.size_owner.?);

    server.markActivity(second);
    try noren.core.reducer.apply(
        allocator,
        &server,
        .{ .client = first },
        .{ .detach_client = first },
        &effects,
    );
    try std.testing.expectEqual(second, server.sessions.get(session_id).?.size_owner.?);
    try std.testing.expectEqual(
        @as(u16, 39),
        server.sessions.get(session_id).?.canonical_outer_rows,
    );

    try std.testing.expectError(
        error.ReadOnlyClient,
        noren.core.reducer.apply(
            allocator,
            &server,
            .{ .client = observer },
            .{ .new_pane = .{
                .session_id = session_id,
                .outer_width = 20,
                .viewport_width = 80,
            } },
            &effects,
        ),
    );
    try noren.core.invariant.assertInvariants(&server);
}

test "last pane removal ends the session but leaves clients allocated" {
    const allocator = std.testing.allocator;
    var server = noren.core.model.ServerModel.init();
    defer server.deinit(allocator);
    var effects: std.ArrayList(noren.core.effect.Effect) = .empty;
    defer effects.deinit(allocator);

    const session_id = try server.createSession(allocator, "short", 80, 24);
    const client_id = try server.addClient(allocator, .{ .cols = 80, .rows = 24 }, false);
    try noren.core.reducer.apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .attach_client = .{
            .client_id = client_id,
            .session_id = session_id,
        } },
        &effects,
    );
    const pane_id = server.activeWorkspace(session_id).?.panes.items[0];
    try noren.core.reducer.apply(
        allocator,
        &server,
        .{ .server = {} },
        .{ .pane_drained = pane_id },
        &effects,
    );

    try std.testing.expect(server.sessions.get(session_id) == null);
    try std.testing.expect(server.clients.get(client_id).?.attached_session == null);
    try noren.core.invariant.assertInvariants(&server);
}
