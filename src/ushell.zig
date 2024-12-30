//! Utilities to make a shell-like interface.

const std = @import("std");

const builtins = @import("builtins.zig");
const BuiltinCommand = builtins.BuiltinCommand;
const find = @import("find.zig");
const help = @import("help.zig");
const history = @import("history.zig");

pub const Escape = @import("Escape.zig");
pub const Parser = @import("Parser.zig");
pub const Reader = @import("Reader.zig");

const Output = union(enum) {
    ok,
    err: anyerror,
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
pub fn Shell(UserCommand: type, options: Options) type {
    validate(UserCommand, options);

    const History = history.History(options);

    return struct {
        const Self = @This();

        pub const Help = help.Help(UserCommand, options);

        input: Reader,
        writer: std.io.AnyWriter,

        parser: Parser,
        buffer: std.BoundedArray(u8, options.max_line_size),
        history: History,

        stop_running: bool,
        last_output: Output,

        pub fn new(
            reader: std.io.AnyReader,
            writer: std.io.AnyWriter,
        ) Self {
            return Self{
                .input = Reader.new(reader),
                .writer = writer,
                .parser = undefined,
                .buffer = .{},
                .history = History.new(),
                .stop_running = false,
                .last_output = .ok,
            };
        }

        pub fn readline(self: *Self) ![]const u8 {
            self.buffer.clear();

            while (true) {
                const token = try self.input.next();

                switch (token) {
                    // delete previous char (if any)
                    .backspace => _ = self.buffer.popOrNull(),
                    .tab => {}, // TODO
                    // line ready, stop reading
                    .newline => break,
                    .arrow => {}, // TODO
                    .char => |byte| {
                        self.buffer.append(byte) catch std.debug.panic("Exhausted reception buffer", .{});
                    },
                }
            }

            return self.buffer.constSlice();
        }

        pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
            std.fmt.format(self.writer, fmt, args) catch unreachable;
        }

        pub fn showPrompt(self: *Self) void {
            self.print("\n{s}", .{options.prompt});
        }

        pub fn unknown(self: *Self, name: []const u8) void {
            self.print("unknown command: {s}", .{name});
        }

        fn handleUser(self: *Self, command: *UserCommand) !void {
            errdefer Help.usage(self, @tagName(command.*));

            switch (command.*) {
                inline else => |cmd| {
                    const Cmd = @TypeOf(cmd);

                    if (!@hasDecl(Cmd, "allow_extra_args") or !Cmd.allow_extra_args) {
                        try self.parser.assertExhausted();
                    }
                },
            }

            return switch (command.*) {
                inline else => |cmd| cmd.handle(self),
            };
        }

        fn handleBuiltin(self: *Self, command: *BuiltinCommand) !void {
            errdefer self.print("{s}", .{command.usage()});
            return command.handle(self, &self.parser);
        }

        fn handleImpl(self: *Self, line: []const u8) !void {
            self.parser = Parser.new(line);

            // only append to history if there has been *some* input
            if (self.parser.tokensLeft()) {
                self.history.append(line);
                self.parser.reset();
            } else {
                return;
            }

            var user = find.user(&self.parser, UserCommand) catch |err| {
                self.parser.reset();
                const name = self.parser.next().?;
                Help.usage(self, name);
                return err;
            };
            if (user) |*command| {
                return self.handleUser(command);
            }

            var builtin = find.builtin(&self.parser) catch |err| {
                self.parser.reset();
                const name = self.parser.next().?;
                self.unknown(name);
                return err;
            };
            return self.handleBuiltin(&builtin);
        }

        pub fn handle(self: *Self, line: []const u8) !void {
            self.handleImpl(line) catch |err| {
                self.last_output = .{ .err = err };
                return err;
            };

            self.last_output = .ok;
        }

        pub fn run(self: *Self) void {
            while (!self.stop_running) {
                self.showPrompt();
                const line = self.readline() catch continue;
                self.handle(line) catch continue;
            }
        }
    };
}
