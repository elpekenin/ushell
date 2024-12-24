const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const ushell = b.addModule("ushell", .{
        .root_source_file = b.path("src/ushell.zig"),
    });

    // Test suite
    const test_step = b.step("test", "Run test suite");

    const parser_tests = b.addTest(.{
        .root_source_file = b.path("src/Parser.zig"),
    });

    const run_parser_tests = b.addRunArtifact(parser_tests);
    test_step.dependOn(&run_parser_tests.step);

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
