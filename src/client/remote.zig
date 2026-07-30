const std = @import("std");
const raw_mode = @import("raw_mode.zig");
const transport = @import("../server/transport.zig");
const frame = @import("../protocol/frame.zig");
const control = @import("../protocol/control.zig");
const prefix_mod = @import("../input/prefix.zig");

pub const Options = struct {
    socket_path: []const u8,
    session_name: []const u8,
};

pub fn run(allocator: std.mem.Allocator, options: Options) !void {
    var stream = try transport.Stream.connect(allocator, options.socket_path);
    defer stream.close();
    var outer = try raw_mode.Terminal.enter();
    defer outer.restore();
    try outer.write("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l\x1b[?2004h");
    defer outer.write(
        "\x1b[0m\x1b[?25h\x1b[?2004l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1049l",
    ) catch {};

    var size = try outer.size();
    if (size.rows < 4 or size.cols < 3) return error.TerminalTooSmall;
    try stream.send(allocator, .hello, 1, "{\"major\":1,\"minor\":0}");
    try sendAttach(allocator, &stream, options.session_name, size.rows, size.cols);

    var parser: frame.Parser = .{};
    defer parser.deinit(allocator);
    var prefix: prefix_mod.Router = .{};
    var attached = false;
    var done = false;

    while (!done) {
        const ready = try outer.poll(stream.fd, -1);
        if (ready.signal) {
            while (outer.takeSignal()) |signal| switch (signal) {
                .resize => {
                    const next = outer.size() catch continue;
                    if (next.rows < 4 or next.cols < 3) continue;
                    if (next.rows == size.rows and next.cols == size.cols) continue;
                    size = next;
                    try sendResize(allocator, &stream, size.rows, size.cols);
                },
                .terminate, .hangup => {
                    stream.send(
                        allocator,
                        .detach_request,
                        4,
                        "{\"reason\":\"signal\"}",
                    ) catch {};
                    done = true;
                },
            };
        }

        if (ready.stdin and attached and !done) {
            var input: [8192]u8 = undefined;
            const bytes = try outer.readInput(&input);
            var forwarded: [8192]u8 = undefined;
            var count: usize = 0;
            for (bytes) |byte| {
                switch (prefix.feed(byte)) {
                    .forward => |value| {
                        forwarded[count] = value;
                        count += 1;
                    },
                    .command => |command| {
                        if (count > 0) {
                            try stream.send(
                                allocator,
                                .input_bytes,
                                0,
                                forwarded[0..count],
                            );
                            count = 0;
                        }
                        switch (command) {
                            .send_prefix => {
                                forwarded[count] = prefix.prefix_byte;
                                count += 1;
                            },
                            .detach => {
                                try stream.send(
                                    allocator,
                                    .detach_request,
                                    3,
                                    "{\"reason\":\"requested\"}",
                                );
                            },
                            .new_pane => try sendCommand(
                                allocator,
                                &stream,
                                "new-pane",
                            ),
                            .close_pane => try sendCommand(
                                allocator,
                                &stream,
                                "close-pane",
                            ),
                            .focus_left => try sendCommand(
                                allocator,
                                &stream,
                                "focus-left",
                            ),
                            .focus_right => try sendCommand(
                                allocator,
                                &stream,
                                "focus-right",
                            ),
                            .focus_up => try sendCommand(
                                allocator,
                                &stream,
                                "focus-up",
                            ),
                            .focus_down => try sendCommand(
                                allocator,
                                &stream,
                                "focus-down",
                            ),
                            .resize_narrower => try sendCommand(
                                allocator,
                                &stream,
                                "resize-narrower",
                            ),
                            .resize_wider => try sendCommand(
                                allocator,
                                &stream,
                                "resize-wider",
                            ),
                            .new_workspace => try sendCommand(
                                allocator,
                                &stream,
                                "new-workspace",
                            ),
                            else => try outer.write("\x07"),
                        }
                    },
                    .wait => {},
                    .rejected => try outer.write("\x07"),
                }
            }
            if (count > 0) {
                try stream.send(
                    allocator,
                    .input_bytes,
                    0,
                    forwarded[0..count],
                );
            }
        }

        if (ready.pty) {
            var buffer: [64 * 1024]u8 = undefined;
            switch (try stream.read(&buffer)) {
                .data => |bytes| {
                    try parser.feed(allocator, bytes);
                    while (try parser.next(allocator)) |owned| {
                        var message = owned;
                        defer message.deinit(allocator);
                        if (message.header.version.major != 1) {
                            return error.ProtocolVersionMismatch;
                        }
                        switch (message.header.kind) {
                            .welcome => {},
                            .attached => attached = true,
                            .render_bytes => try outer.write(message.payload),
                            .detached => done = true,
                            .error_message => return error.AttachRejected,
                            else => {},
                        }
                    }
                },
                .would_block => {},
                .eof => done = true,
            }
        }
    }
}

fn sendAttach(
    allocator: std.mem.Allocator,
    stream: *transport.Stream,
    session_name: []const u8,
    rows: u16,
    cols: u16,
) !void {
    const payload = try control.encode(allocator, control.Attach{
        .target = session_name,
        .rows = rows,
        .cols = cols,
    });
    defer allocator.free(payload);
    try stream.send(allocator, .attach_request, 2, payload);
}

fn sendResize(
    allocator: std.mem.Allocator,
    stream: *transport.Stream,
    rows: u16,
    cols: u16,
) !void {
    const payload = try control.encode(allocator, control.Resize{
        .rows = rows,
        .cols = cols,
    });
    defer allocator.free(payload);
    try stream.send(allocator, .client_resize, 0, payload);
}

fn sendCommand(
    allocator: std.mem.Allocator,
    stream: *transport.Stream,
    command: []const u8,
) !void {
    const payload = try control.encode(allocator, control.Command{
        .command = command,
    });
    defer allocator.free(payload);
    try stream.send(allocator, .command_request, 5, payload);
}
