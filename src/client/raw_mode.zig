const c = @cImport({
    @cInclude("raw_bridge.h");
    @cInclude("signal.h");
});

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const Ready = packed struct(u8) {
    stdin: bool = false,
    pty: bool = false,
    signal: bool = false,
    padding: u5 = 0,
};

pub const Terminal = struct {
    handle: *c.NorenRawTerminal,
    restored: bool = false,

    pub fn enter() !Terminal {
        return .{
            .handle = c.noren_raw_enter() orelse return error.NotInteractiveTerminal,
        };
    }

    pub fn restore(self: *Terminal) void {
        if (self.restored) return;
        c.noren_raw_restore(self.handle);
        self.restored = true;
    }

    pub fn size(_: *const Terminal) !Size {
        var rows: u16 = 0;
        var cols: u16 = 0;
        if (c.noren_raw_get_size(&rows, &cols) != 0) {
            return error.TerminalSizeUnavailable;
        }
        return .{ .rows = rows, .cols = cols };
    }

    pub fn poll(self: *Terminal, pty_fd: c_int, timeout_ms: i32) !Ready {
        var mask: c_int = 0;
        if (c.noren_raw_poll(self.handle, pty_fd, timeout_ms, &mask) != 0) {
            return error.TerminalPollFailed;
        }
        return .{
            .stdin = mask & c.NOREN_POLL_STDIN != 0,
            .pty = mask & c.NOREN_POLL_PTY != 0,
            .signal = mask & c.NOREN_POLL_SIGNAL != 0,
        };
    }

    pub fn readInput(_: *Terminal, buffer: []u8) ![]u8 {
        var count: usize = 0;
        if (c.noren_raw_read(buffer.ptr, buffer.len, &count) != 0) {
            return error.TerminalReadFailed;
        }
        return buffer[0..count];
    }

    pub fn write(_: *Terminal, bytes: []const u8) !void {
        if (c.noren_raw_write(bytes.ptr, bytes.len) != 0) {
            return error.TerminalWriteFailed;
        }
    }

    pub fn takeSignal(self: *Terminal) ?Signal {
        return switch (c.noren_raw_take_signal(self.handle)) {
            c.SIGTERM => .terminate,
            c.SIGHUP => .hangup,
            c.SIGWINCH => .resize,
            else => null,
        };
    }
};

pub const Signal = enum {
    terminate,
    hangup,
    resize,
};
