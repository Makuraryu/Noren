const std = @import("std");
const builtin = @import("builtin");
const frame = @import("../protocol/frame.zig");

const c = @cImport({
    @cInclude("socket_bridge.h");
    @cInclude("stdlib.h");
});

pub const Stream = struct {
    fd: c_int,
    closed: bool = false,

    pub fn connect(allocator: std.mem.Allocator, path: []const u8) !Stream {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const fd = c.noren_socket_connect(path_z.ptr);
        if (fd < 0) return error.ServerUnavailable;
        return .{ .fd = fd };
    }

    pub fn close(self: *Stream) void {
        if (self.closed) return;
        _ = c.noren_socket_close(self.fd);
        self.closed = true;
    }

    pub fn send(
        self: *Stream,
        allocator: std.mem.Allocator,
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
        if (c.noren_socket_write_all(self.fd, encoded.ptr, encoded.len) != 0) {
            return error.ConnectionWriteFailed;
        }
    }

    pub fn read(self: *Stream, buffer: []u8) !ReadResult {
        var count: usize = 0;
        return switch (c.noren_socket_read(
            self.fd,
            buffer.ptr,
            buffer.len,
            &count,
        )) {
            c.NOREN_SOCKET_OK => .{ .data = buffer[0..count] },
            c.NOREN_SOCKET_WOULD_BLOCK => .would_block,
            c.NOREN_SOCKET_EOF => .eof,
            else => error.ConnectionReadFailed,
        };
    }

    pub fn writeSome(self: *Stream, bytes: []const u8) !WriteResult {
        var count: usize = 0;
        return switch (c.noren_socket_write_some(
            self.fd,
            bytes.ptr,
            bytes.len,
            &count,
        )) {
            c.NOREN_SOCKET_OK => .{ .written = count },
            c.NOREN_SOCKET_WOULD_BLOCK => .would_block,
            else => error.ConnectionWriteFailed,
        };
    }
};

pub const Listener = struct {
    fd: c_int,
    path: [:0]u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Listener {
        const path_z = try allocator.dupeZ(u8, path);
        errdefer allocator.free(path_z);
        if (c.noren_socket_prepare(path_z.ptr) != 0) {
            return error.InsecureRuntimeDirectory;
        }
        if (Stream.connect(allocator, path)) |stream_value| {
            var stream = stream_value;
            stream.close();
            return error.ServerAlreadyRunning;
        } else |_| {}
        _ = c.noren_socket_remove(path_z.ptr);
        const fd = c.noren_socket_listen(path_z.ptr);
        if (fd < 0) return error.SocketListenFailed;
        return .{ .fd = fd, .path = path_z, .allocator = allocator };
    }

    pub fn accept(self: *Listener) !Stream {
        const fd = c.noren_socket_accept(self.fd);
        if (fd < 0) return error.SocketAcceptFailed;
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Listener) void {
        _ = c.noren_socket_close(self.fd);
        _ = c.noren_socket_remove(self.path.ptr);
        self.allocator.free(self.path);
        self.* = undefined;
    }
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

pub const Ready = packed struct(u8) {
    first: bool = false,
    second: bool = false,
    third: bool = false,
    second_write: bool = false,
    padding: u4 = 0,
};

pub fn poll3(
    first: c_int,
    second: c_int,
    third: c_int,
    timeout_ms: i32,
    watch_second_write: bool,
) !Ready {
    var mask: c_int = 0;
    if (c.noren_socket_poll3(
        first,
        second,
        third,
        timeout_ms,
        @intFromBool(watch_second_write),
        &mask,
    ) < 0) {
        return error.SocketPollFailed;
    }
    return .{
        .first = mask & 1 != 0,
        .second = mask & 2 != 0,
        .third = mask & 4 != 0,
        .second_write = mask & 8 != 0,
    };
}

pub fn defaultSocketPath(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .linux) {
        if (c.getenv("XDG_RUNTIME_DIR")) |directory| {
            const path = std.mem.span(directory);
            if (path.len > 0) {
                return std.fmt.allocPrint(
                    allocator,
                    "{s}/noren/default.sock",
                    .{path},
                );
            }
        }
    }
    const temporary = if (c.getenv("TMPDIR")) |directory|
        std.mem.span(directory)
    else
        "/tmp";
    return std.fmt.allocPrint(
        allocator,
        "{s}/noren-{d}/default.sock",
        .{ temporary, c.noren_user_id() },
    );
}
