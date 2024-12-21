const std = @import("std");

const ushell = @import("ushell");

const reader = std.io.getStdIn().reader().any();
const writer = std.io.getStdOut().writer().any();

const Commands = union(enum) {
    echo: struct {
        pub fn handle(_: *const @This(), parser: *ushell.Parser) !void {
            while (parser.next()) |val| {
                try std.fmt.format(writer, "{s} ", .{val});
            }
        }
    },

    number: struct {
        foo: u8,
        bar: bool,

        pub fn handle(self: *const @This(), _: *ushell.Parser) !void {
            try std.fmt.format(writer, "Received: {d} {}", .{ self.foo, self.bar });
        }
    },

    pub fn handle(self: *Commands, parser: *ushell.Parser) !void {
        switch (self.*) {
            .echo => {},
            else => if (parser.tokensLeft()) {
                return error.TooManyArgs;
            },
        }

        return switch (self.*) {
            inline else => |child| child.handle(parser),
        };
    }
};

const Shell = ushell.Shell(Commands, .{});

pub fn main() !void {
    var shell = Shell.new(reader, writer);

    while (!shell.stop_running) {
        shell.showPrompt();

        // do not break loop because of errors
        const line = shell.readline() catch continue;

        shell.handle(line) catch continue;
    }
}
