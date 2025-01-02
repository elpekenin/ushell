//! Utilities to make a shell-like interface.

const std = @import("std");
const Type = std.builtin.Type;

const history = @import("history.zig");
const Ascii = @import("Ascii.zig");

pub const utils = @import("utils.zig");
pub const Escape = @import("Escape.zig");
pub const Parser = @import("Parser.zig");
pub const Reader = @import("Reader.zig");

const Output = union(enum) {
    ok,
    err: anyerror,
};

pub const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    default,
    reset,
};

pub const Mode = enum {
    reset,
    bold,
    dim,
    italic,
    underline,
    blinking,
    inverse,
    hidden,
    strikethrough,
};

pub const TextStyle = struct {
    foreground: Color = .white,
    background: Color = .black,
    mode: Mode = .reset,
};

fn validate(T: type, options: Options) void {
    const I = @typeInfo(T);

    if (I != .@"union") {
        const msg = "Commands must be represented with a `union(enum)`";
        @compileError(msg);
    }

    if (options.max_line_size == 0 or options.max_history_size == 0) {
        const msg = "Buffers can't be 0-sized";
        @compileError(msg);
    }
}

pub const Options = struct {
    prompt: []const u8 = "$ ",
    max_line_size: usize = 200,
    max_history_size: usize = 10,
    use_color: bool = true,
};

/// A shell's type is defined by a `union(enum)` of different commands and some optional arguments.
///
/// By default, extra arguments (more than strictly needed to fill the struct) will cause an error,
/// you can opt-out this behaviour by adding `pub const allow_extra_args = true;` to your struct.
///
/// You can also overwrite the default `usage: ...` message by defining your own message to be shown,
/// with `pub const usage = "my command should be used as: hello <world>";`
///
/// At runtime, an instance of this type is created by calling `Shell.new` with a reader and writer.
///
/// See `examples/echo.zig` for a small demo.
pub fn MakeShell(UserCommand: type, options: Options) type {
    validate(UserCommand, options);

    const History = history.History(options);

    return struct {
        const Shell = @This();

        const B = @typeInfo(BuiltinCommand).@"enum";
        const U = @typeInfo(UserCommand).@"union";

        input: Reader,
        writer: std.io.AnyWriter,

        parser: Parser,
        buffer: std.BoundedArray(u8, options.max_line_size),
        history: History,

        stop_running: bool,
        last_output: Output,

        const BuiltinCommand = enum {
            @"!",
            @"$?",
            clear,
            exit,
            help,
            history,

            const Error = Parser.ArgError || error{ LineNotFound, UserCommandError };
            fn handle(builtin: BuiltinCommand, shell: *Shell) Error!void {
                switch (builtin) {
                    .@"!" => {
                        const i = try shell.parser.required(usize);
                        try shell.parser.assertExhausted();

                        // remove "! <n>" from history
                        // the command being referenced will be put in history (which makes more sense)
                        _ = shell.history.pop();

                        const line = try shell.history.getLine(i);
                        return shell.run(line) catch return error.UserCommandError;
                    },
                    .@"$?" => {
                        // print (instead of return) the exitcode
                        switch (shell.last_output) {
                            .ok => shell.print("0", .{}),
                            .err => |e| shell.print("1 ({})", .{e}),
                        }
                    },
                    .clear => {
                        try shell.parser.assertExhausted();
                        shell.print("{s}", .{Escape.Clear});
                    },
                    .exit => {
                        try shell.parser.assertExhausted();
                        shell.stop_running = true;
                    },
                    .help => {
                        const name = shell.parser.next();
                        if (name != null) try shell.parser.assertExhausted();
                        shell.help(name);
                    },
                    .history => {
                        try shell.parser.assertExhausted();

                        const n = shell.history.len() - 1;
                        const offset = shell.history.offset;

                        for (offset..offset + n) |i| {
                            const line = shell.history.getLine(i) catch unreachable;
                            shell.print("{d: >3}: {s}\n", .{ i, line });
                        }

                        const i = offset + n;
                        const line = shell.history.getLine(i) catch unreachable;
                        shell.print("{d: >3}: {s}", .{ i, line });
                    },
                }
            }

            fn usage(builtin: BuiltinCommand) []const u8 {
                return switch (builtin) {
                    .@"!" => "usage: `! <n>` -- re-run n'th command in history",
                    .@"$?" => "usage: `$?` -- show last command's status",
                    .clear => "usage: `clear` -- wipe the screen",
                    .exit => "usage: `exit` -- quits shell session",
                    .help =>
                    \\usage:
                    \\  `help` -- list available commands
                    \\  `help <command>` -- show usage of a specific command
                    ,
                    .history => "usage: `history` -- list last commands used",
                };
            }

            fn tab(builtin: BuiltinCommand, shell: *Shell) void {
                switch (builtin) {
                    .@"!",
                    .@"$?",
                    .clear,
                    .exit,
                    .history,
                    => {},

                    .help => {
                        const maybe_input = shell.parser.next();
                        if (maybe_input != null) shell.parser.assertExhausted() catch return;
                        const needle = maybe_input orelse "";

                        switch (Find.commands(needle)) {
                            .none => {},
                            .builtin => |name| {
                                shell.applyCompletion(needle, name);
                            },
                            .user => |name| {
                                shell.applyCompletion(needle, name);
                            },
                            .multiple => |matches| shell.complete(needle, matches),
                        }
                    },
                }
            }
        };

        const Find = struct {
            fn builtin(shell: *Shell) !BuiltinCommand {
                return shell.parser.required(BuiltinCommand);
            }

            fn user(shell: *Shell) !?UserCommand {
                return shell.parser.required(UserCommand) catch |err| {
                    // name did not exist in UserCommand, will try and find into BuiltinCommand later
                    if (shell.parser.successful_parses == 0 and err == error.InvalidArg) {
                        return null;
                    }

                    return err;
                };
            }

            const Matches = union(enum) { none, builtin: []const u8, user: []const u8, multiple: [][]const u8 };

            inline fn commands(needle: []const u8) Matches {
                const builtin_commands = B.fields;
                const b = utils.findMatches(builtin_commands, needle);

                const user_commands = U.fields;
                const u = utils.findMatches(user_commands, needle);

                if (b.len == 0 and u.len == 0) {
                    return Matches{ .none = {} };
                }

                if (b.len == 1 and u.len == 0) {
                    return Matches{ .builtin = b[0] };
                }

                if (b.len == 0 and u.len == 1) {
                    return Matches{ .user = u[0] };
                }

                var n: usize = 0;
                var buffer: [builtin_commands.len + user_commands.len][]const u8 = undefined;

                for (b) |name| {
                    buffer[n] = name;
                    n += 1;
                }
                for (u) |name| {
                    buffer[n] = name;
                    n += 1;
                }

                return Matches{
                    .multiple = buffer[0..n],
                };
            }
        };

        const Help = struct {
            fn forSubcommand(shell: *Shell, name: []const u8, Inner: type) void {
                if (@hasDecl(Inner, "usage")) {
                    shell.print("{s}", .{Inner.usage});
                } else {
                    // default implementation: introspection of arguments
                    shell.print("usage: {s} ", .{name});
                    Usage.ofType(shell, Inner);

                    if (@hasDecl(Inner, "description")) {
                        shell.print("-- {s}", .{Inner.description});
                    }
                }
            }

            fn list(shell: *Shell) void {
                const commands = Find.commands("");

                shell.print("Available commands:", .{});
                for (commands.multiple) |name| {
                    shell.print("\n  * {s}", .{name});
                }
            }
        };

        const Run = struct {
            fn user(shell: *Shell, command: UserCommand) !void {
                errdefer shell.help(@tagName(command));

                switch (command) {
                    inline else => |cmd| {
                        const Cmd = @TypeOf(cmd);

                        if (!@hasDecl(Cmd, "allow_extra_args") or !Cmd.allow_extra_args) {
                            try shell.parser.assertExhausted();
                        }
                    },
                }

                return switch (command) {
                    inline else => |cmd| cmd.handle(shell),
                };
            }

            fn builtin(shell: *Shell, command: BuiltinCommand) !void {
                errdefer shell.print("{s}", .{command.usage()});
                return command.handle(shell);
            }

            fn run(shell: *Shell, line: []const u8) !void {
                shell.parser = Parser.new(line);

                // nothing to do if user simply pressed enter
                if (!shell.parser.tokensLeft()) {
                    return;
                }

                shell.history.append(line);

                const user_command: ?UserCommand = Find.user(shell) catch |err| {
                    shell.help(shell.parser.first());
                    return err;
                };
                if (user_command) |command| {
                    return Run.user(shell, command);
                }

                shell.parser.reset();
                const builtin_command = Find.builtin(shell) catch |err| {
                    shell.unknown(shell.parser.first().?);
                    return err;
                };
                return Run.builtin(shell, builtin_command);
            }
        };

        const Usage = struct {
            fn defaultValue(shell: *Shell, field: Type.StructField) void {
                if (field.default_value) |def| {
                    shell.print("=", .{});

                    const T = field.type;

                    const ptr: *align(field.alignment) const T = @alignCast(@ptrCast(def));
                    const val = ptr.*;

                    const I = @typeInfo(field.type);
                    switch (T) {
                        []const u8 => shell.print("{s}", .{val}),
                        ?[]const u8 => shell.print("{?s}", .{val}),
                        else => switch (I) {
                            // eg: show "=foo" instead of "=main.EnumName.foo" (not even valid input for parser)
                            .@"enum" => shell.print("{s}", .{@tagName(val)}),
                            .optional => shell.print("{?}", .{val}),
                            else => shell.print("{}", .{val}),
                        },
                    }
                }
            }

            fn ofEnum(shell: *Shell, e: Type.Enum) void {
                const fields = e.fields;

                shell.print("{{", .{});
                inline for (fields[0 .. fields.len - 1]) |field| {
                    shell.print("{s},", .{field.name});
                }
                shell.print("{s}}}", .{fields[fields.len - 1].name});
            }

            fn ofStruct(shell: *Shell, s: Type.Struct) void {
                inline for (s.fields) |field| {
                    shell.print("{s}(", .{field.name});
                    Usage.ofType(shell, field.type);
                    shell.print(")", .{});
                    Usage.defaultValue(shell, field);
                    shell.print(" ", .{});
                }
            }

            fn ofUnion(shell: *Shell, u: Type.Union) void {
                const fields = u.fields;

                shell.print("{{", .{});
                inline for (fields[0 .. fields.len - 1]) |field| {
                    shell.print("{s}(", .{field.name});
                    Usage.ofType(shell, field.type);
                    shell.print("),");
                }
                shell.print("{s}(", .{fields[fields.len - 1].name});
                Usage.ofType(shell, fields[fields.len - 1].type);
                shell.print(")}}", .{});
            }

            fn ofType(shell: *Shell, T: type) void {
                const I = @typeInfo(T);

                switch (T) {
                    // TODO?: show string literals that cast to bool values
                    bool => shell.print("bool", .{}),
                    []const u8 => shell.print("string", .{}),
                    ?[]const u8 => shell.print("optional string", .{}),
                    else => switch (I) {
                        .int,
                        .float,
                        => shell.print("{s}", .{@typeName(T)}),
                        .@"enum" => |e| Usage.ofEnum(shell, e),
                        .@"struct" => |s| Usage.ofStruct(shell, s),
                        .@"union" => |u| Usage.ofUnion(shell, u),
                        else => {
                            const msg = "Showing usage for arguments of type '" ++ @typeName(T) ++ "' not supported at the moment.";
                            @compileError(msg);
                        },
                    },
                }
            }
        };

        pub fn new(
            reader: std.io.AnyReader,
            writer: std.io.AnyWriter,
        ) Shell {
            return Shell{
                .input = Reader.new(reader),
                .writer = writer,
                .parser = undefined,
                .buffer = .{},
                .history = History.new(),
                .stop_running = false,
                .last_output = .ok,
            };
        }

        // TODO: non-blocking API
        fn readline(shell: *Shell) ![]const u8 {
            shell.buffer.clear();

            while (true) {
                const token = try shell.input.next();

                switch (token) {
                    // delete previous char (if any)
                    .backspace => shell.popOne(),
                    .tab => shell.tab(),
                    // line ready, stop reading
                    .newline => break,
                    .arrow => {}, // TODO
                    .char => |byte| {
                        shell.buffer.append(byte) catch std.debug.panic("Exhausted reception buffer", .{});
                    },
                }
            }

            return shell.buffer.constSlice();
        }

        pub fn print(shell: *Shell, comptime fmt: []const u8, args: anytype) void {
            std.fmt.format(shell.writer, fmt, args) catch unreachable;
        }

        pub fn prompt(shell: *Shell) void {
            shell.print("\n{s}", .{options.prompt});
        }

        fn unknown(shell: *Shell, name: []const u8) void {
            shell.print("unknown command: {s}", .{name});
        }

        pub fn applyCompletion(shell: *Shell, needle: []const u8, final: []const u8) void {
            if (needle.len == final.len) return;

            const space = std.mem.containsAtLeast(u8, final, 1, " ");
            if (space) {
                shell.pop(needle.len);
                shell.append("'");
                shell.append(final);
                shell.append("'");
            } else {
                const diff = final[needle.len..final.len];
                shell.append(diff);
            }
        }

        pub fn complete(shell: *Shell, needle: []const u8, matches: [][]const u8) void {
            switch (matches.len) {
                0 => {},
                1 => shell.applyCompletion(needle, matches[0]),
                else => {
                    shell.print("\n", .{});
                    for (matches) |match| {
                        shell.print("{s} ", .{match});
                    }
                    shell.prompt();
                    shell.print("{s}", .{shell.buffer.constSlice()});
                },
            }
        }

        fn tab(shell: *Shell) void {
            shell.parser = Parser.new(shell.buffer.constSlice());
            const needle = shell.parser.next() orelse "";

            switch (Find.commands(needle)) {
                .none => {},
                .builtin => |name| {
                    if (needle.len == name.len) {
                        // name is completely written, apply command's tab
                        const b = shell.parser.parseToken(BuiltinCommand, name) catch unreachable;
                        b.tab(shell);
                    } else {
                        shell.applyCompletion(needle, name);
                    }
                },
                .user => |name| {
                    if (needle.len == name.len) {
                        // name is completely written, apply command's tab
                        inline for (U.fields) |field| {
                            if (std.mem.eql(u8, name, field.name)) {
                                const Cmd = field.type;

                                if (@hasDecl(Cmd, "tab")) {
                                    Cmd.tab(shell) catch {};
                                }
                            }
                        }
                    } else {
                        shell.applyCompletion(needle, name);
                    }
                },
                .multiple => |matches| shell.complete(needle, matches),
            }
        }

        fn run(shell: *Shell, line: []const u8) !void {
            Run.run(shell, line) catch |err| {
                shell.last_output = .{ .err = err };
                return err;
            };

            shell.last_output = .ok;
        }

        pub fn loop(shell: *Shell) void {
            while (!shell.stop_running) {
                shell.prompt();
                const line = shell.readline() catch continue;
                shell.run(line) catch continue;
            }
        }

        fn help(shell: *Shell, maybe_name: ?[]const u8) void {
            // NOTE: Not using the parser here so that we can identify commands from partial input
            //
            // This is, if we have a `foo: struct { n: u32 }` command and we receive an input of "foo",
            // we can't fully parse the type (`n` is missing), but we can identify the type that
            // it uses internally (the anonymous struct with a u32 field), and show the usage
            // based on this knowledge

            const name = maybe_name orelse return Help.list(shell);

            // TODO: Use `Find` for this, reducing code duplication

            inline for (U.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    Help.forSubcommand(shell, field.name, field.type);
                    return;
                }
            }

            const builtin = shell.parser.parseToken(BuiltinCommand, name) catch {
                return shell.unknown(name);
            };

            shell.print("{s}", .{builtin.usage()});
        }

        fn popOne(shell: *Shell) void {
            // TODO: make this stuff configurable with options as it relies on host-app implementation details

            // send backspace, to delete previous char
            //
            // however this might only move cursor on host and not actually remove the glyph from screen (pyOCD behavior).
            // to handle that, we also send a whitespace to overwrite it
            //
            // then, print another backspace to get cursor back to intended place
            shell.print("{c} {c}", .{ Ascii.Backspace, Ascii.Backspace });

            // nothing on buffer -> user deletes last char of prompt from screen -> write it back
            if (shell.buffer.popOrNull() == null) {
                shell.print("{c}", .{options.prompt[options.prompt.len - 1]});
            }
        }

        pub fn pop(shell: *Shell, n: usize) void {
            for (0..n) |_| shell.popOne();
        }

        pub fn append(shell: *Shell, slice: []const u8) void {
            shell.buffer.appendSlice(slice) catch std.debug.panic("Exhausted reception buffer", .{});
            shell.print("{s}", .{slice});
        }

        pub fn style(_: *const Shell, s: TextStyle) []const u8 {
            if (!options.use_color) return "";
            return Escape.styleFor(s);
        }
    };
}
