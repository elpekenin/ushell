const ushell = @import("../ushell.zig");
const Escape = ushell.Escape;
const Parser = ushell.Parser;

const utils = @import("../utils.zig");

pub const BuiltinCommand = enum {
    const Self = @This();

    @"!",
    clear,
    help,
    history,
    exit,

    /// Shell.handle and BuiltinCommand.handle can call each other, retuning error
    /// here would confuse zig's logic to infer error type.
    /// 
    /// shell is of type ushell.Shell(UserCommand, options) but it is marked as anytype
    /// because we dont want to pollute BuiltinCommand with user-level configuration
    pub fn handle(self: *Self, shell: anytype, parser: *Parser) void {
        switch (self.*) {
            .@"!" => {
                const i = parser.required(usize) catch return;

                // remove "! <n>" from history
                // the command being referenced will be put in history (which makes more sense)
                _ = shell.history.pop();

                // cant access elements past the current size
                if (i >= shell.history.len()) return;

                const line = shell.history.getLine(i);
                shell.handle(line) catch return;
            },
            .clear => shell.print("{s}", .{Escape.Clear}),
            .exit => shell.stop_running = true,
            .help => {
                const Shell = @TypeOf(shell.*);

                if (parser.next()) |name| {
                    parser.assertExhausted() catch return;
                    Shell.Help.of(shell, name);
                } else {
                    Shell.Help.list(shell);
                }
            },
            .history => {
                const n = shell.history.len() - 1;

                for (0..n) |i| {
                    const line = shell.history.getLine(i);
                    shell.print("{}: {s}\n", .{ i, line });
                }

                const line = shell.history.getLine(n);
                shell.print("{}: {s}", .{ n, line });
            },
        }
    }
};
