const ushell = @import("ushell.zig");
const Escape = ushell.Escape;
const Parser = ushell.Parser;

const Error = Parser.ArgError || error{UserCommandError};

pub const BuiltinCommand = enum {
    const Self = @This();

    @"!",
    @"$?",
    clear,
    help,
    history,
    exit,

    // NOTE: shell is always of type `ushell.Shell(UserCommand, options)`. however it is marked as anytype
    // because we dont want to pollute `BuiltinCommand` with user-level configuration
    pub fn handle(self: *Self, shell: anytype, parser: *Parser) Error!void {
        switch (self.*) {
            .@"!" => {
                const i = try parser.required(usize);
                try parser.assertExhausted();

                // remove "! <n>" from history
                // the command being referenced will be put in history (which makes more sense)
                _ = shell.history.pop();

                // cant access elements past the current size
                if (i >= shell.history.len()) return;

                const line = shell.history.getLine(i);
                return shell.handle(line) catch return error.UserCommandError;
            },
            .@"$?" => {
                // print (instead of return) the exitcode
                switch (shell.last_output) {
                    .ok => shell.print("0", .{}),
                    .err => |e| shell.print("1 ({})", .{e}),
                }
            },
            .clear => {
                try parser.assertExhausted();
                shell.print("{s}", .{Escape.Clear});
            },
            .exit => {
                try parser.assertExhausted();
                shell.stop_running = true;
            },
            .help => {
                if (parser.next()) |name| {
                    try parser.assertExhausted();
                    shell.helpFor(name);
                } else {
                    shell.listCommands();
                }
            },
            .history => {
                try parser.assertExhausted();

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

    pub fn usage(self: *const Self) []const u8 {
        return switch (self.*) {
            .@"!" => "usage: `! <n>` -- re-run n'th command in history",
            .@"$?" => "usage: `$?` -- show last command's status",
            .clear => "usage: `clear` -- wipe the screen",
            .help =>
            \\usage:
            \\  `help` -- list available commands
            \\  `help <command>` -- show usage of a specific command
            ,
            .history => "usage: `history` -- list last commands used",
            .exit => "usage: `exit` -- quits shell session",
        };
    }
};
