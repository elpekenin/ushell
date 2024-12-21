const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("ushell", .{
        .root_source_file = b.path("src/mod.zig"),
    });

    const test_step = b.step("test", "Run test suite");

    const parser_tests = b.addTest(.{
        .root_source_file = b.path("src/Parser.zig"),
    });
    const run_parser_tests = b.addRunArtifact(parser_tests);
    test_step.dependOn(&run_parser_tests.step);
}
