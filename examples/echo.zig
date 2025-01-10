const std = @import("std");

const ushell = @import("ushell");

const reader = std.io.getStdIn().reader().any();
const writer = std.io.getStdOut().writer().any();

const Commands = union(enum) {
    echo: struct {
        pub const meta: ushell.argparse.Meta = .{
            .usage = "usage: echo ...args",
        };

        args: ushell.argparse.TokensLeft = .{
            .n = 10,
        },


        pub fn handle(self: ushell.argparse.Args(@This()), shell: *Shell) void {
            for (self.args.toSlice()) |token| {
                shell.print("{s} ", .{token});
            }
        }
    },

    foo: struct {
        bar: u8,
        baz: bool,
        flag: ushell.argparse.OptionalFlag, // can be written in any place :)

        pub fn handle(self: ushell.argparse.Args(@This()), shell: *Shell) void {
            shell.print("{s}Received: bar={d} baz={} flag={?}{s}", .{
                shell.style(.red),
                self.bar,
                self.baz,
                self.flag,
                shell.style(.default),
            });
        }
    },
};

const Shell = ushell.MakeShell(Commands, .{});

pub fn main() !void {
    var shell = Shell.new(reader, writer);
    shell.loop();
}
