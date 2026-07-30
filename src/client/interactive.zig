const std = @import("std");
const raw_mode = @import("raw_mode.zig");
const pty_mod = @import("../os/pty.zig");
const terminal_mod = @import("../terminal/backend.zig");
const cell_mod = @import("../terminal/cell.zig");
const canvas_mod = @import("../render/canvas.zig");
const compositor = @import("../render/compositor.zig");
const ansi = @import("../render/ansi.zig");
const placement_mod = @import("../layout/placement.zig");
const ids = @import("../core/ids.zig");
const prefix_mod = @import("../input/prefix.zig");
const BoundedByteQueue = @import("../core/bounded_queue.zig").BoundedByteQueue;

const default_outer_width: u16 = 80;
const max_pty_read_per_tick: usize = 256 * 1024;
const pane_input_limit: usize = 1024 * 1024;

pub const Options = struct {
    argv: []const []const u8,
    cwd: ?[]const u8,
    environment: []const []const u8,
    session_name: []const u8,
};

pub fn run(allocator: std.mem.Allocator, options: Options) !void {
    var outer = try raw_mode.Terminal.enter();
    defer outer.restore();
    try outer.write("\x1b[?1049h\x1b[2J\x1b[H\x1b[?25l\x1b[?2004h");
    defer outer.write(
        "\x1b[0m\x1b[?25h\x1b[?2004l\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1049l",
    ) catch {};

    var outer_size = try outer.size();
    if (outer_size.rows < 4 or outer_size.cols < 3) return error.TerminalTooSmall;
    var pane_size = logicalPaneSize(outer_size);
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
    var canvas = try canvas_mod.Canvas.init(allocator, outer_size.cols, outer_size.rows);
    defer canvas.deinit(allocator);
    var cells = try allocator.alloc(
        cell_mod.Cell,
        @as(usize, pane_size.rows) * pane_size.cols,
    );
    defer allocator.free(cells);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var input_queue = BoundedByteQueue.init(pane_input_limit);
    defer input_queue.deinit(allocator);
    var prefix: prefix_mod.Router = .{};
    var first_frame = true;
    var pty_eof = false;
    var closing = false;

    try render(
        &outer,
        &backend,
        &canvas,
        cells,
        &output,
        options.session_name,
        first_frame,
    );
    first_frame = false;

    while (!pty_eof) {
        const ready = try outer.poll(pty.master_fd, -1);
        if (ready.signal) {
            while (outer.takeSignal()) |signal| switch (signal) {
                .resize => {
                    const new_size = outer.size() catch continue;
                    if (new_size.rows == outer_size.rows and new_size.cols == outer_size.cols) {
                        continue;
                    }
                    outer_size = new_size;
                    if (outer_size.rows < 4 or outer_size.cols < 3) continue;
                    const new_pane_size = logicalPaneSize(outer_size);
                    try pty.resize(new_pane_size);
                    try backend.resize(new_pane_size.rows, new_pane_size.cols);
                    allocator.free(cells);
                    cells = try allocator.alloc(
                        cell_mod.Cell,
                        @as(usize, new_pane_size.rows) * new_pane_size.cols,
                    );
                    pane_size = new_pane_size;
                    canvas.deinit(allocator);
                    canvas = try canvas_mod.Canvas.init(
                        allocator,
                        outer_size.cols,
                        outer_size.rows,
                    );
                    first_frame = true;
                },
                .terminate, .hangup => {
                    closing = true;
                    pty.signalGroup(.hup) catch {};
                },
            };
        }

        if (ready.stdin and !closing) {
            var input_buffer: [8192]u8 = undefined;
            const bytes = try outer.readInput(&input_buffer);
            for (bytes) |byte| {
                switch (prefix.feed(byte)) {
                    .forward => |forwarded| try input_queue.append(
                        allocator,
                        &.{forwarded},
                    ),
                    .command => |command| switch (command) {
                        .send_prefix => try input_queue.append(
                            allocator,
                            &.{prefix.prefix_byte},
                        ),
                        .close_pane, .detach => {
                            closing = true;
                            try pty.signalGroup(.hup);
                        },
                        else => try outer.write("\x07"),
                    },
                    .wait => {},
                    .rejected => try outer.write("\x07"),
                }
            }
        }

        try flushInput(&pty, &input_queue);

        if (ready.pty) {
            var read_budget: usize = 0;
            var pty_buffer: [16 * 1024]u8 = undefined;
            while (read_budget < max_pty_read_per_tick) {
                switch (try pty.read(&pty_buffer)) {
                    .data => |bytes| {
                        read_budget += bytes.len;
                        try backend.feed(bytes);
                        var response_buffer: [4096]u8 = undefined;
                        while (true) {
                            const response = backend.takeOutput(&response_buffer);
                            if (response.len == 0) break;
                            try input_queue.append(allocator, response);
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

        if (backend.takeDamage() or first_frame) {
            try render(
                &outer,
                &backend,
                &canvas,
                cells,
                &output,
                options.session_name,
                first_frame,
            );
            first_frame = false;
        }

        switch (try pty.wait(true)) {
            .running => {},
            .exited => {
                child_reaped = true;
                if (pty_eof) break;
            },
        }
        if (closing and child_reaped) break;
    }

    if (!child_reaped) {
        _ = try pty.wait(false);
        child_reaped = true;
    }
}

fn logicalPaneSize(outer: raw_mode.Size) pty_mod.Size {
    const outer_width = @max(@as(u16, 3), @min(default_outer_width, outer.cols));
    return .{
        .rows = @max(@as(u16, 1), outer.rows -| 3),
        .cols = outer_width - 2,
    };
}

fn render(
    outer: *raw_mode.Terminal,
    backend: *const terminal_mod.TerminalBackend,
    canvas: *canvas_mod.Canvas,
    cells: []cell_mod.Cell,
    output: *std.Io.Writer.Allocating,
    session_name: []const u8,
    clear: bool,
) !void {
    for (0..backend.rows) |row| {
        for (0..backend.cols) |column| {
            cells[row * backend.cols + column] = backend.cellAt(
                @intCast(column),
                @intCast(row),
            );
        }
    }
    const pane_outer_width = backend.cols + 2;
    const pane_outer_rows = backend.rows + 2;
    const visible_width = @min(canvas.width, pane_outer_width);
    const visible_height = @min(canvas.height -| 1, pane_outer_rows);
    const placement: placement_mod.Placement = .{
        .pane_id = @as(ids.PaneId, @enumFromInt(1)),
        .pane_index = 0,
        .world_x = 0,
        .screen_x = 0,
        .outer_width = pane_outer_width,
        .visible = .{
            .x = 0,
            .y = 0,
            .width = visible_width,
            .height = visible_height,
        },
    };
    try compositor.drawPaneSurface(
        canvas,
        placement,
        .{ .cells = cells, .cols = backend.cols, .rows = backend.rows },
        session_name,
        1,
        1,
    );
    const child_cursor = backend.cursor();
    output.clearRetainingCapacity();
    try ansi.writeFull(
        &output.writer,
        canvas,
        .{
            .x = child_cursor.col + 1,
            .y = child_cursor.row + 1,
            .visible = child_cursor.visible and
                child_cursor.col < backend.cols and
                child_cursor.row < backend.rows,
        },
        clear,
    );
    try outer.write(output.written());
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
    const stages = [_]struct {
        signal: pty_mod.Signal,
        attempts: usize,
    }{
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
