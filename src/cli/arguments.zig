const std = @import("std");

pub const Invocation = struct {
    executable: []const u8,
    command: []const u8,
    command_args: []const []const u8,
};

pub fn parse(args: []const []const u8) Invocation {
    return .{
        .executable = if (args.len > 0) args[0] else "noren",
        .command = if (args.len > 1) args[1] else "new",
        .command_args = if (args.len > 1) args[2..] else &.{},
    };
}

test "an invocation without arguments safely defaults to new" {
    const args = [_][]const u8{"noren"};
    const invocation = parse(&args);
    try std.testing.expectEqualStrings("noren", invocation.executable);
    try std.testing.expectEqualStrings("new", invocation.command);
    try std.testing.expectEqual(@as(usize, 0), invocation.command_args.len);
}

test "an invocation separates the command from its arguments" {
    const args = [_][]const u8{ "noren", "attach", "-t", "work" };
    const invocation = parse(&args);
    try std.testing.expectEqualStrings("attach", invocation.command);
    try std.testing.expectEqualStrings("-t", invocation.command_args[0]);
    try std.testing.expectEqualStrings("work", invocation.command_args[1]);
}
