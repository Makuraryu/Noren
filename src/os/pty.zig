const std = @import("std");

const c = @cImport({
    @cInclude("pty_bridge.h");
    @cInclude("signal.h");
});

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const SpawnOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    /// Full `KEY=value` environment. Null inherits the current environment.
    environment: ?[]const []const u8 = null,
    size: Size,
};

pub const ReadResult = union(enum) {
    data: []u8,
    would_block,
    eof,
};

pub const WriteResult = union(enum) {
    written: usize,
    would_block,
};

pub const WaitResult = union(enum) {
    running,
    exited: i32,
};

pub const Signal = enum {
    hup,
    term,
    kill,
};

pub const Pty = struct {
    master_fd: c_int,
    root_pid: c_int,
    generation: u64 = 1,
    closed: bool = false,

    pub fn spawn(allocator: std.mem.Allocator, options: SpawnOptions) !Pty {
        if (options.argv.len == 0) return error.MissingCommand;
        var argv = try CStringVector.init(allocator, options.argv);
        defer argv.deinit(allocator);
        var environment: ?CStringVector = if (options.environment) |entries|
            try CStringVector.init(allocator, entries)
        else
            null;
        defer if (environment) |*entries| entries.deinit(allocator);
        const cwd = if (options.cwd) |path| try allocator.dupeZ(u8, path) else null;
        defer if (cwd) |path| allocator.free(path);

        var result: c.NorenPtySpawnResult = undefined;
        const status = c.noren_pty_spawn(
            if (cwd) |path| path.ptr else null,
            @ptrCast(argv.pointers.ptr),
            if (environment) |*entries| @ptrCast(entries.pointers.ptr) else null,
            options.size.rows,
            options.size.cols,
            &result,
        );
        if (status != 0) return error.PtySpawnFailed;
        return .{
            .master_fd = result.master_fd,
            .root_pid = result.root_pid,
        };
    }

    pub fn resize(self: *Pty, size: Size) !void {
        if (self.closed) return error.PtyClosed;
        if (size.rows == 0 or size.cols == 0) return error.InvalidPtySize;
        if (c.noren_pty_resize(self.master_fd, size.rows, size.cols) != 0) {
            return error.PtyResizeFailed;
        }
    }

    pub fn read(self: *Pty, buffer: []u8) !ReadResult {
        if (self.closed) return error.PtyClosed;
        var count: usize = 0;
        const status = c.noren_pty_read(
            self.master_fd,
            buffer.ptr,
            buffer.len,
            &count,
        );
        return switch (status) {
            c.NOREN_IO_OK => .{ .data = buffer[0..count] },
            c.NOREN_IO_WOULD_BLOCK => .would_block,
            c.NOREN_IO_EOF => .eof,
            else => error.PtyReadFailed,
        };
    }

    pub fn write(self: *Pty, bytes: []const u8) !WriteResult {
        if (self.closed) return error.PtyClosed;
        var count: usize = 0;
        const status = c.noren_pty_write(
            self.master_fd,
            bytes.ptr,
            bytes.len,
            &count,
        );
        return switch (status) {
            c.NOREN_IO_OK => .{ .written = count },
            c.NOREN_IO_WOULD_BLOCK => .would_block,
            else => error.PtyWriteFailed,
        };
    }

    pub fn pollReadable(self: *Pty, timeout_ms: u16) !bool {
        if (self.closed) return error.PtyClosed;
        const result = c.noren_pty_poll_readable(self.master_fd, timeout_ms);
        if (result < 0) return error.PtyPollFailed;
        return result > 0;
    }

    pub fn signalGroup(self: *Pty, signal: Signal) !void {
        const number: c_int = switch (signal) {
            .hup => c.SIGHUP,
            .term => c.SIGTERM,
            .kill => c.SIGKILL,
        };
        if (c.noren_pty_signal_group(self.root_pid, number) != 0) {
            return error.PtySignalFailed;
        }
    }

    pub fn wait(self: *Pty, no_hang: bool) !WaitResult {
        var status: c_int = 0;
        const result = c.noren_pty_wait(
            self.root_pid,
            &status,
            @intFromBool(no_hang),
        );
        if (result < 0) return error.PtyWaitFailed;
        if (result == 0) return .running;
        return .{ .exited = status };
    }

    pub fn close(self: *Pty) void {
        if (self.closed) return;
        _ = c.noren_pty_close(self.master_fd);
        self.closed = true;
        self.master_fd = -1;
        self.generation +%= 1;
    }
};

const CStringVector = struct {
    strings: [][:0]u8,
    pointers: []?[*:0]const u8,

    fn init(allocator: std.mem.Allocator, values: []const []const u8) !CStringVector {
        const strings = try allocator.alloc([:0]u8, values.len);
        errdefer allocator.free(strings);
        var initialized: usize = 0;
        errdefer for (strings[0..initialized]) |string| allocator.free(string);
        const pointers = try allocator.alloc(?[*:0]const u8, values.len + 1);
        errdefer allocator.free(pointers);
        for (values, 0..) |value, index| {
            const string = try allocator.dupeZ(u8, value);
            strings[index] = string;
            initialized += 1;
            pointers[index] = @ptrCast(string.ptr);
        }
        pointers[values.len] = null;
        return .{ .strings = strings, .pointers = pointers };
    }

    fn deinit(self: *CStringVector, allocator: std.mem.Allocator) void {
        for (self.strings) |string| allocator.free(string);
        allocator.free(self.strings);
        allocator.free(self.pointers);
        self.* = undefined;
    }
};

test "PTY spawns a process with cwd and initial dimensions" {
    const allocator = std.testing.allocator;
    var pty = try Pty.spawn(allocator, .{
        .argv = &.{ "sh", "-c", "pwd; stty size; printf ready" },
        .cwd = "/",
        .size = .{ .rows = 7, .cols = 19 },
    });
    defer {
        pty.close();
        _ = pty.wait(true) catch {};
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var buffer: [1024]u8 = undefined;
    var saw_eof = false;
    for (0..20) |_| {
        _ = try pty.pollReadable(250);
        switch (try pty.read(&buffer)) {
            .data => |bytes| try output.appendSlice(allocator, bytes),
            .would_block => {},
            .eof => {
                saw_eof = true;
                break;
            },
        }
    }
    _ = try pty.wait(false);
    try std.testing.expect(saw_eof);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "7 19") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ready") != null);
}
