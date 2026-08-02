const std = @import("std");
const noren = @import("noren");

pub fn main(init: std.process.Init) !void {
    // The Init arena is appropriate for process-start data, but Noren's
    // Server can live for days. Using it for runtime frames and renders would
    // make every logical free a no-op and grow memory until process exit.
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    const exit_code = run(
        allocator,
        init.io,
        init.environ_map,
        args,
        stdout,
        stderr,
    ) catch |err| {
        try stderr.print("noren: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    try stdout.flush();
    try stderr.flush();
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const invocation = noren.cli.arguments.parse(args);
    const command = invocation.command;

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try stdout.writeAll("noren 0.4.4 (M4)\n");
        return 0;
    }
    if (std.mem.eql(u8, command, "info")) {
        try stdout.writeAll(
            \\Noren 0.4.4
            \\implementation stage: M4 (horizontal Panes and Workspaces)
            \\protocol: NRN1 1.0
            \\target Zig: 0.16.0
            \\PTY runtime: enabled
            \\persistent server/attach: enabled
            \\horizontal Panes/Workspaces: enabled
            \\Nord capsule status/Session rename: enabled
            \\interactive prefix menu/continuous adjustment: enabled
            \\cursor sync/mouse Pane selection: enabled
            \\
        );
        return 0;
    }
    if (std.mem.eql(u8, command, "debug") and args.len > 2 and
        std.mem.eql(u8, args[2], "model-demo"))
    {
        try modelDemo(allocator, stdout);
        return 0;
    }
    if (std.mem.eql(u8, command, "new") or
        std.mem.eql(u8, command, "new-session"))
    {
        return runNew(
            allocator,
            io,
            environ,
            invocation.executable,
            invocation.command_args,
            stderr,
        );
    }
    if (std.mem.eql(u8, command, "attach")) {
        return runAttach(allocator, environ, invocation.command_args, stderr);
    }
    if (std.mem.eql(u8, command, "__server")) {
        return runServer(allocator, environ, invocation.command_args, stderr);
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        try printHelp(stdout);
        return 0;
    }

    try stderr.print(
        "noren: unknown command '{s}'\n\n",
        .{command},
    );
    try printHelp(stderr);
    return 2;
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: noren <command>
        \\
        \\Commands available in 0.4.4:
        \\  new [-d] [-s NAME] [-c DIR] [-- COMMAND...]
        \\                      Create a persistent Session; attach unless -d
        \\  attach [-t NAME]    Attach to the running Session
        \\  version             Show version
        \\  info                Show implementation capabilities
        \\  debug model-demo    Exercise the model and layout renderer
        \\  help                Show this help
        \\
        \\Inside a Session, press Ctrl-b then:
        \\  c/x            create/close Pane
        \\  arrows         focus Pane or Workspace
        \\  h/l            scroll camera by 1 cell (repeat directly)
        \\  [/]            narrow/widen Pane by 5 cells (repeat directly)
        \\  n/,/d          create Workspace/rename Session/detach
        \\  mouse click    focus Pane; forward content clicks when app opts in
        \\
    );
}

fn runNew(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
    executable: []const u8,
    args: []const []const u8,
    stderr: *std.Io.Writer,
) !u8 {
    if (environ.contains("NOREN")) {
        try stderr.writeAll(
            "noren: interactive nesting is disabled; use the in-app command area " ++
                "or a distinct --nested socket namespace in a later milestone\n",
        );
        return 2;
    }

    const parsed = try parseNewArgs(args, stderr) orelse return 2;
    const socket_path = try noren.server.transport.defaultSocketPath(allocator);
    if (noren.server.transport.Stream.connect(allocator, socket_path)) |existing_value| {
        var existing = existing_value;
        existing.close();
        try stderr.writeAll(
            "noren: a Session server is already running; use 'noren attach'\n",
        );
        return 1;
    } else |_| {}

    const server_args = try allocator.alloc([]const u8, args.len + 2);
    server_args[0] = executable;
    server_args[1] = "__server";
    @memcpy(server_args[2..], args);
    const child = try std.process.spawn(io, .{
        .argv = server_args,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    _ = child;

    var connected = false;
    for (0..100) |_| {
        if (noren.server.transport.Stream.connect(allocator, socket_path)) |probe_value| {
            var probe = probe_value;
            probe.close();
            connected = true;
            break;
        } else |_| {
            try io.sleep(.fromMilliseconds(20), .awake);
        }
    }
    if (!connected) {
        try stderr.writeAll("noren: Session server did not start\n");
        return 1;
    }
    if (parsed.detached) return 0;

    noren.client.remote.run(allocator, .{
        .socket_path = socket_path,
        .session_name = parsed.session_name,
    }) catch |err| return reportClientError(err, stderr);
    return 0;
}

const NewArgs = struct {
    session_name: []const u8 = "default",
    cwd: ?[]const u8 = null,
    command: ?[]const []const u8 = null,
    detached: bool = false,
};

fn parseNewArgs(
    args: []const []const u8,
    stderr: *std.Io.Writer,
) !?NewArgs {
    var parsed: NewArgs = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            parsed.command = args[index + 1 ..];
            break;
        }
        if (std.mem.eql(u8, arg, "-d")) {
            parsed.detached = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-s")) {
            index += 1;
            if (index >= args.len) {
                try stderr.writeAll("noren: -s requires a Session name\n");
                return null;
            }
            parsed.session_name = args[index];
            noren.core.model.validateSessionName(parsed.session_name) catch {
                try stderr.writeAll("noren: invalid Session name\n");
                return null;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "-c")) {
            index += 1;
            if (index >= args.len) {
                try stderr.writeAll("noren: -c requires a directory\n");
                return null;
            }
            parsed.cwd = args[index];
            continue;
        }
        try stderr.print("noren: unknown new option '{s}'\n", .{arg});
        return null;
    }
    if (parsed.command) |command| {
        if (command.len == 0) {
            try stderr.writeAll("noren: COMMAND after -- cannot be empty\n");
            return null;
        }
    }
    return parsed;
}

fn runServer(
    allocator: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
    stderr: *std.Io.Writer,
) !u8 {
    const parsed = (try parseNewArgs(args, stderr)) orelse return 2;

    var child_environment = try environ.clone(allocator);
    defer child_environment.deinit();
    try child_environment.put("TERM", "xterm-256color");
    try child_environment.put("COLORTERM", "truecolor");
    try child_environment.put("NOREN", "1");
    const socket_path = try noren.server.transport.defaultSocketPath(allocator);
    try child_environment.put("NOREN_SOCKET", socket_path);
    try child_environment.put("NOREN_SESSION", "s1");
    try child_environment.put("NOREN_PANE", "p1");

    const child_command = parsed.command orelse &.{
        child_environment.get("SHELL") orelse "/bin/sh",
    };

    const environment_entries = try allocator.alloc(
        []const u8,
        child_environment.count(),
    );
    var environment_iterator = child_environment.iterator();
    var environment_index: usize = 0;
    while (environment_iterator.next()) |entry| : (environment_index += 1) {
        environment_entries[environment_index] = try std.fmt.allocPrint(
            allocator,
            "{s}={s}",
            .{ entry.key_ptr.*, entry.value_ptr.* },
        );
    }

    try noren.server.session.run(allocator, .{
        .argv = child_command,
        .default_argv = &.{
            child_environment.get("SHELL") orelse "/bin/sh",
        },
        .cwd = parsed.cwd,
        .environment = environment_entries,
        .session_name = parsed.session_name,
        .socket_path = socket_path,
    });
    return 0;
}

fn runAttach(
    allocator: std.mem.Allocator,
    environ: *std.process.Environ.Map,
    args: []const []const u8,
    stderr: *std.Io.Writer,
) !u8 {
    if (environ.contains("NOREN")) {
        try stderr.writeAll("noren: attaching from inside Noren is disabled\n");
        return 2;
    }
    var target: []const u8 = "default";
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "-t")) {
            index += 1;
            if (index >= args.len) {
                try stderr.writeAll("noren: -t requires a Session name\n");
                return 2;
            }
            target = args[index];
            noren.core.model.validateSessionName(target) catch {
                try stderr.writeAll("noren: invalid Session name\n");
                return 2;
            };
        } else {
            try stderr.print("noren: unknown attach option '{s}'\n", .{args[index]});
            return 2;
        }
    }
    const socket_path = try noren.server.transport.defaultSocketPath(allocator);
    noren.client.remote.run(allocator, .{
        .socket_path = socket_path,
        .session_name = target,
    }) catch |err| return reportClientError(err, stderr);
    return 0;
}

fn reportClientError(err: anyerror, stderr: *std.Io.Writer) !u8 {
    switch (err) {
        error.ServerUnavailable => try stderr.writeAll(
            "noren: no Session server is running; create one with 'noren new'\n",
        ),
        error.NotInteractiveTerminal => try stderr.writeAll(
            "noren: attach requires an interactive terminal\n",
        ),
        error.AttachRejected => try stderr.writeAll(
            "noren: requested Session was not found\n",
        ),
        else => return err,
    }
    return 1;
}

fn modelDemo(allocator: std.mem.Allocator, writer: *std.Io.Writer) !void {
    var model = noren.core.model.ServerModel.init();
    defer model.deinit(allocator);

    const session_id = try model.createSession(allocator, "work", 80, 24);
    var effects: std.ArrayList(noren.core.effect.Effect) = .empty;
    defer effects.deinit(allocator);

    try noren.core.reducer.apply(
        allocator,
        &model,
        .{ .server = {} },
        .{ .new_pane = .{ .session_id = session_id, .outer_width = 40 } },
        &effects,
    );
    try noren.core.invariant.assertInvariants(&model);

    const session = model.sessions.getPtr(session_id).?;
    const workspace_id = session.workspaces.items[session.active_workspace];
    const workspace = model.workspaces.getPtr(workspace_id).?;
    const snapshot = try noren.layout.workspace.snapshotFromModel(allocator, &model, workspace);
    defer allocator.free(snapshot.panes);

    var placements = try noren.layout.workspace.placeWorkspace(
        allocator,
        snapshot,
        .{ .x = 0, .y = 0, .width = 50, .height = 8 },
    );
    defer placements.deinit(allocator);

    var canvas = try noren.render.canvas.Canvas.init(allocator, 50, 9);
    defer canvas.deinit(allocator);
    try noren.render.compositor.drawWorkspace(
        &canvas,
        placements.items,
        snapshot.focused_pane,
        "work",
        1,
        2,
    );
    try canvas.writeTextDump(writer);
}
