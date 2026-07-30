const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const noren = b.addModule("noren", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    noren.addIncludePath(b.path("vendor/libvterm/include"));
    noren.addIncludePath(b.path("vendor/libvterm/src"));
    noren.addIncludePath(b.path("src/terminal"));
    noren.addIncludePath(b.path("src/os"));
    noren.addIncludePath(b.path("src/client"));
    noren.addIncludePath(b.path("src/server"));
    noren.addCSourceFiles(.{
        .files = &.{
            "vendor/libvterm/src/encoding.c",
            "vendor/libvterm/src/keyboard.c",
            "vendor/libvterm/src/mouse.c",
            "vendor/libvterm/src/parser.c",
            "vendor/libvterm/src/pen.c",
            "vendor/libvterm/src/screen.c",
            "vendor/libvterm/src/state.c",
            "vendor/libvterm/src/unicode.c",
            "vendor/libvterm/src/vterm.c",
            "src/terminal/libvterm_bridge.c",
            "src/os/pty_bridge.c",
            "src/client/raw_bridge.c",
            "src/server/socket_bridge.c",
        },
        .flags = &.{ "-std=c99", "-Wall", "-Wextra" },
    });
    noren.linkSystemLibrary("c", .{});

    const exe = b.addExecutable(.{
        .name = "noren",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noren", .module = noren },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run Noren");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = noren,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "noren", .module = noren },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_step = b.step("test-integration", "Run integration tests");
    integration_step.dependOn(&run_integration_tests.step);

    const e2e_cmd = b.addSystemCommand(&.{ "sh", "tests/e2e/smoke.sh" });
    e2e_cmd.addFileArg(exe.getEmittedBin());
    const e2e_step = b.step("test-e2e", "Run end-to-end tests");
    e2e_step.dependOn(&e2e_cmd.step);
}
