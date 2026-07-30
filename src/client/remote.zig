const std = @import("std");
const raw_mode = @import("raw_mode.zig");
const transport = @import("../server/transport.zig");
const frame = @import("../protocol/frame.zig");
const control = @import("../protocol/control.zig");
const prefix_mod = @import("../input/prefix.zig");
const model_mod = @import("../core/model.zig");

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
    var rename_prompt: RenamePrompt = .{};
    defer rename_prompt.deinit(allocator);
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
            if (rename_prompt.active) {
                try handleRenameInput(
                    allocator,
                    &rename_prompt,
                    bytes,
                    &outer,
                    &stream,
                    size,
                );
            } else {
                var forwarded: [8192]u8 = undefined;
                var count: usize = 0;
                var input_index: usize = 0;
                while (input_index < bytes.len) : (input_index += 1) {
                    if (rename_prompt.active) {
                        if (count > 0) {
                            try stream.send(
                                allocator,
                                .input_bytes,
                                0,
                                forwarded[0..count],
                            );
                            count = 0;
                        }
                        try handleRenameInput(
                            allocator,
                            &rename_prompt,
                            bytes[input_index..],
                            &outer,
                            &stream,
                            size,
                        );
                        break;
                    }
                    const byte = bytes[input_index];
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
                                .detach => try stream.send(
                                    allocator,
                                    .detach_request,
                                    3,
                                    "{\"reason\":\"requested\"}",
                                ),
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
                                .rename_session => {
                                    rename_prompt.active = true;
                                    rename_prompt.buffer.clearRetainingCapacity();
                                    try drawRenamePrompt(
                                        &outer,
                                        &rename_prompt,
                                        size,
                                    );
                                },
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
                            .render_bytes => {
                                try outer.write(message.payload);
                                if (rename_prompt.active) {
                                    try drawRenamePrompt(
                                        &outer,
                                        &rename_prompt,
                                        size,
                                    );
                                }
                            },
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
        .value = null,
    });
    defer allocator.free(payload);
    try stream.send(allocator, .command_request, 5, payload);
}

const RenamePrompt = struct {
    active: bool = false,
    buffer: std.ArrayList(u8) = .empty,

    fn deinit(self: *RenamePrompt, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        self.* = .{};
    }
};

fn handleRenameInput(
    allocator: std.mem.Allocator,
    prompt: *RenamePrompt,
    bytes: []const u8,
    outer: *raw_mode.Terminal,
    stream: *transport.Stream,
    size: raw_mode.Size,
) !void {
    for (bytes) |byte| switch (byte) {
        '\r', '\n' => {
            model_mod.validateSessionName(prompt.buffer.items) catch {
                try outer.write("\x07");
                try drawRenamePrompt(outer, prompt, size);
                return;
            };
            const payload = try control.encode(allocator, control.Command{
                .command = "rename-session",
                .value = prompt.buffer.items,
            });
            defer allocator.free(payload);
            try stream.send(allocator, .command_request, 6, payload);
            prompt.active = false;
            try outer.write("\x1b[?25l");
            return;
        },
        0x1b, 0x03 => {
            prompt.active = false;
            try outer.write("\x1b[?25l");
            try sendResize(allocator, stream, size.rows, size.cols);
            return;
        },
        0x08, 0x7f => removeLastCodepoint(&prompt.buffer),
        0x15 => prompt.buffer.clearRetainingCapacity(),
        else => if (byte >= 0x20 and byte != 0x7f and
            prompt.buffer.items.len < 128)
        {
            try prompt.buffer.append(allocator, byte);
        },
    };
    try drawRenamePrompt(outer, prompt, size);
}

fn removeLastCodepoint(buffer: *std.ArrayList(u8)) void {
    if (buffer.items.len == 0) return;
    var index = buffer.items.len - 1;
    while (index > 0 and buffer.items[index] & 0xc0 == 0x80) index -= 1;
    buffer.items.len = index;
}

fn drawRenamePrompt(
    outer: *raw_mode.Terminal,
    prompt: *const RenamePrompt,
    size: raw_mode.Size,
) !void {
    var position_buffer: [64]u8 = undefined;
    const position = try std.fmt.bufPrint(
        &position_buffer,
        "\x1b[{d};1H\x1b[0;48;2;46;52;64m\x1b[2K",
        .{size.rows},
    );
    try outer.write(position);
    try outer.write(
        "\x1b[38;2;136;192;208;48;2;46;52;64m" ++
            "\x1b[1;38;2;46;52;64;48;2;136;192;208m rename session: ",
    );
    try outer.write(prompt.buffer.items);
    try outer.write(
        " \x1b[0;38;2;136;192;208;48;2;46;52;64m" ++
            "\x1b[0m\x1b[?25h",
    );
}

test "rename prompt removes one UTF-8 codepoint" {
    const allocator = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    try buffer.appendSlice(allocator, "A工");
    removeLastCodepoint(&buffer);
    try std.testing.expectEqualStrings("A", buffer.items);
    removeLastCodepoint(&buffer);
    try std.testing.expectEqualStrings("", buffer.items);
}
