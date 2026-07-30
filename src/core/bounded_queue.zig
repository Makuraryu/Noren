const std = @import("std");

/// A compact bounded byte queue. Limits are checked before allocation, so
/// peer-controlled input cannot cause growth beyond `limit`.
pub const BoundedByteQueue = struct {
    bytes: std.ArrayList(u8) = .empty,
    head: usize = 0,
    limit: usize,

    pub fn init(limit: usize) BoundedByteQueue {
        return .{ .limit = limit };
    }

    pub fn deinit(self: *BoundedByteQueue, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = undefined;
    }

    pub fn len(self: *const BoundedByteQueue) usize {
        return self.bytes.items.len - self.head;
    }

    pub fn append(
        self: *BoundedByteQueue,
        allocator: std.mem.Allocator,
        data: []const u8,
    ) !void {
        if (data.len > self.limit -| self.len()) return error.QueueFull;
        self.compact();
        try self.bytes.appendSlice(allocator, data);
    }

    pub fn peek(self: *const BoundedByteQueue) []const u8 {
        return self.bytes.items[self.head..];
    }

    pub fn consume(self: *BoundedByteQueue, count: usize) void {
        const amount = @min(count, self.len());
        self.head += amount;
        if (self.head == self.bytes.items.len) {
            self.bytes.clearRetainingCapacity();
            self.head = 0;
        }
    }

    fn compact(self: *BoundedByteQueue) void {
        if (self.head == 0) return;
        const remaining = self.len();
        std.mem.copyForwards(u8, self.bytes.items[0..remaining], self.peek());
        self.bytes.items.len = remaining;
        self.head = 0;
    }
};

test "bounded queue rejects growth beyond its cap" {
    const allocator = std.testing.allocator;
    var queue = BoundedByteQueue.init(4);
    defer queue.deinit(allocator);

    try queue.append(allocator, "abc");
    try std.testing.expectError(error.QueueFull, queue.append(allocator, "de"));
    queue.consume(2);
    try queue.append(allocator, "de");
    try std.testing.expectEqualStrings("cde", queue.peek());
}
