const std = @import("std");
const transport = @import("transport.zig");
const reactor = @import("reactor.zig");
const frame = @import("../protocol/frame.zig");
const control = @import("../protocol/control.zig");
const pty_mod = @import("../os/pty.zig");
const terminal_mod = @import("../terminal/backend.zig");
const session_render = @import("../render/session.zig");
const layout_workspace = @import("../layout/workspace.zig");
const ids = @import("../core/ids.zig");
const model_mod = @import("../core/model.zig");
const action_mod = @import("../core/action.zig");
const effect_mod = @import("../core/effect.zig");
const reducer = @import("../core/reducer.zig");
const BoundedByteQueue = @import("../core/bounded_queue.zig").BoundedByteQueue;

const default_outer_rows: u16 = 24;
const default_outer_cols: u16 = 80;
const default_pane_width: u16 = 80;
const pane_input_limit: usize = 1024 * 1024;
const client_output_limit: usize = 4 * 1024 * 1024;
const max_poll_entries: usize = 258;

pub const Options = struct {
    argv: []const []const u8,
    default_argv: []const []const u8,
    cwd: ?[]const u8,
    environment: []const []const u8,
    session_name: []const u8,
    socket_path: []const u8,
};

const PaneRuntime = struct {
    pty: pty_mod.Pty,
    backend: terminal_mod.TerminalBackend,
    input: BoundedByteQueue = BoundedByteQueue.init(pane_input_limit),
    child_reaped: bool = false,
    pty_eof: bool = false,
    close_deadline_ms: ?u64 = null,

    fn deinit(self: *PaneRuntime, allocator: std.mem.Allocator) void {
        if (!self.child_reaped) shutdownChild(&self.pty);
        self.pty.close();
        self.backend.deinit();
        self.input.deinit(allocator);
        self.* = undefined;
    }
};

const PollTarget = union(enum) {
    listener,
    client,
    pane: ids.PaneId,
};

pub fn run(allocator: std.mem.Allocator, options: Options) !void {
    var listener = try transport.Listener.init(allocator, options.socket_path);
    defer listener.deinit();

    var model = model_mod.ServerModel.init();
    defer model.deinit(allocator);
    const session_id = try model.createSession(
        allocator,
        options.session_name,
        default_outer_cols,
        default_outer_rows - 1,
    );
    const initial_pane_id = model.activeWorkspace(session_id).?.panes.items[0];

    var panes: std.AutoHashMapUnmanaged(ids.PaneId, PaneRuntime) = .empty;
    defer {
        var iterator = panes.valueIterator();
        while (iterator.next()) |pane| pane.deinit(allocator);
        panes.deinit(allocator);
    }
    const initial_model = model.panes.get(initial_pane_id).?;
    try spawnPaneRuntime(
        allocator,
        &panes,
        initial_pane_id,
        .{ .cols = initial_model.logical_cols, .rows = initial_model.logical_rows },
        options.argv,
        options.cwd,
        options.environment,
    );
    try applySimple(
        allocator,
        &model,
        .{ .pane_spawned = initial_pane_id },
    );

    var renderer: session_render.Renderer = .{};
    defer renderer.deinit(allocator);
    var client: ?transport.Stream = null;
    defer if (client) |*stream| stream.close();
    var parser: frame.Parser = .{};
    defer parser.deinit(allocator);
    var output_queue = BoundedByteQueue.init(client_output_limit);
    defer output_queue.deinit(allocator);
    var attached = false;
    var outer_rows = default_outer_rows;
    var outer_cols = default_outer_cols;
    var render_needed = false;
    var force_full = true;
    var ever_attached = false;
    var rendered_after_attach = false;
    var startup_grace_ticks: usize = 100;

    while (model.sessions.count() > 0 and panes.count() > 0) {
        var fds: [max_poll_entries]c_int = undefined;
        var interests: [max_poll_entries]reactor.Interest = undefined;
        var ready: [max_poll_entries]reactor.Ready = undefined;
        var targets: [max_poll_entries]PollTarget = undefined;
        var count: usize = 0;
        addPollEntry(
            &fds,
            &interests,
            &targets,
            &count,
            listener.fd,
            .{ .read = true },
            .listener,
        );
        addPollEntry(
            &fds,
            &interests,
            &targets,
            &count,
            if (client) |stream| stream.fd else -1,
            .{ .read = true, .write = output_queue.len() > 0 },
            .client,
        );
        var pane_iterator = panes.iterator();
        var waiting_for_terminal_completion = false;
        while (pane_iterator.next()) |entry| {
            if (entry.value_ptr.pty_eof) {
                waiting_for_terminal_completion = true;
                continue;
            }
            addPollEntry(
                &fds,
                &interests,
                &targets,
                &count,
                entry.value_ptr.pty.master_fd,
                .{
                    .read = !entry.value_ptr.pty_eof,
                    .write = entry.value_ptr.input.len() > 0,
                },
                .{ .pane = entry.key_ptr.* },
            );
        }
        var poll_timeout_ms: i32 =
            if (!ever_attached and waiting_for_terminal_completion) 20 else -1;
        poll_timeout_ms = nextTimerTimeout(&panes, poll_timeout_ms);
        try reactor.poll(
            fds[0..count],
            interests[0..count],
            ready[0..count],
            poll_timeout_ms,
        );

        for (targets[0..count], ready[0..count]) |target, event| {
            switch (target) {
                .listener => if (event.read) acceptClient(
                    allocator,
                    &listener,
                    &client,
                    &parser,
                    &output_queue,
                    &attached,
                    &force_full,
                ),
                .client => {
                    if (event.read and client != null) {
                        readClient(
                            allocator,
                            &client,
                            &parser,
                            &output_queue,
                            &attached,
                            &outer_rows,
                            &outer_cols,
                            &model,
                            session_id,
                            &panes,
                            options,
                            &render_needed,
                            &force_full,
                            &ever_attached,
                            &rendered_after_attach,
                        ) catch |err| {
                            std.debug.print(
                                "noren: client request failed: {s}\n",
                                .{@errorName(err)},
                            );
                            disconnect(
                                &client,
                                &parser,
                                &output_queue,
                                allocator,
                                &attached,
                            );
                        };
                    }
                    if (event.write and client != null) {
                        flushOutput(&client.?, &output_queue) catch {
                            disconnect(
                                &client,
                                &parser,
                                &output_queue,
                                allocator,
                                &attached,
                            );
                        };
                    }
                },
                .pane => |pane_id| if (event.read) {
                    if (panes.getPtr(pane_id)) |pane| {
                        try drainPane(allocator, pane);
                    }
                },
            }
        }

        var runtime_iterator = panes.iterator();
        while (runtime_iterator.next()) |entry| {
            if (!entry.value_ptr.pty_eof) {
                try flushPaneInput(entry.value_ptr);
            }
            if (entry.value_ptr.backend.takeDamage()) render_needed = true;
        }
        try fireCloseTimers(allocator, &model, &panes, options);

        var completed: [256]ids.PaneId = undefined;
        var completed_count: usize = 0;
        var wait_iterator = panes.iterator();
        while (wait_iterator.next()) |entry| {
            const runtime = entry.value_ptr;
            if (!runtime.child_reaped) {
                switch (try runtime.pty.wait(true)) {
                    .running => {},
                    .exited => runtime.child_reaped = true,
                }
            }
            if (runtime.child_reaped and runtime.pty_eof) {
                completed[completed_count] = entry.key_ptr.*;
                completed_count += 1;
            }
        }
        for (completed[0..completed_count]) |pane_id| {
            const final_pane = panes.count() == 1;
            if (final_pane and !ever_attached and startup_grace_ticks > 0) {
                startup_grace_ticks -= 1;
                continue;
            }
            if (final_pane and attached and
                (!rendered_after_attach or output_queue.len() > 0))
            {
                continue;
            }
            try finishPane(allocator, &model, &panes, pane_id);
            render_needed = true;
            if (model.sessions.count() > 0) {
                try revealActive(allocator, &model, session_id, outer_cols, null);
            }
        }

        if (attached and client != null and render_needed and
            model.sessions.count() > 0)
        {
            sendRender(
                allocator,
                &output_queue,
                &renderer,
                &model,
                session_id,
                &panes,
                outer_cols,
                outer_rows,
                options.session_name,
                force_full,
            ) catch |err| {
                std.debug.print(
                    "noren: render failed: {s}\n",
                    .{@errorName(err)},
                );
                disconnect(
                    &client,
                    &parser,
                    &output_queue,
                    allocator,
                    &attached,
                );
            };
            render_needed = false;
            force_full = false;
            rendered_after_attach = true;
        }
    }
}

fn addPollEntry(
    fds: *[max_poll_entries]c_int,
    interests: *[max_poll_entries]reactor.Interest,
    targets: *[max_poll_entries]PollTarget,
    count: *usize,
    fd: c_int,
    interest: reactor.Interest,
    target: PollTarget,
) void {
    fds[count.*] = fd;
    interests[count.*] = interest;
    targets[count.*] = target;
    count.* += 1;
}

fn acceptClient(
    allocator: std.mem.Allocator,
    listener: *transport.Listener,
    client: *?transport.Stream,
    parser: *frame.Parser,
    output_queue: *BoundedByteQueue,
    attached: *bool,
    force_full: *bool,
) void {
    var incoming = listener.accept() catch return;
    if (client.* != null and attached.*) {
        incoming.close();
        return;
    }
    if (client.*) |*stream| stream.close();
    client.* = incoming;
    parser.deinit(allocator);
    parser.* = .{};
    output_queue.consume(output_queue.len());
    attached.* = false;
    force_full.* = true;
}

fn readClient(
    allocator: std.mem.Allocator,
    client: *?transport.Stream,
    parser: *frame.Parser,
    output_queue: *BoundedByteQueue,
    attached: *bool,
    outer_rows: *u16,
    outer_cols: *u16,
    model: *model_mod.ServerModel,
    session_id: ids.SessionId,
    panes: *std.AutoHashMapUnmanaged(ids.PaneId, PaneRuntime),
    options: Options,
    render_needed: *bool,
    force_full: *bool,
    ever_attached: *bool,
    rendered_after_attach: *bool,
) !void {
    var buffer: [64 * 1024]u8 = undefined;
    switch (try client.*.?.read(&buffer)) {
        .data => |bytes| {
            try parser.feed(allocator, bytes);
            while (try parser.next(allocator)) |owned| {
                var message = owned;
                defer message.deinit(allocator);
                try handleMessage(
                    allocator,
                    client,
                    output_queue,
                    attached,
                    outer_rows,
                    outer_cols,
                    model,
                    session_id,
                    panes,
                    options,
                    render_needed,
                    force_full,
                    ever_attached,
                    rendered_after_attach,
                    message,
                );
                if (client.* == null) break;
            }
        },
        .would_block => {},
        .eof => disconnect(client, parser, output_queue, allocator, attached),
    }
}

fn handleMessage(
    allocator: std.mem.Allocator,
    client: *?transport.Stream,
    output_queue: *BoundedByteQueue,
    attached: *bool,
    outer_rows: *u16,
    outer_cols: *u16,
    model: *model_mod.ServerModel,
    session_id: ids.SessionId,
    panes: *std.AutoHashMapUnmanaged(ids.PaneId, PaneRuntime),
    options: Options,
    render_needed: *bool,
    force_full: *bool,
    ever_attached: *bool,
    rendered_after_attach: *bool,
    message: frame.OwnedFrame,
) !void {
    if (message.header.version.major != 1) return error.ProtocolVersionMismatch;
    switch (message.header.kind) {
        .hello => try queueFrame(
            allocator,
            output_queue,
            .welcome,
            message.header.request_id,
            "{\"major\":1,\"minor\":0}",
        ),
        .attach_request => {
            var parsed = try control.decode(control.Attach, allocator, message.payload);
            defer parsed.deinit();
            const session = model.sessions.get(session_id) orelse
                return error.SessionNotFound;
            if (!std.mem.eql(u8, parsed.value.target, session.name)) {
                try queueFrame(
                    allocator,
                    output_queue,
                    .error_message,
                    message.header.request_id,
                    "{\"error\":\"session-not-found\"}",
                );
                return;
            }
            try applySize(
                allocator,
                model,
                session_id,
                panes,
                parsed.value.rows,
                parsed.value.cols,
                outer_rows,
                outer_cols,
            );
            const payload = try control.encode(allocator, control.Attached{
                .session = session.name,
            });
            defer allocator.free(payload);
            try queueFrame(
                allocator,
                output_queue,
                .attached,
                message.header.request_id,
                payload,
            );
            attached.* = true;
            ever_attached.* = true;
            render_needed.* = true;
            force_full.* = true;
            rendered_after_attach.* = false;
        },
        .client_resize => {
            if (!attached.*) return;
            var parsed = try control.decode(control.Resize, allocator, message.payload);
            defer parsed.deinit();
            try applySize(
                allocator,
                model,
                session_id,
                panes,
                parsed.value.rows,
                parsed.value.cols,
                outer_rows,
                outer_cols,
            );
            render_needed.* = true;
            force_full.* = true;
        },
        .input_bytes => if (attached.*) {
            const pane_id = focusedPaneId(model, session_id) orelse return;
            const runtime = panes.getPtr(pane_id) orelse return;
            try runtime.input.append(allocator, message.payload);
        },
        .command_request => if (attached.*) {
            var parsed = try control.decode(control.Command, allocator, message.payload);
            defer parsed.deinit();
            handleCommand(
                allocator,
                model,
                session_id,
                panes,
                options,
                outer_cols.*,
                parsed.value.command,
            ) catch |err| switch (err) {
                error.InvalidPaneState,
                error.PaneLimitReached,
                error.WorkspaceLimitReached,
                error.InvalidDirection,
                error.PaneNotFound,
                error.WorkspaceNotFound,
                error.SessionNotFound,
                error.UnknownCommand,
                => {
                    var notice_buffer: [128]u8 = undefined;
                    const notice = try std.fmt.bufPrint(
                        &notice_buffer,
                        "{{\"error\":\"{s}\"}}",
                        .{@errorName(err)},
                    );
                    try queueFrame(
                        allocator,
                        output_queue,
                        .notice,
                        message.header.request_id,
                        notice,
                    );
                    return;
                },
                else => return err,
            };
            render_needed.* = true;
        },
        .detach_request => {
            client.*.?.close();
            client.* = null;
            output_queue.consume(output_queue.len());
            attached.* = false;
        },
        .ping => try queueFrame(
            allocator,
            output_queue,
            .pong,
            message.header.request_id,
            "{}",
        ),
        else => {},
    }
}

fn handleCommand(
    allocator: std.mem.Allocator,
    model: *model_mod.ServerModel,
    session_id: ids.SessionId,
    panes: *std.AutoHashMapUnmanaged(ids.PaneId, PaneRuntime),
    options: Options,
    viewport_width: u16,
    command: []const u8,
) !void {
    const action: action_mod.Action = if (std.mem.eql(u8, command, "new-pane"))
        .{ .new_pane = .{
            .session_id = session_id,
            .outer_width = default_pane_width,
            .viewport_width = viewport_width,
        } }
    else if (std.mem.eql(u8, command, "new-workspace"))
        .{ .new_workspace = .{
            .session_id = session_id,
            .outer_width = default_pane_width,
        } }
    else if (std.mem.eql(u8, command, "focus-left"))
        .{ .focus_pane = .{
            .session_id = session_id,
            .direction = .left,
            .viewport_width = viewport_width,
        } }
    else if (std.mem.eql(u8, command, "focus-right"))
        .{ .focus_pane = .{
            .session_id = session_id,
            .direction = .right,
            .viewport_width = viewport_width,
        } }
    else if (std.mem.eql(u8, command, "focus-up"))
        .{ .focus_workspace = .{
            .session_id = session_id,
            .direction = .up,
        } }
    else if (std.mem.eql(u8, command, "focus-down"))
        .{ .focus_workspace = .{
            .session_id = session_id,
            .direction = .down,
        } }
    else if (std.mem.eql(u8, command, "resize-narrower"))
        .{ .resize_pane = .{
            .session_id = session_id,
            .delta = -5,
            .viewport_width = viewport_width,
        } }
    else if (std.mem.eql(u8, command, "resize-wider"))
        .{ .resize_pane = .{
            .session_id = session_id,
            .delta = 5,
            .viewport_width = viewport_width,
        } }
    else if (std.mem.eql(u8, command, "close-pane"))
        .{ .close_pane = focusedPaneId(model, session_id) orelse return }
    else
        return error.UnknownCommand;
    try dispatch(
        allocator,
        model,
        panes,
        options,
        action,
    );
}

fn dispatch(
    allocator: std.mem.Allocator,
    model: *model_mod.ServerModel,
    panes: *std.AutoHashMapUnmanaged(ids.PaneId, PaneRuntime),
    options: Options,
    action: action_mod.Action,
) !void {
    var effects: std.ArrayList(effect_mod.Effect) = .empty;
    defer effects.deinit(allocator);
    try reducer.apply(
        allocator,
        model,
        .{ .server = {} },
        action,
        &effects,
    );
    try executeEffects(allocator, model, panes, options, effects.items);
}

fn executeEffects(
    allocator: std.mem.Allocator,
    model: *model_mod.ServerModel,
    panes: *std.AutoHashMapUnmanaged(ids.PaneId, PaneRuntime),
    options: Options,
    effects: []const effect_mod.Effect,
) !void {
    for (effects) |effect| switch (effect) {
        .spawn_pane => |spawn| {
            spawnPaneRuntime(
                allocator,
                panes,
                spawn.pane_id,
                spawn.size,
                options.default_argv,
                options.cwd,
                options.environment,
            ) catch {
                try applySimple(
                    allocator,
                    model,
                    .{ .pane_spawn_failed = spawn.pane_id },
                );
                continue;
            };
            try applySimple(
                allocator,
                model,
                .{ .pane_spawned = spawn.pane_id },
            );
        },
        .resize_pty => |resize| {
            if (panes.getPtr(resize.pane_id)) |pane| {
                try pane.pty.resize(.{
                    .rows = resize.size.rows,
                    .cols = resize.size.cols,
                });
                try pane.backend.resize(resize.size.rows, resize.size.cols);
            }
        },
        .signal_process_group => |signal| {
            if (panes.getPtr(signal.pane_id)) |pane| {
                pane.pty.signalGroup(switch (signal.signal) {
                    .hup => .hup,
                    .term => .term,
                    .kill => .kill,
                }) catch {};
            }
        },
        .arm_close_timer,
        => |timer| {
            if (panes.getPtr(timer.pane_id)) |pane| {
                pane.close_deadline_ms =
                    reactor.nowMillis() + timer.delay_ms;
            }
        },
        .request_full_redraw, .disconnect_client => {},
    };
}

fn nextTimerTimeout(
    panes: *const std.AutoHashMapUnmanaged(ids.PaneId, PaneRuntime),
    fallback_ms: i32,
) i32 {
    const now = reactor.nowMillis();
    var result = fallback_ms;
    var iterator = panes.valueIterator();
    while (iterator.next()) |pane| {
        const deadline = pane.close_deadline_ms orelse continue;
        const remaining: u64 = if (deadline <= now) 0 else deadline - now;
        const bounded: i32 = @intCast(@min(
            remaining,
            @as(u64, std.math.maxInt(i32)),
        ));
        if (result < 0 or bounded < result) result = bounded;
    }
    return result;
}

fn fireCloseTimers(
    allocator: std.mem.Allocator,
    model: *model_mod.ServerModel,
    panes: *std.AutoHashMapUnmanaged(ids.PaneId, PaneRuntime),
    options: Options,
) !void {
    const now = reactor.nowMillis();
    var due: [256]ids.PaneId = undefined;
    var due_count: usize = 0;
    var iterator = panes.iterator();
    while (iterator.next()) |entry| {
        const deadline = entry.value_ptr.close_deadline_ms orelse continue;
        if (deadline > now) continue;
        entry.value_ptr.close_deadline_ms = null;
        due[due_count] = entry.key_ptr.*;
        due_count += 1;
    }
    for (due[0..due_count]) |pane_id| {
        if (!model.panes.contains(pane_id)) continue;
        try dispatch(
            allocator,
            model,
            panes,
            options,
            .{ .close_deadline = pane_id },
        );
    }
}

fn applySimple(
    allocator: std.mem.Allocator,
    model: *model_mod.ServerModel,
    action: action_mod.Action,
) !void {
    var ignored: std.ArrayList(effect_mod.Effect) = .empty;
    defer ignored.deinit(allocator);
    try reducer.apply(
        allocator,
        model,
        .{ .server = {} },
        action,
        &ignored,
    );
}

fn spawnPaneRuntime(
    allocator: std.mem.Allocator,
    panes: *std.AutoHashMapUnmanaged(ids.PaneId, PaneRuntime),
    pane_id: ids.PaneId,
    size: model_mod.Size,
    argv: []const []const u8,
    cwd: ?[]const u8,
    base_environment: []const []const u8,
) !void {
    const environment = try environmentForPane(
        allocator,
        base_environment,
        pane_id,
    );
    defer {
        if (environment.replacement) |value| allocator.free(value);
        allocator.free(environment.entries);
    }
    var pty = try pty_mod.Pty.spawn(allocator, .{
        .argv = argv,
        .cwd = cwd,
        .environment = environment.entries,
        .size = .{ .rows = size.rows, .cols = size.cols },
    });
    errdefer {
        shutdownChild(&pty);
        pty.close();
    }
    var backend = try terminal_mod.TerminalBackend.init(size.rows, size.cols);
    errdefer backend.deinit();
    try panes.put(allocator, pane_id, .{
        .pty = pty,
        .backend = backend,
    });
}

const PaneEnvironment = struct {
    entries: [][]const u8,
    replacement: ?[]u8,
};

fn environmentForPane(
    allocator: std.mem.Allocator,
    base: []const []const u8,
    pane_id: ids.PaneId,
) !PaneEnvironment {
    const entries = try allocator.alloc([]const u8, base.len);
    errdefer allocator.free(entries);
    var replacement: ?[]u8 = null;
    errdefer if (replacement) |value| allocator.free(value);
    for (base, 0..) |entry, index| {
        if (std.mem.startsWith(u8, entry, "NOREN_PANE=")) {
            const value = try std.fmt.allocPrint(
                allocator,
                "NOREN_PANE=p{d}",
                .{ids.value(pane_id)},
            );
            replacement = value;
            entries[index] = value;
        } else {
            entries[index] = entry;
        }
    }
    return .{ .entries = entries, .replacement = replacement };
}

fn applySize(
    allocator: std.mem.Allocator,
    model: *model_mod.ServerModel,
    session_id: ids.SessionId,
    panes: *std.AutoHashMapUnmanaged(ids.PaneId, PaneRuntime),
    rows: u16,
    cols: u16,
    outer_rows: *u16,
    outer_cols: *u16,
) !void {
    if (rows < 4 or cols < 3) return error.TerminalTooSmall;
    outer_rows.* = rows;
    outer_cols.* = cols;
    const session = model.sessions.getPtr(session_id) orelse
        return error.SessionNotFound;
    session.canonical_cols = cols;
    session.canonical_outer_rows = rows - 1;
    for (session.workspaces.items) |workspace_id| {
        const workspace = model.workspaces.get(workspace_id) orelse continue;
        for (workspace.panes.items) |pane_id| {
            const pane_model = model.panes.getPtr(pane_id) orelse continue;
            pane_model.logical_rows = session.canonical_outer_rows - 2;
            if (panes.getPtr(pane_id)) |pane| {
                try pane.pty.resize(.{
                    .rows = pane_model.logical_rows,
                    .cols = pane_model.logical_cols,
                });
                try pane.backend.resize(
                    pane_model.logical_rows,
                    pane_model.logical_cols,
                );
            }
        }
    }
    try revealActive(allocator, model, session_id, cols, null);
}

fn revealActive(
    allocator: std.mem.Allocator,
    model: *model_mod.ServerModel,
    session_id: ids.SessionId,
    viewport_width: u16,
    direction: ?model_mod.Direction,
) !void {
    const workspace = model.activeWorkspace(session_id) orelse return;
    const snapshot = try layout_workspace.snapshotFromModel(
        allocator,
        model,
        workspace,
    );
    defer allocator.free(snapshot.panes);
    workspace.camera_x = try layout_workspace.revealForSnapshot(
        allocator,
        snapshot,
        viewport_width,
        direction,
    );
}

fn focusedPaneId(
    model: *model_mod.ServerModel,
    session_id: ids.SessionId,
) ?ids.PaneId {
    const workspace = model.activeWorkspace(session_id) orelse return null;
    if (workspace.focused_pane >= workspace.panes.items.len) return null;
    return workspace.panes.items[workspace.focused_pane];
}

fn drainPane(allocator: std.mem.Allocator, pane: *PaneRuntime) !void {
    var buffer: [16 * 1024]u8 = undefined;
    var budget: usize = 0;
    while (budget < 256 * 1024) {
        switch (try pane.pty.read(&buffer)) {
            .data => |bytes| {
                budget += bytes.len;
                try pane.backend.feed(bytes);
                var response: [4096]u8 = undefined;
                while (true) {
                    const bytes_out = pane.backend.takeOutput(&response);
                    if (bytes_out.len == 0) break;
                    try pane.input.append(allocator, bytes_out);
                }
            },
            .would_block => break,
            .eof => {
                pane.pty_eof = true;
                break;
            },
        }
    }
}

fn flushPaneInput(pane: *PaneRuntime) !void {
    while (pane.input.len() > 0) {
        switch (try pane.pty.write(pane.input.peek())) {
            .written => |count| pane.input.consume(count),
            .would_block => break,
        }
    }
}

fn finishPane(
    allocator: std.mem.Allocator,
    model: *model_mod.ServerModel,
    panes: *std.AutoHashMapUnmanaged(ids.PaneId, PaneRuntime),
    pane_id: ids.PaneId,
) !void {
    try applySimple(
        allocator,
        model,
        .{ .pane_process_exited = pane_id },
    );
    if (panes.fetchRemove(pane_id)) |removed| {
        var runtime = removed.value;
        runtime.deinit(allocator);
    }
    try applySimple(
        allocator,
        model,
        .{ .pane_drained = pane_id },
    );
}

fn sendRender(
    allocator: std.mem.Allocator,
    output_queue: *BoundedByteQueue,
    renderer: *session_render.Renderer,
    model: *model_mod.ServerModel,
    session_id: ids.SessionId,
    panes: *std.AutoHashMapUnmanaged(ids.PaneId, PaneRuntime),
    cols: u16,
    rows: u16,
    session_name: []const u8,
    force_full: bool,
) !void {
    const session = model.sessions.getPtr(session_id) orelse
        return error.SessionNotFound;
    const workspace = model.activeWorkspace(session_id) orelse
        return error.WorkspaceNotFound;
    const snapshot = try layout_workspace.snapshotFromModel(
        allocator,
        model,
        workspace,
    );
    defer allocator.free(snapshot.panes);
    var placements = try layout_workspace.placeWorkspace(
        allocator,
        snapshot,
        .{
            .x = 0,
            .y = 0,
            .width = cols,
            .height = @min(rows -| 1, session.canonical_outer_rows),
        },
    );
    defer placements.deinit(allocator);
    const views = try allocator.alloc(
        session_render.BackendView,
        placements.items.len,
    );
    defer allocator.free(views);
    var view_count: usize = 0;
    for (placements.items) |placement| {
        const runtime = panes.getPtr(placement.pane_id) orelse continue;
        views[view_count] = .{
            .pane_id = placement.pane_id,
            .backend = &runtime.backend,
        };
        view_count += 1;
    }
    const payload = try renderer.frameAlloc(
        allocator,
        views[0..view_count],
        placements.items,
        workspace.focused_pane,
        cols,
        rows,
        session_name,
        session.active_workspace + 1,
        workspace.focused_pane + 1,
        force_full,
    );
    defer allocator.free(payload);
    try queueFrame(allocator, output_queue, .render_bytes, 0, payload);
}

fn disconnect(
    client: *?transport.Stream,
    parser: *frame.Parser,
    output_queue: *BoundedByteQueue,
    allocator: std.mem.Allocator,
    attached: *bool,
) void {
    if (client.*) |*stream| stream.close();
    client.* = null;
    parser.deinit(allocator);
    parser.* = .{};
    output_queue.consume(output_queue.len());
    attached.* = false;
}

fn queueFrame(
    allocator: std.mem.Allocator,
    output_queue: *BoundedByteQueue,
    kind: frame.Kind,
    request_id: u32,
    payload: []const u8,
) !void {
    const encoded = try frame.encodeAlloc(allocator, .{
        .version = .{},
        .kind = kind,
        .flags = 0,
        .request_id = request_id,
        .payload_len = @intCast(payload.len),
    }, payload);
    defer allocator.free(encoded);
    try output_queue.append(allocator, encoded);
}

fn flushOutput(
    client: *transport.Stream,
    output_queue: *BoundedByteQueue,
) !void {
    while (output_queue.len() > 0) {
        switch (try client.writeSome(output_queue.peek())) {
            .written => |count| output_queue.consume(count),
            .would_block => break,
        }
    }
}

fn shutdownChild(pty: *pty_mod.Pty) void {
    const stages = [_]struct { signal: pty_mod.Signal, attempts: usize }{
        .{ .signal = .hup, .attempts = 10 },
        .{ .signal = .term, .attempts = 20 },
        .{ .signal = .kill, .attempts = 2 },
    };
    for (stages) |stage| {
        pty.signalGroup(stage.signal) catch {};
        for (0..stage.attempts) |_| {
            switch (pty.wait(true) catch return) {
                .exited => return,
                .running => _ = pty.pollReadable(100) catch false,
            }
        }
    }
    _ = pty.wait(false) catch {};
}
