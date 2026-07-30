const std = @import("std");
const BoundedByteQueue = @import("../core/bounded_queue.zig").BoundedByteQueue;

pub const magic = [4]u8{ 'N', 'R', 'N', '1' };
pub const header_len: usize = 20;
pub const max_payload_len: usize = 16 * 1024 * 1024;

pub const Version = struct {
    major: u16 = 1,
    minor: u16 = 0,
};

pub const Kind = enum(u16) {
    hello = 1,
    welcome = 2,
    attach_request = 3,
    attached = 4,
    command_request = 5,
    command_result = 6,
    input_bytes = 7,
    input_event = 8,
    client_resize = 9,
    detach_request = 10,
    render_bytes = 11,
    notice = 12,
    error_message = 13,
    detached = 14,
    ping = 15,
    pong = 16,
    _,
};

pub const Header = struct {
    version: Version,
    kind: Kind,
    flags: u16,
    request_id: u32,
    payload_len: u32,
};

pub const OwnedFrame = struct {
    header: Header,
    payload: []u8,

    pub fn deinit(self: *OwnedFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    header: Header,
    payload: []const u8,
) ![]u8 {
    if (payload.len > max_payload_len or payload.len > std.math.maxInt(u32)) {
        return error.FrameTooLarge;
    }
    if (header.payload_len != payload.len) return error.PayloadLengthMismatch;
    const bytes = try allocator.alloc(u8, header_len + payload.len);
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..4], &magic);
    putU16(bytes[4..6], header.version.major);
    putU16(bytes[6..8], header.version.minor);
    putU16(bytes[8..10], @intFromEnum(header.kind));
    putU16(bytes[10..12], header.flags);
    putU32(bytes[12..16], header.request_id);
    putU32(bytes[16..20], header.payload_len);
    @memcpy(bytes[20..], payload);
    return bytes;
}

pub fn decodeHeader(bytes: []const u8) !Header {
    if (bytes.len < header_len) return error.NeedMoreData;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidMagic;
    const payload_len = getU32(bytes[16..20]);
    if (payload_len > max_payload_len) return error.FrameTooLarge;
    return .{
        .version = .{
            .major = getU16(bytes[4..6]),
            .minor = getU16(bytes[6..8]),
        },
        .kind = @enumFromInt(getU16(bytes[8..10])),
        .flags = getU16(bytes[10..12]),
        .request_id = getU32(bytes[12..16]),
        .payload_len = payload_len,
    };
}

pub const Parser = struct {
    queue: BoundedByteQueue = BoundedByteQueue.init(header_len + max_payload_len),

    pub fn deinit(self: *Parser, allocator: std.mem.Allocator) void {
        self.queue.deinit(allocator);
        self.* = undefined;
    }

    pub fn feed(
        self: *Parser,
        allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !void {
        self.queue.append(allocator, bytes) catch |err| switch (err) {
            error.QueueFull => return error.FrameBufferLimitExceeded,
            else => return err,
        };
        if (self.queue.len() >= header_len) {
            _ = try decodeHeader(self.queue.peek()[0..header_len]);
        }
    }

    pub fn next(
        self: *Parser,
        allocator: std.mem.Allocator,
    ) !?OwnedFrame {
        if (self.queue.len() < header_len) return null;
        const header = try decodeHeader(self.queue.peek()[0..header_len]);
        const total_len = header_len + @as(usize, header.payload_len);
        if (self.queue.len() < total_len) return null;
        const payload = try allocator.dupe(u8, self.queue.peek()[header_len..total_len]);
        self.queue.consume(total_len);
        return .{ .header = header, .payload = payload };
    }
};

fn putU16(out: []u8, value: u16) void {
    out[0] = @truncate(value >> 8);
    out[1] = @truncate(value);
}

fn putU32(out: []u8, value: u32) void {
    out[0] = @truncate(value >> 24);
    out[1] = @truncate(value >> 16);
    out[2] = @truncate(value >> 8);
    out[3] = @truncate(value);
}

fn getU16(input: []const u8) u16 {
    return (@as(u16, input[0]) << 8) | input[1];
}

fn getU32(input: []const u8) u32 {
    return (@as(u32, input[0]) << 24) |
        (@as(u32, input[1]) << 16) |
        (@as(u32, input[2]) << 8) |
        input[3];
}

test "frame parser accepts fragmented input" {
    const allocator = std.testing.allocator;
    const header: Header = .{
        .version = .{},
        .kind = .hello,
        .flags = 0,
        .request_id = 42,
        .payload_len = 2,
    };
    const encoded = try encodeAlloc(allocator, header, "{}");
    defer allocator.free(encoded);
    var parser: Parser = .{};
    defer parser.deinit(allocator);

    try parser.feed(allocator, encoded[0..7]);
    try std.testing.expect((try parser.next(allocator)) == null);
    try parser.feed(allocator, encoded[7..]);
    var frame = (try parser.next(allocator)).?;
    defer frame.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 42), frame.header.request_id);
    try std.testing.expectEqualStrings("{}", frame.payload);
}

test "frame parser handles multiple frames in one read" {
    const allocator = std.testing.allocator;
    const header: Header = .{
        .version = .{},
        .kind = .ping,
        .flags = 0,
        .request_id = 1,
        .payload_len = 0,
    };
    const encoded = try encodeAlloc(allocator, header, "");
    defer allocator.free(encoded);
    var parser: Parser = .{};
    defer parser.deinit(allocator);
    try parser.feed(allocator, encoded);
    try parser.feed(allocator, encoded);

    var first = (try parser.next(allocator)).?;
    defer first.deinit(allocator);
    var second = (try parser.next(allocator)).?;
    defer second.deinit(allocator);
    try std.testing.expect((try parser.next(allocator)) == null);
}
