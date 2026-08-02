const std = @import("std");
const raw_mode = @import("raw_mode.zig");
const transport = @import("../server/transport.zig");
const reactor = @import("../server/reactor.zig");
const frame = @import("../protocol/frame.zig");
const control = @import("../protocol/control.zig");
const prefix_mod = @import("../input/prefix.zig");
const mouse_mod = @import("../input/mouse.zig");
const model_mod = @import("../core/model.zig");

const enable_mouse = "\x1b[?1000h\x1b[?1006h";
const disable_mouse = "\x1b[?1000l\x1b[?1006l";
const escape_sequence_timeout_ms: u64 = 30;

pub const Options = struct {
    socket_path: []const u8,
    session_name: []const u8,
};

pub fn run(allocator: std.mem.Allocator, options: Options) !void {
    var stream = try transport.Stream.connect(allocator, options.socket_path);
    defer stream.close();
    var outer = try raw_mode.Terminal.enter();
    defer outer.restore();
    try outer.write(
        "\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l\x1b[?2004h" ++ enable_mouse,
    );
    defer outer.write(
        "\x1b[0m\x1b[?25h\x1b[?2004l" ++ disable_mouse ++
            "\x1b[?1002l\x1b[?1003l\x1b[?1049l",
    ) catch {};

    var size = try outer.size();
    if (size.rows < 4 or size.cols < 3) return error.TerminalTooSmall;
    try stream.send(allocator, .hello, 1, "{\"major\":1,\"minor\":0}");
    try sendAttach(allocator, &stream, options.session_name, size.rows, size.cols);

    var parser: frame.Parser = .{};
    defer parser.deinit(allocator);
    var prefix: prefix_mod.Router = .{};
    var mouse_decoder: mouse_mod.Decoder = .{};
    var mouse_decode_deadline: ?u64 = null;
    var prefix_menu_visible = false;
    var rename_prompt: RenamePrompt = .{};
    defer rename_prompt.deinit(allocator);
    var attached = false;
    var done = false;

    while (!done) {
        const ready = try outer.poll(
            stream.fd,
            mousePollTimeout(mouse_decode_deadline),
        );
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
                var forwarded: ForwardBuffer = .{};
                var input_index: usize = 0;
                while (input_index < bytes.len) : (input_index += 1) {
                    if (rename_prompt.active) {
                        try forwarded.flush(allocator, &stream);
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
                    switch (mouse_decoder.feed(bytes[input_index])) {
                        .forward => |byte| try routePrefixByte(
                            allocator,
                            byte,
                            &forwarded,
                            &prefix,
                            &prefix_menu_visible,
                            &rename_prompt,
                            &outer,
                            &stream,
                            size,
                        ),
                        .replay => |replay| {
                            for (replay.slice()) |byte| {
                                try routePrefixByte(
                                    allocator,
                                    byte,
                                    &forwarded,
                                    &prefix,
                                    &prefix_menu_visible,
                                    &rename_prompt,
                                    &outer,
                                    &stream,
                                    size,
                                );
                            }
                        },
                        .mouse => |event| {
                            try forwarded.flush(allocator, &stream);
                            prefix.timeout();
                            try syncPrefixMenu(
                                allocator,
                                &stream,
                                &prefix_menu_visible,
                                false,
                            );
                            try sendMouseInput(allocator, &stream, event);
                        },
                        .wait => {},
                    }
                    refreshMouseDeadline(
                        &mouse_decoder,
                        &mouse_decode_deadline,
                    );
                }
                try forwarded.flush(allocator, &stream);
            }
        }

        if (attached and !done and mouse_decoder.hasPending() and
            mousePollTimeout(mouse_decode_deadline) == 0)
        {
            const replay = mouse_decoder.flush().?;
            mouse_decode_deadline = null;
            var forwarded: ForwardBuffer = .{};
            for (replay.slice()) |byte| {
                try routePrefixByte(
                    allocator,
                    byte,
                    &forwarded,
                    &prefix,
                    &prefix_menu_visible,
                    &rename_prompt,
                    &outer,
                    &stream,
                    size,
                );
            }
            try forwarded.flush(allocator, &stream);
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

fn sendMouseInput(
    allocator: std.mem.Allocator,
    stream: *transport.Stream,
    event: mouse_mod.Event,
) !void {
    const payload = try control.encode(allocator, control.MouseInput{
        .x = event.x,
        .y = event.y,
        .button = event.button,
        .pressed = event.pressed,
        .shift = event.shift,
        .alt = event.alt,
        .ctrl = event.ctrl,
    });
    defer allocator.free(payload);
    try stream.send(allocator, .input_event, 0, payload);
}

const ForwardBuffer = struct {
    bytes: [8192]u8 = undefined,
    count: usize = 0,

    fn append(
        self: *ForwardBuffer,
        allocator: std.mem.Allocator,
        stream: *transport.Stream,
        byte: u8,
    ) !void {
        if (self.count == self.bytes.len) try self.flush(allocator, stream);
        self.bytes[self.count] = byte;
        self.count += 1;
    }

    fn flush(
        self: *ForwardBuffer,
        allocator: std.mem.Allocator,
        stream: *transport.Stream,
    ) !void {
        if (self.count == 0) return;
        try stream.send(
            allocator,
            .input_bytes,
            0,
            self.bytes[0..self.count],
        );
        self.count = 0;
    }
};

fn refreshMouseDeadline(
    decoder: *const mouse_mod.Decoder,
    deadline: *?u64,
) void {
    if (!decoder.hasPending()) {
        deadline.* = null;
    } else if (deadline.* == null) {
        deadline.* = reactor.nowMillis() + escape_sequence_timeout_ms;
    }
}

fn mousePollTimeout(deadline: ?u64) i32 {
    const expires = deadline orelse return -1;
    const now = reactor.nowMillis();
    if (expires <= now) return 0;
    return @intCast(@min(
        expires - now,
        @as(u64, std.math.maxInt(i32)),
    ));
}

fn routePrefixByte(
    allocator: std.mem.Allocator,
    byte: u8,
    forwarded: *ForwardBuffer,
    prefix: *prefix_mod.Router,
    prefix_menu_visible: *bool,
    rename_prompt: *RenamePrompt,
    outer: *raw_mode.Terminal,
    stream: *transport.Stream,
    size: raw_mode.Size,
) !void {
    const route = prefix.feed(byte);
    const next_menu_visible = prefix.menuActive();
    if (next_menu_visible != prefix_menu_visible.*) {
        try forwarded.flush(allocator, stream);
    }
    try syncPrefixMenu(
        allocator,
        stream,
        prefix_menu_visible,
        next_menu_visible,
    );
    switch (route) {
        .forward => |value| try forwarded.append(allocator, stream, value),
        .command => |command| {
            try forwarded.flush(allocator, stream);
            switch (command) {
                .send_prefix => try forwarded.append(
                    allocator,
                    stream,
                    prefix.prefix_byte,
                ),
                .detach => try stream.send(
                    allocator,
                    .detach_request,
                    3,
                    "{\"reason\":\"requested\"}",
                ),
                .new_pane => try sendCommand(allocator, stream, "new-pane"),
                .close_pane => try sendCommand(allocator, stream, "close-pane"),
                .focus_left => try sendCommand(allocator, stream, "focus-left"),
                .focus_right => try sendCommand(allocator, stream, "focus-right"),
                .focus_up => try sendCommand(allocator, stream, "focus-up"),
                .focus_down => try sendCommand(allocator, stream, "focus-down"),
                .scroll_left => try sendCommand(allocator, stream, "scroll-left"),
                .scroll_right => try sendCommand(allocator, stream, "scroll-right"),
                .resize_narrower => try sendCommand(
                    allocator,
                    stream,
                    "resize-narrower",
                ),
                .resize_wider => try sendCommand(
                    allocator,
                    stream,
                    "resize-wider",
                ),
                .new_workspace => try sendCommand(
                    allocator,
                    stream,
                    "new-workspace",
                ),
                .rename_session => {
                    rename_prompt.active = true;
                    rename_prompt.buffer.clearRetainingCapacity();
                    try outer.write(disable_mouse);
                    try drawRenamePrompt(outer, rename_prompt, size);
                },
                .dismiss_prefix => {},
                else => try outer.write("\x07"),
            }
        },
        .wait => {},
        .rejected => try outer.write("\x07"),
    }
}

fn syncPrefixMenu(
    allocator: std.mem.Allocator,
    stream: *transport.Stream,
    visible: *bool,
    next: bool,
) !void {
    if (visible.* == next) return;
    const payload = try control.encode(allocator, control.Command{
        .command = "prefix-menu",
        .value = if (next) "open" else "closed",
    });
    defer allocator.free(payload);
    try stream.send(allocator, .command_request, 5, payload);
    visible.* = next;
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
            try outer.write("\x1b[?25l" ++ enable_mouse);
            return;
        },
        0x1b, 0x03 => {
            prompt.active = false;
            try outer.write("\x1b[?25l" ++ enable_mouse);
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
