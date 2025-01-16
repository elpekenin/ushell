const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ushell = b.addModule("ushell", .{
        .root_source_file = b.path("src/ushell.zig"),
        .optimize = optimize,
        .target = target,
    });

    // Dependencies
    const ansi_term = b.dependency("ansi-term", .{
        .optimize = optimize,
        .target = target,
    }).module("ansi-term");

    ushell.addImport("ansi-term", ansi_term);

    // Example
    const echo_exe = b.addExecutable(.{
        .name = "echo",
        .target = target,
        .root_source_file = b.path("examples/echo.zig"),
    });
    echo_exe.root_module.addImport("ushell", ushell);

    const run_echo_step = b.step("run", "Run echo example");
    const run_echo = b.addRunArtifact(echo_exe);
    run_echo_step.dependOn(&run_echo.step);

    const build_echo_step = b.step("build", "Build echo example");
    const build_echo = b.addInstallArtifact(echo_exe, .{});
    build_echo_step.dependOn(&build_echo.step);
}
