const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.addModule("compositor", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = core });
    const core_run = b.addRunArtifact(tests);
    b.step("test-core", "Test window management without terminal I/O").dependOn(&core_run.step);
    const test_step = b.step("test", "Test geometry and terminal adapter");
    test_step.dependOn(&core_run.step);
    const input_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(input_tests).step);
    const vt = b.dependency("ghostty_vt", .{
        .target = target,
        .optimize = optimize,
    }).module("ghostty-vt");
    const terminal = b.addModule("terminal", .{
        .root_source_file = b.path("src/terminal.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "ghostty-vt", .module = vt }, .{ .name = "compositor", .module = core } },
    });
    const vt_tests = b.addTest(.{ .root_module = terminal });
    // Reuse the pinned archive's decoder module instead of a second image dependency.
    terminal.addImport("wuffs", vt.import_table.get("wuffs").?);
    const vt_run = b.addRunArtifact(vt_tests);
    b.step("test-vt", "Test the libghostty-vt adapter").dependOn(&vt_run.step);
    test_step.dependOn(&vt_run.step);
    const terminal_demo = b.addExecutable(.{
        .name = "terminal-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/terminal.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "terminal", .module = terminal }},
        }),
    });
    b.step("demo-vt", "Replay terminal output through libghostty-vt").dependOn(&b.addRunArtifact(terminal_demo).step);
    const shell = b.addExecutable(.{
        .name = "tmuxpp-shell",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "terminal", .module = terminal }, .{ .name = "compositor", .module = core }, .{ .name = "ghostty-vt", .module = vt } },
        }),
    });
    shell.root_module.addCSourceFile(.{ .file = b.path("src/host.c"), .flags = &.{ "-std=c11", "-D_DEFAULT_SOURCE", "-Wall", "-Wextra" } });
    if (target.result.os.tag == .linux) shell.root_module.linkSystemLibrary("util", .{});
    b.installArtifact(shell);
    b.installArtifact(terminal_demo);
    b.step("shell", "Run docked and main interactive shells").dependOn(&b.addRunArtifact(shell).step);
    const renderer_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/renderer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "terminal", .module = terminal }, .{ .name = "compositor", .module = core }, .{ .name = "ghostty-vt", .module = vt } },
    }) });
    const renderer_run = b.addRunArtifact(renderer_tests);
    test_step.dependOn(&renderer_run.step);
    b.step("test-renderer", "Round-trip rendered frames through a second terminal").dependOn(&renderer_run.step);
    const demo = b.addExecutable(.{
        .name = "layout-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/layout.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "compositor", .module = core }},
        }),
    });
    b.installArtifact(demo);
    b.step("demo", "Print a scene with docks, tiles and a floating window").dependOn(&b.addRunArtifact(demo).step);
}
