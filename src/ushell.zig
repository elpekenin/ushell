//! Utilities to make a shell-like interface.

const std = @import("std");
const control = std.ascii.control_code;
const Type = std.builtin.Type;

const ansi = @import("ansi-term");

const history = @import("history.zig");
const internal = @import("internal.zig");
const usage = @import("usage.zig");

/// dont want to expose everything in here
/// lets re-expose some of them, and with shorter paths
const argparse = @import("argparse.zig");
pub const parseToken = argparse.parseToken;
pub const Meta = argparse.Meta;
pub const Args = argparse.Args;
pub const OptionalFlag = argparse.OptionalFlag;
pub const TrueFlag = argparse.TrueFlag;
pub const FalseFlag = argparse.FalseFlag;
pub const RemainingTokens = argparse.RemainingTokens;

pub const utils = @import("utils.zig");
pub const Reader = @import("Reader.zig");

const Output = union(enum) {
    ok,
    err: anyerror,
};

/// merge types(unions) into a single one
fn MakeCommand(comptime User: type, comptime Builtin: type) type {
    const U = @typeInfo(User).@"union";
    const B = @typeInfo(Builtin).@"union";

    const user_tag_fields = internal.enumFields(U.tag_type.?);
    const builtin_tag_fields = internal.enumFields(B.tag_type.?);

    var n: usize = 0;
    var enum_fields: [user_tag_fields.len + builtin_tag_fields.len]Type.EnumField = undefined;

    for (builtin_tag_fields) |field| {
        var copy = field;
        copy.value = n;
        enum_fields[n] = copy;
        n += 1;
    }
    for (user_tag_fields) |field| {
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

    if (I != .@"union") internal.err("Commands must be represented with a `union(enum)`");
    if (options.max_line_size == 0 or options.max_history_size == 0) internal.err("Buffer can't be 0-sized");
}

pub const Options = struct {
    /// shown at the start of each line, when prompting user for input
    prompt: []const u8 = "$ ",

    /// buffer size for user input
    max_line_size: usize = 200,

    /// buffer size for `history` and `! <n>` builtins
    max_history_size: usize = 10,

    /// used to disable colors (ANSII escape sequences)
    use_color: bool = true,

    /// whether to write input back to user
    /// useful if the sending party is **not** printing the sent text
    echo_input: bool = false,

    /// configuration passed to `argparse.ArgumentParser`
    parser_options: argparse.Options,
};

/// A shell's type is defined by a `union(enum)` of different commands and some optional arguments.
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

        buffer: std.BoundedArray(u8, options.max_line_size),
        history: History,

        stop_running: bool,
        last_output: Output,

        const BuiltinCommand = union(enum) {
            @"!": struct {
                pub const meta: argparse.Meta = .{
                    .description = "re-run n'th command in history",
                };

                i: usize,

                const Error = error{ LineNotFound, UserCommandError };
                pub fn handle(self: @This(), shell: *Shell) Error!void {
                    // remove "! <n>" from history
                    // the command being referenced will be put in history (which makes more sense)
                    _ = shell.history.pop();

                    const line = try shell.history.getLine(self.i);
                    return shell.run(line) catch return error.UserCommandError;
                }
            },

            @"$?": struct {
                pub const meta: argparse.Meta = .{
                    .description = "show last command's exitcode",
                };

                pub fn handle(_: @This(), shell: *Shell) void {
                    switch (shell.last_output) {
                        .ok => shell.print("0", .{}),
                        .err => |e| shell.print("1 ({})", .{e}),
                    }
                }
            },

            clear: struct {
                pub const meta: argparse.Meta = .{
                    .description = "wipe the screen",
                };

                pub fn handle(_: @This(), shell: *Shell) void {
                    // TODO?: propagate error
                    ansi.clear.clearScreen(shell.writer) catch {};
                }
            },

            exit: struct {
                pub const meta: argparse.Meta = .{
                    .description = "quit shell session",
                };

                pub fn handle(_: @This(), shell: *Shell) void {
                    shell.stop_running = true;
                }
            },

            help: struct {
                pub const meta: argparse.Meta = .{
                    .usage =
                    \\usage: help [command]
                    \\
                    \\list available commands
                    \\
                    \\
                    \\arguments:
                    \\  command    show usage of a specific command instead
                    ,
                };

                name: ?[]const u8 = null,

                pub fn handle(self: @This(), shell: *Shell) void {
                    if (self.name) |name| {
                        const command = command_info.get(name) orelse return shell.unknown(name);
                        shell.print("{s}", .{command.usage});
                    } else {
                        const commands = utils.findMatches(command_names, "");

                        shell.print("Available commands:", .{});
                        for (commands) |name| {
                            shell.print("\n  * {s}", .{name});
                        }
                    }
                }

                pub fn tab(shell: *Shell, tokens: []const []const u8) !void {
                    if (tokens.len != 2) return;
                    const needle = tokens[1];

                    const matches = utils.findMatches(command_names, needle);
                    shell.complete(needle, matches);
                }
            },

            history: struct {
                pub const meta: argparse.Meta = .{
                    .description = "show last commands used",
                };

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
        const CommandParser = argparse.ArgumentParser(Command, options.parser_options);

        const Info = struct {
            handle: *const fn (*const anyopaque, *Shell) anyerror!void,
            tab: *const fn (*Shell, tokens: []const []const u8) anyerror!void,
            usage: []const u8,
        };
        fn noop_tab(_: *Shell, _: []const []const u8) !void {}

        const Map = std.StaticStringMap(Info);

        const command_info = blk: {
            const fields = internal.unionFields(Command);

            var n: usize = 0;
            var kvs: [fields.len]struct { []const u8, Info } = undefined;

            for (fields) |field| {
                const Cmd = field.type;

                const meta: argparse.Meta = if (@hasDecl(Cmd, "meta")) Cmd.meta else .{};

                kvs[n] = .{
                    field.name, Info{
                        .handle = struct {
                            fn impl(args: *const anyopaque, shell: *Shell) !void {
                                const casted: *const argparse.Args(Cmd) = @ptrCast(@alignCast(args));
                                return Cmd.handle(casted.*, shell);
                            }
                        }.impl,
                        .tab = if (std.meta.hasFn(Cmd, "tab")) Cmd.tab else noop_tab,
                        .usage = usage.of(Cmd, meta, field.name),
                    },
                };

                n += 1;
            }

            break :blk Map.initComptime(kvs[0..n]);
        };

        const command_names = command_info.keys();

        pub fn new(
            reader: std.io.AnyReader,
            writer: std.io.AnyWriter,
        ) Shell {
            return Shell{
                .input = Reader.new(reader),
                .writer = writer,
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
                        if (options.echo_input) shell.print("{c}", .{byte});
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
            const input = shell.buffer.constSlice();

            var tokenizer: argparse.Tokenizer(options.parser_options) = .new();
            const tokens = tokenizer.getTokens(input);

            if (tokens.len == 0) return;
            const name = tokens[0];

            // handle command-specific completion
            if (command_info.get(name)) |command| {
                return command.tab(shell, tokens) catch {
                    // TODO: log or something?
                };
            }

            const matches = utils.findMatches(command_names, name);
            shell.complete(name, matches);
        }

        fn run(shell: *Shell, line: []const u8) !void {
            errdefer |e| shell.last_output = .{ .err = e };

            shell.history.append(line);

            const result = CommandParser.parse(line);
            const command = switch (result) {
                .ok => |command| command,
                .empty_input => {
                    _ = shell.history.pop(); // remove empty line from history
                    return;
                },
                .parsing_error => |info| {
                    shell.applyStyle(.{ .foreground = .Red });
                    shell.print("Error parsing input ({s})", .{@errorName(info.err)});

                    shell.applyStyle(.{ .foreground = .Green });
                    shell.print("\nHint: run `help {s}` to see command's usage", .{info.name});

                    shell.applyStyle(.{ .foreground = .Default });
                    return @as(anyerror!void, info.err); // FIXME: why?
                },
                .unknown_command => |name| {
                    shell.applyStyle(.{ .foreground = .Red });
                    shell.unknown(name);
                    shell.applyStyle(.{ .foreground = .Default });

                    return error.UnknownCommand;
                },
            };

            errdefer |err| {
                shell.applyStyle(.{ .foreground = .Red });
                shell.print("Command failed ({s})", .{@errorName(err)});

                shell.applyStyle(.{ .foreground = .Green });
                shell.print("\nHint: run `help {s}` to see its usage", .{command.name});

                shell.applyStyle(.{ .foreground = .Default });
            }

            const info = command_info.get(command.name) orelse unreachable;
            const ret = try info.handle(&command.args, shell);

            shell.last_output = .ok;
            return ret;
        }

        pub fn loop(shell: *Shell) void {
            while (!shell.stop_running) {
                shell.prompt();
                const line = shell.readline() catch continue;
                shell.run(line) catch continue;
            }
        }

        fn unknown(shell: *Shell, name: []const u8) void {
            shell.print("unknown command: {s}", .{name});
        }

        fn popOne(shell: *Shell) void {
            // TODO: make this stuff configurable with options as it relies on host-app implementation details

            // send backspace, to delete previous char
            //
            // however this might only move cursor on host and not actually remove the glyph from screen (pyOCD behavior).
            // to handle that, we also send a whitespace to overwrite it
            //
            // then, print another backspace to get cursor back to intended place
            shell.print("{c} {c}", .{ control.bs, control.bs });

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

        pub fn applyStyle(shell: *Shell, style: ansi.style.Style) void {
            if (!options.use_color) return;

            // TODO?: store state
            // TODO?: propagate error
            ansi.format.updateStyle(shell.writer, style, null) catch {};
        }
    };
}
