//! Find the UserCommand or BuiltinCommand appropiate for the input received

const ushell = @import("../ushell.zig");

const utils = @import("../utils.zig");
const BuiltinCommand = utils.BuiltinCommand;

pub fn builtin(parser: *ushell.Parser) !BuiltinCommand {
    parser.reset();

    const builtin_command = try parser.required(BuiltinCommand);

    switch (builtin_command) {
        .clear,
        .exit,
        .history,
        => try parser.assertExhausted(),

        .@"!",
        .help,
        => {},
    }

    return builtin_command;
}

pub fn user(parser: *ushell.Parser, UserCommand: type) !?UserCommand {
    return parser.required(UserCommand) catch |err| {
        // name did not exist in UserCommand, will try and find into BuiltinCommand later
        if (parser.successful_parses == 0 and err == error.InvalidArg) {
            return null;
        }

        return err;
    };
}
