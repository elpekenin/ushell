const std = @import("std");

const ushell = @import("ushell");

const Shell = ushell.Wrapper(struct {
    const Self = @This();

    const dummy_input = "echo hello world!\n";

    reader: std.io.AnyReader,
    stop_running: bool = false,

    pub fn readByte(self: *Self) !u8 {
        return self.reader.readByte();
    }

    pub const Commands = struct {
        pub fn echo(self: *Self, parser: *ushell.Parser) !void {
            while (parser.next()) |token| {
                std.debug.print("{s} ", .{token});
            }
            std.debug.print("\n", .{});

            self.stop_running = true;
        }
    };
});

pub fn main() !void {
    var shell = Shell.new(.{
        .reader = std.io.getStdIn().reader().any(),
    });

    while (!shell.inner.stop_running) {
        std.debug.print("$ ", .{});

        const line = try shell.readline();
        shell.handle(line) catch unreachable;
    }
}