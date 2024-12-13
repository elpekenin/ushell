const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const mod = b.addModule("ushell", .{
        .root_source_file = b.path("src/mod.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "echo",
        .target = target,
        .root_source_file = b.path("examples/echo.zig"),
    });
    exe.root_module.addImport("ushell", mod);

    b.installArtifact(exe);
}
