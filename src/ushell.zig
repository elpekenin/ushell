//! Utilities to make a shell-like interface.

const std = @import("std");
const Type = std.builtin.Type;

const history = @import("history.zig");
const usage = @import("usage.zig");
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

/// merge types(unions) into a single one
fn MakeCommand(UserCommand: type, BuiltinCommand: type) type {
    const U = @typeInfo(UserCommand).@"union";
    const B = @typeInfo(BuiltinCommand).@"union";

    const UT = @typeInfo(U.tag_type.?).@"enum";
    const BT = @typeInfo(B.tag_type.?).@"enum";

    var n: usize = 0;
    var enum_fields: [UT.fields.len + BT.fields.len]Type.EnumField = undefined;

    for (BT.fields) |field| {
        var copy = field;
        copy.value = n;
        enum_fields[n] = copy;
        n += 1;
    }
    for (UT.fields) |field| {
        var copy = field;
        copy.value = n;
        enum_fields[n] = copy;
        n += 1;
    }

    // WARNING: this will fail if UserCommand contains any name already defined in BuiltinCommand
    const CommandInfo: Type = .{
        .@"union" = .{
            .layout = .auto,
            .tag_type = @Type(.{
                .@"enum" = .{
                    .tag_type = u8, // FIXME
                    .fields = enum_fields[0..n],
                    .decls = &.{},
                    .is_exhaustive = true,
                },
            }),
            .fields = B.fields ++ U.fields,
            .decls = &.{},
        },
    };

    return @Type(CommandInfo);
}

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

        input: Reader,
        writer: std.io.AnyWriter,

        parser: Parser,
        buffer: std.BoundedArray(u8, options.max_line_size),
        history: History,

        stop_running: bool,
        last_output: Output,

        const BuiltinCommand = union(enum) {
            @"!": struct {
                pub const description = "re-run n'th command in history";

                i: usize,

                const Error = Parser.ArgError || error{ LineNotFound, UserCommandError };
                pub fn handle(self: @This(), shell: *Shell) Error!void {
                    // remove "! <n>" from history
                    // the command being referenced will be put in history (which makes more sense)
                    _ = shell.history.pop();

                    const line = try shell.history.getLine(self.i);
                    return shell.run(line) catch return error.UserCommandError;
                }
            },

            @"$?": struct {
                pub const description = "show last command's exitcode";

                pub fn handle(_: @This(), shell: *Shell) !void {
                    switch (shell.last_output) {
                        .ok => shell.print("0", .{}),
                        .err => |e| shell.print("1 ({})", .{e}),
                    }
                }
            },

            clear: struct {
                pub const description = "wipe the screen";

                pub fn handle(_: @This(), shell: *Shell) !void {
                    shell.print("{s}", .{Escape.Clear});
                }
            },

            exit: struct {
                pub const description = "quit shell session";

                pub fn handle(_: @This(), shell: *Shell) !void {
                    shell.stop_running = true;
                }
            },

            help: struct {
                pub const usage =
                    \\usage:
                    \\  help -- list available commands
                    \\  help <command> -- show usage of <command>
                ;

                name: ?[]const u8 = null,

                pub fn handle(self: @This(), shell: *Shell) !void {
                    shell.help(self.name);
                }

                pub fn tab(shell: *Shell) !void {
                    const maybe_input = shell.parser.next();
                    if (maybe_input != null) {
                        try shell.parser.assertExhausted();
                    }

                    const needle = maybe_input orelse "";

                    const matches = utils.findMatches(command_names, needle);
                    shell.complete(needle, matches);
                }
            },

            history: struct {
                pub const description = "show last commands used";

                pub fn handle(_: @This(), shell: *Shell) !void {
                    const n = shell.history.len() - 1;
                    const offset = shell.history.offset;

                    for (offset..offset + n) |i| {
                        const line = shell.history.getLine(i) catch unreachable;
                        shell.print("{d: >3}: {s}\n", .{ i, line });
                    }

                    const i = offset + n;
                    const line = shell.history.getLine(i) catch unreachable;
                    shell.print("{d: >3}: {s}", .{ i, line });
                }
            },
        };

        const Command = MakeCommand(UserCommand, BuiltinCommand);
        const CommandInfo = struct {
            // TODO?: *const fn handle(...)
            tab: *const fn (*Shell) anyerror!void,
            usage: []const u8,
        };
        fn noop_tab(_: *Shell) !void {}

        const Map = std.StaticStringMap(CommandInfo);

        const command_map = blk: {
            const C = @typeInfo(Command).@"union";

            var n: usize = 0;
            var kvs: [C.fields.len]struct { []const u8, CommandInfo } = undefined;

            for (C.fields) |field| {
                const T = field.type;

                kvs[n] = .{ field.name, CommandInfo{
                    .tab = if (@hasDecl(T, "tab")) T.tab else noop_tab,
                    .usage = usage.from(T, field.name),
                } };

                n += 1;
            }

            break :blk Map.initComptime(kvs[0..n]);
        };

        const command_names = command_map.keys();

        const Help = struct {
            fn forCommand(shell: *Shell, name: []const u8) void {
                const command = command_map.get(name) orelse return;
                shell.print("{s}", .{command.usage});
            }

            fn list(shell: *Shell) void {
                const commands = utils.findMatches(command_names, "");

                shell.print("Available commands:", .{});
                for (commands) |name| {
                    shell.print("\n  * {s}", .{name});
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

            const matches = utils.findMatches(command_names, needle);
            if (matches.len == 0) return;

            // handle command-specific completion
            if (command_map.get(needle)) |command| {
                return command.tab(shell) catch {};
            }

            shell.complete(needle, matches);
        }

        fn run(shell: *Shell, line: []const u8) !void {
            errdefer |e| shell.last_output = .{ .err = e };

            shell.parser = Parser.new(line);

            // nothing to do if user simply pressed enter
            if (!shell.parser.tokensLeft()) {
                return;
            }

            shell.history.append(line);

            // FIXME: `catch |err|` + `return err` doesn't work (??)
            const command = shell.parser.required(Command) catch {
                // couldn't parse, lets try and get command info from its name
                const name = shell.parser.first() orelse unreachable;
                shell.help(name);
                return error.InvalidArg;
            };

            switch (command) {
                inline else => |cmd| {
                    const Cmd = @TypeOf(cmd);

                    errdefer shell.help(shell.parser.first());

                    if (!@hasDecl(Cmd, "allow_extra_args") or !Cmd.allow_extra_args) {
                        try shell.parser.assertExhausted();
                    }

                    return cmd.handle(shell);
                },
            }

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

            const command = command_map.get(name) orelse {
                return shell.print("unknown command: {s}", .{name});
            };

            shell.print("{s}", .{command.usage});
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
