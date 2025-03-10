const std = @import("std");

const ushell = @import("ushell");

const Commands = union(enum) {
    echo: struct {
        pub const meta: ushell.Meta = .{
            .usage = "usage: echo ...args",
        };

        args: ushell.RemainingTokens,

        pub fn handle(self: ushell.Args(@This()), shell: *Shell) void {
            for (self.args) |token| {
                shell.print("{s} ", .{token});
            }
        }
    },

    foo: struct {
        bar: u8,
        baz: bool,

        // can be written in any order in the input
        opt_flag: ushell.OptionalFlag,
        t_flag: ushell.TrueFlag,
        f_flag: ushell.FalseFlag,

        pub fn handle(self: ushell.Args(@This()), shell: *Shell) void {
            shell.applyStyle(.{ .foreground = .Red });
            shell.print("Received: {any}", .{self});
            shell.applyStyle(.{ .foreground = .Default });
        }
    },
};

const Shell = ushell.MakeShell(Commands, .{
    .parser_options = .{
        .max_tokens = 100,
    },
});

pub fn main() !void {
    const reader = std.io.getStdIn().reader().any();
    const writer = std.io.getStdOut().writer().any();

    var shell = Shell.new(reader, writer);
    shell.loop();
}
