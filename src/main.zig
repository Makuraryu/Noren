const std = @import("std");
const noren = @import("noren");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

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
    environ: *std.process.Environ.Map,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const command = if (args.len > 1) args[1] else "new";

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try stdout.writeAll("noren 0.1.0 (M1)\n");
        return 0;
    }
    if (std.mem.eql(u8, command, "info")) {
        try stdout.writeAll(
            \\Noren 0.1.0
            \\implementation stage: M1 (single Pane PTY + libvterm)
            \\protocol: NRN1 1.0
            \\target Zig: 0.16.0
            \\PTY runtime: enabled
            \\persistent server/attach: not enabled in this stage
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
        return runNew(allocator, environ, args[2..], stderr);
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        try printHelp(stdout);
        return 0;
    }

    try stderr.print(
        "noren: command '{s}' is unavailable in implementation stage M0\n\n",
        .{command},
    );
    try printHelp(stderr);
    return 2;
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: noren <command>
        \\
        \\Commands available in 0.1.0:
        \\  new [-s NAME] [-c DIR] [-- COMMAND...]
        \\                      Run a shell/command in a PTY-backed Pane
        \\  version             Show version
        \\  info                Show implementation capabilities
        \\  debug model-demo    Exercise the model and layout renderer
        \\  help                Show this help
        \\
        \\Detached Sessions and attach are scheduled for M2.
        \\
    );
}

fn runNew(
    allocator: std.mem.Allocator,
    environ: *std.process.Environ.Map,
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

    var session_name: []const u8 = "default";
    var cwd: ?[]const u8 = null;
    var command: ?[]const []const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) {
            command = args[index + 1 ..];
            break;
        }
        if (std.mem.eql(u8, arg, "-d")) {
            try stderr.writeAll(
                "noren: detached creation requires the persistent M2 server\n",
            );
            return 2;
        }
        if (std.mem.eql(u8, arg, "-s")) {
            index += 1;
            if (index >= args.len) {
                try stderr.writeAll("noren: -s requires a Session name\n");
                return 2;
            }
            session_name = args[index];
            noren.core.model.validateSessionName(session_name) catch {
                try stderr.writeAll("noren: invalid Session name\n");
                return 2;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "-c")) {
            index += 1;
            if (index >= args.len) {
                try stderr.writeAll("noren: -c requires a directory\n");
                return 2;
            }
            cwd = args[index];
            continue;
        }
        try stderr.print("noren: unknown new option '{s}'\n", .{arg});
        return 2;
    }

    var child_environment = try environ.clone(allocator);
    defer child_environment.deinit();
    try child_environment.put("TERM", "xterm-256color");
    try child_environment.put("COLORTERM", "truecolor");
    try child_environment.put("NOREN", "1");
    try child_environment.put("NOREN_SOCKET", "m1-local");
    try child_environment.put("NOREN_SESSION", "s1");
    try child_environment.put("NOREN_PANE", "p1");

    const child_command = command orelse &.{
        child_environment.get("SHELL") orelse "/bin/sh",
    };
    if (child_command.len == 0) {
        try stderr.writeAll("noren: COMMAND after -- cannot be empty\n");
        return 2;
    }

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

    noren.client.interactive.run(allocator, .{
        .argv = child_command,
        .cwd = cwd,
        .environment = environment_entries,
        .session_name = session_name,
    }) catch |err| {
        switch (err) {
            error.NotInteractiveTerminal => {
                try stderr.writeAll("noren: new requires an interactive terminal\n");
                return 1;
            },
            else => return err,
        }
    };
    return 0;
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
