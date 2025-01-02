const std = @import("std");

const ushell = @import("ushell");

const reader = std.io.getStdIn().reader().any();
const writer = std.io.getStdOut().writer().any();

const Commands = union(enum) {
    echo: struct {
        pub const allow_extra_args = true;
        pub const usage = "usage: echo ...args";

        pub fn handle(_: @This(), shell: *Shell) void {
            while (shell.parser.next()) |val| {
                shell.print("{s} ", .{val});
            }
        }
    },

    number: struct {
        foo: u8,
        bar: bool,

        pub fn handle(self: @This(), shell: *Shell) void {
            shell.print("{s}Received: {d} {}{s}", .{
                shell.style(.{ .foreground = .red }),
                self.foo,
                self.bar,
                shell.style(.{ .foreground = .reset }),
            });
        }
    },
};

const Shell = ushell.MakeShell(Commands, .{});

pub fn main() !void {
    var shell = Shell.new(reader, writer);
    shell.loop();
}
