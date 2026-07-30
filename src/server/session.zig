const std = @import("std");
const transport = @import("transport.zig");
const frame = @import("../protocol/frame.zig");
const control = @import("../protocol/control.zig");
const pty_mod = @import("../os/pty.zig");
const terminal_mod = @import("../terminal/backend.zig");
const session_render = @import("../render/session.zig");
const BoundedByteQueue = @import("../core/bounded_queue.zig").BoundedByteQueue;

const default_outer_rows: u16 = 24;
const default_outer_cols: u16 = 80;
const input_limit: usize = 1024 * 1024;
const client_output_limit: usize = 4 * 1024 * 1024;

pub const Options = struct {
    argv: []const []const u8,
    cwd: ?[]const u8,
    environment: []const []const u8,
    session_name: []const u8,
    socket_path: []const u8,
};

pub fn run(allocator: std.mem.Allocator, options: Options) !void {
    var listener = try transport.Listener.init(allocator, options.socket_path);
    defer listener.deinit();

    var outer_rows = default_outer_rows;
    var outer_cols = default_outer_cols;
    var pane_size = logicalPaneSize(outer_rows, outer_cols);
    var pty = try pty_mod.Pty.spawn(allocator, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environment = options.environment,
        .size = pane_size,
    });
    var child_reaped = false;
    defer {
        if (!child_reaped) shutdownChild(&pty);
        pty.close();
    }
    var backend = try terminal_mod.TerminalBackend.init(pane_size.rows, pane_size.cols);
    defer backend.deinit();
    var renderer: session_render.Renderer = .{};
    defer renderer.deinit(allocator);
    var input_queue = BoundedByteQueue.init(input_limit);
    defer input_queue.deinit(allocator);
    var output_queue = BoundedByteQueue.init(client_output_limit);
    defer output_queue.deinit(allocator);

    var client: ?transport.Stream = null;
    defer if (client) |*stream| stream.close();
    var parser: frame.Parser = .{};
    defer parser.deinit(allocator);
    var attached = false;
    var ever_attached = false;
    var first_frame = true;
    var pty_eof = false;
    var startup_grace_ticks: usize = 100;

    while (true) {
        const ready = try transport.poll3(
            listener.fd,
            if (client) |stream| stream.fd else -1,
            if (pty_eof) -1 else pty.master_fd,
            if (pty_eof) 20 else -1,
            output_queue.len() > 0,
        );

        if (ready.first) {
            var incoming = listener.accept() catch continue;
            if (client != null and attached) {
                incoming.close();
            } else {
                if (client) |*stream| stream.close();
                client = incoming;
                parser.deinit(allocator);
                parser = .{};
                output_queue.consume(output_queue.len());
                attached = false;
                first_frame = true;
            }
        }

        if (ready.second and client != null) {
            var buffer: [64 * 1024]u8 = undefined;
            switch (client.?.read(&buffer) catch .eof) {
                .data => |bytes| {
                    parser.feed(allocator, bytes) catch {
                        disconnect(&client, &parser, &output_queue, allocator, &attached);
                        continue;
                    };
                    while (try parser.next(allocator)) |owned| {
                        var message = owned;
                        defer message.deinit(allocator);
                        handleMessage(
                            allocator,
                            &client,
                            &output_queue,
                            &attached,
                            &ever_attached,
                            &first_frame,
                            &outer_rows,
                            &outer_cols,
                            &pane_size,
                            &pty,
                            &backend,
                            &input_queue,
                            options.session_name,
                            message,
                        ) catch {
                            disconnect(&client, &parser, &output_queue, allocator, &attached);
                            break;
                        };
                        if (client == null) break;
                    }
                },
                .would_block => {},
                .eof => disconnect(
                    &client,
                    &parser,
                    &output_queue,
                    allocator,
                    &attached,
                ),
            }
        }

        if (ready.second_write and client != null) {
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

        try flushInput(&pty, &input_queue);
        if (ready.third) {
            var buffer: [16 * 1024]u8 = undefined;
            var budget: usize = 0;
            while (budget < 256 * 1024) {
                switch (try pty.read(&buffer)) {
                    .data => |bytes| {
                        budget += bytes.len;
                        try backend.feed(bytes);
                        var response: [4096]u8 = undefined;
                        while (true) {
                            const bytes_out = backend.takeOutput(&response);
                            if (bytes_out.len == 0) break;
                            try input_queue.append(allocator, bytes_out);
                        }
                    },
                    .would_block => break,
                    .eof => {
                        pty_eof = true;
                        break;
                    },
                }
            }
            try flushInput(&pty, &input_queue);
        }

        const damaged = backend.takeDamage();
        if (attached and client != null and (damaged or first_frame)) {
            sendRender(
                allocator,
                &output_queue,
                &renderer,
                &backend,
                outer_cols,
                outer_rows,
                options.session_name,
                first_frame,
            ) catch {
                disconnect(
                    &client,
                    &parser,
                    &output_queue,
                    allocator,
                    &attached,
                );
                continue;
            };
            first_frame = false;
        }

        if (!child_reaped) {
            switch (try pty.wait(true)) {
                .running => {},
                .exited => child_reaped = true,
            }
        }
        if (child_reaped and pty_eof) {
            if (ever_attached and output_queue.len() == 0) break;
            if (startup_grace_ticks == 0) break;
            startup_grace_ticks -= 1;
        }
    }
    if (!child_reaped) {
        _ = try pty.wait(false);
        child_reaped = true;
    }
}

fn handleMessage(
    allocator: std.mem.Allocator,
    client: *?transport.Stream,
    output_queue: *BoundedByteQueue,
    attached: *bool,
    ever_attached: *bool,
    first_frame: *bool,
    outer_rows: *u16,
    outer_cols: *u16,
    pane_size: *pty_mod.Size,
    pty: *pty_mod.Pty,
    backend: *terminal_mod.TerminalBackend,
    input_queue: *BoundedByteQueue,
    session_name: []const u8,
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
            if (!std.mem.eql(u8, parsed.value.target, session_name)) {
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
                parsed.value.rows,
                parsed.value.cols,
                outer_rows,
                outer_cols,
                pane_size,
                pty,
                backend,
            );
            const payload = try control.encode(allocator, control.Attached{
                .session = session_name,
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
            first_frame.* = true;
        },
        .client_resize => {
            if (!attached.*) return;
            var parsed = try control.decode(control.Resize, allocator, message.payload);
            defer parsed.deinit();
            try applySize(
                parsed.value.rows,
                parsed.value.cols,
                outer_rows,
                outer_cols,
                pane_size,
                pty,
                backend,
            );
            first_frame.* = true;
        },
        .input_bytes => {
            if (attached.*) try input_queue.append(allocator, message.payload);
        },
        .detach_request => {
            client.*.?.close();
            client.* = null;
            output_queue.consume(output_queue.len());
            attached.* = false;
        },
        .command_request => {
            if (std.mem.indexOf(u8, message.payload, "\"close-pane\"") != null) {
                try pty.signalGroup(.hup);
            }
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

fn applySize(
    rows: u16,
    cols: u16,
    outer_rows: *u16,
    outer_cols: *u16,
    pane_size: *pty_mod.Size,
    pty: *pty_mod.Pty,
    backend: *terminal_mod.TerminalBackend,
) !void {
    if (rows < 4 or cols < 3) return error.TerminalTooSmall;
    outer_rows.* = rows;
    outer_cols.* = cols;
    const next = logicalPaneSize(rows, cols);
    if (next.rows == pane_size.rows and next.cols == pane_size.cols) return;
    try pty.resize(next);
    try backend.resize(next.rows, next.cols);
    pane_size.* = next;
}

fn logicalPaneSize(rows: u16, cols: u16) pty_mod.Size {
    const outer_width = @max(@as(u16, 3), @min(@as(u16, 80), cols));
    return .{
        .rows = @max(@as(u16, 1), rows -| 3),
        .cols = outer_width - 2,
    };
}

fn sendRender(
    allocator: std.mem.Allocator,
    output_queue: *BoundedByteQueue,
    renderer: *session_render.Renderer,
    backend: *const terminal_mod.TerminalBackend,
    cols: u16,
    rows: u16,
    session_name: []const u8,
    clear: bool,
) !void {
    const payload = try renderer.frameAlloc(
        allocator,
        backend,
        cols,
        rows,
        session_name,
        clear,
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

fn flushInput(pty: *pty_mod.Pty, queue: *BoundedByteQueue) !void {
    while (queue.len() > 0) {
        switch (try pty.write(queue.peek())) {
            .written => |count| queue.consume(count),
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
