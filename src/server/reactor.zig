const std = @import("std");

const c = @cImport({
    @cInclude("socket_bridge.h");
});

pub const Interest = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    padding: u6 = 0,
};

pub const Ready = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    padding: u6 = 0,
};

pub fn poll(
    fds: []const c_int,
    interests: []const Interest,
    ready: []Ready,
    timeout_ms: i32,
) !void {
    if (fds.len == 0 or interests.len != fds.len or ready.len != fds.len) {
        return error.InvalidPollSet;
    }
    if (c.noren_poll_many(
        fds.ptr,
        @ptrCast(interests.ptr),
        fds.len,
        timeout_ms,
        @ptrCast(ready.ptr),
    ) < 0) return error.PollFailed;
}

pub fn nowMillis() u64 {
    return c.noren_monotonic_millis();
}

pub fn wallClockMinute() u64 {
    return c.noren_wall_clock_minute();
}

pub fn localTimeHhmm(buffer: []u8) ![]const u8 {
    if (buffer.len < 6) return error.BufferTooSmall;
    if (c.noren_format_local_hhmm(buffer.ptr, buffer.len) != 0) {
        return error.LocalTimeUnavailable;
    }
    return buffer[0..5];
}

test "poll rejects mismatched buffers" {
    var ready: [1]Ready = undefined;
    try std.testing.expectError(
        error.InvalidPollSet,
        poll(&.{}, &.{}, &ready, 0),
    );
}

test "monotonic clock is available for reactor deadlines" {
    try std.testing.expect(nowMillis() > 0);
}

test "local status time uses HH:MM" {
    var buffer: [6]u8 = undefined;
    const value = try localTimeHhmm(&buffer);
    try std.testing.expectEqual(@as(usize, 5), value.len);
    try std.testing.expectEqual(@as(u8, ':'), value[2]);
}
