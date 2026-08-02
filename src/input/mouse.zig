const std = @import("std");

const max_sequence_len = 64;

pub const Event = struct {
    x: u16,
    y: u16,
    button: u8,
    pressed: bool,
    shift: bool,
    alt: bool,
    ctrl: bool,
};

pub const Replay = struct {
    bytes: [max_sequence_len]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Replay) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Result = union(enum) {
    forward: u8,
    mouse: Event,
    replay: Replay,
    wait,
};

const State = enum {
    normal,
    escape,
    csi,
    mouse,
};

pub const Decoder = struct {
    state: State = .normal,
    pending: [max_sequence_len]u8 = undefined,
    pending_len: usize = 0,

    pub fn hasPending(self: *const Decoder) bool {
        return self.pending_len > 0;
    }

    pub fn feed(self: *Decoder, byte: u8) Result {
        switch (self.state) {
            .normal => {
                if (byte != 0x1b) return .{ .forward = byte };
                self.start(byte);
                self.state = .escape;
                return .wait;
            },
            .escape => {
                self.append(byte);
                if (byte == '[') {
                    self.state = .csi;
                    return .wait;
                }
                return .{ .replay = self.takeReplay() };
            },
            .csi => {
                self.append(byte);
                if (byte == '<') {
                    self.state = .mouse;
                    return .wait;
                }
                return .{ .replay = self.takeReplay() };
            },
            .mouse => {
                self.append(byte);
                if (byte == 'M' or byte == 'm') {
                    const replay = self.snapshot();
                    const event = parseEvent(replay.slice());
                    self.reset();
                    return if (event) |value|
                        .{ .mouse = value }
                    else
                        .{ .replay = replay };
                }
                if ((byte < '0' or byte > '9') and byte != ';') {
                    return .{ .replay = self.takeReplay() };
                }
                if (self.pending_len == max_sequence_len) {
                    return .{ .replay = self.takeReplay() };
                }
                return .wait;
            },
        }
    }

    pub fn flush(self: *Decoder) ?Replay {
        if (!self.hasPending()) return null;
        return self.takeReplay();
    }

    fn start(self: *Decoder, byte: u8) void {
        self.pending[0] = byte;
        self.pending_len = 1;
    }

    fn append(self: *Decoder, byte: u8) void {
        if (self.pending_len == max_sequence_len) return;
        self.pending[self.pending_len] = byte;
        self.pending_len += 1;
    }

    fn snapshot(self: *const Decoder) Replay {
        var result: Replay = .{ .len = self.pending_len };
        @memcpy(result.bytes[0..self.pending_len], self.pending[0..self.pending_len]);
        return result;
    }

    fn takeReplay(self: *Decoder) Replay {
        const result = self.snapshot();
        self.reset();
        return result;
    }

    fn reset(self: *Decoder) void {
        self.state = .normal;
        self.pending_len = 0;
    }
};

fn parseEvent(sequence: []const u8) ?Event {
    if (sequence.len < 7 or
        !std.mem.eql(u8, sequence[0..3], "\x1b[<")) return null;
    const final = sequence[sequence.len - 1];
    var fields = std.mem.splitScalar(u8, sequence[3 .. sequence.len - 1], ';');
    const raw_code = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch
        return null;
    const raw_x = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch
        return null;
    const raw_y = std.fmt.parseInt(u16, fields.next() orelse return null, 10) catch
        return null;
    if (fields.next() != null or raw_x == 0 or raw_y == 0) return null;

    const base = raw_code & 0b11;
    const wheel = raw_code & 0b0100_0000 != 0;
    if ((!wheel and base > 2) or raw_code & 0xff00 != 0) return null;
    return .{
        .x = raw_x - 1,
        .y = raw_y - 1,
        .button = if (wheel) @intCast(4 + base) else @intCast(base + 1),
        .pressed = if (wheel) true else final == 'M',
        .shift = raw_code & 0b0000_0100 != 0,
        .alt = raw_code & 0b0000_1000 != 0,
        .ctrl = raw_code & 0b0001_0000 != 0,
    };
}

test "SGR mouse decoder accepts sequences split across reads" {
    var decoder: Decoder = .{};
    const sequence = "\x1b[<16;12;7M";
    for (sequence[0 .. sequence.len - 1]) |byte| {
        try std.testing.expect(decoder.feed(byte) == .wait);
    }
    const event = decoder.feed(sequence[sequence.len - 1]).mouse;
    try std.testing.expectEqual(@as(u16, 11), event.x);
    try std.testing.expectEqual(@as(u16, 6), event.y);
    try std.testing.expectEqual(@as(u8, 1), event.button);
    try std.testing.expect(event.pressed);
    try std.testing.expect(event.ctrl);
    try std.testing.expect(!decoder.hasPending());
}

test "non-mouse escape sequences replay without loss" {
    var decoder: Decoder = .{};
    try std.testing.expect(decoder.feed(0x1b) == .wait);
    try std.testing.expect(decoder.feed('[') == .wait);
    const replay = decoder.feed('D').replay;
    try std.testing.expectEqualStrings("\x1b[D", replay.slice());
}

test "an incomplete sequence can be flushed after the input timeout" {
    var decoder: Decoder = .{};
    try std.testing.expect(decoder.feed(0x1b) == .wait);
    const replay = decoder.flush().?;
    try std.testing.expectEqualStrings("\x1b", replay.slice());
    try std.testing.expect(decoder.flush() == null);
}
