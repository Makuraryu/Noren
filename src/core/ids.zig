const std = @import("std");

pub const SessionId = enum(u64) { _ };
pub const WorkspaceId = enum(u64) { _ };
pub const PaneId = enum(u64) { _ };
pub const ClientId = enum(u64) { _ };
pub const LayerId = enum(u64) { _ };
pub const TimerId = enum(u64) { _ };
pub const ConnectionId = enum(u64) { _ };

pub fn value(id: anytype) u64 {
    return @intFromEnum(id);
}

/// Server-local monotonic ID source. Zero is never emitted and IDs are never
/// recycled during the lifetime of a server process.
pub const IdGenerator = struct {
    next_value: u64 = 1,

    pub fn next(self: *IdGenerator, comptime T: type) !T {
        if (self.next_value == std.math.maxInt(u64)) return error.IdSpaceExhausted;
        const raw = self.next_value;
        self.next_value += 1;
        return @enumFromInt(raw);
    }
};

test "IDs are monotonic and never reused" {
    var ids: IdGenerator = .{};
    const s1 = try ids.next(SessionId);
    const p1 = try ids.next(PaneId);
    const s2 = try ids.next(SessionId);

    try std.testing.expectEqual(@as(u64, 1), value(s1));
    try std.testing.expectEqual(@as(u64, 2), value(p1));
    try std.testing.expectEqual(@as(u64, 3), value(s2));
}
