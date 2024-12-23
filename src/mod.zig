// TODO: Add argument parsing facilities (?)

const std = @import("std");
const Type = std.builtin.Type;

pub const Escape = @import("Escape.zig");
pub const Keys = @import("Keys.zig");
pub const Parser = @import("Parser.zig");

const BuiltinCommand = enum {
    @"!",
    clear,
    help,
    history,
    exit,
};

fn validate(T: type, options: ShellOptions) void {
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

pub const ShellOptions = struct {
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
pub fn Shell(UserCommand: type, options: ShellOptions) type {
    validate(UserCommand, options);

    return struct {
        const Self = @This();

        reader: std.io.AnyReader,
        writer: std.io.AnyWriter,
        buffer: std.BoundedArray(u8, options.max_line_size),
        history: std.BoundedArray([options.max_line_size]u8, options.max_history_size),

        stop_running: bool,

        pub fn new(
            reader: std.io.AnyReader,
            writer: std.io.AnyWriter,
        ) Self {
            return Self{
                .reader = reader,
                .writer = writer,
                .buffer = .{},
                .history = .{},
                .stop_running = false,
            };
        }

        fn readByte(self: *Self) !?u8 {
            return self.reader.readByte() catch |err| switch (err) {
                error.EndOfStream => return null, // nothing was read
                else => return err,
            };
        }

        fn appendHistory(self: *Self, line: []const u8) void {
            // if filled, remove an item
            if (self.history.len == self.history.capacity()) {
                _ = self.history.orderedRemove(0);
            }

            // should never fail, we check the size (and free a slot) above
            const ptr = self.history.addOne() catch unreachable;

            // "append" by copying the buffer (rather than storing a pointer to a temporary slice)
            for (0.., line) |i, byte| {
                ptr[i] = byte;
            }
        }

        pub fn readline(self: *Self) ![]const u8 {
            self.buffer.clear();

            while (true) {
                const byte = try self.readByte() orelse continue;

                switch (byte) {
                    // input ready, stop reading
                    Keys.Newline => break,
                    Keys.Tab => {},
                    Keys.Backspace => {
                        // backspace deletes previous char (if any)
                        _ = self.buffer.popOrNull();
                    },
                    else => {
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

        fn usageEnum(self: *Self, e: Type.Enum) void {
            const fields = e.fields;

            self.print("{{", .{});
            inline for (fields[0 .. fields.len - 1]) |field| {
                self.print("{s},", .{field.name});
            }
            self.print("{s}}}", .{fields[fields.len - 1].name});
        }

        fn defaultValue(self: *Self, field: Type.StructField) void {
            if (field.default_value) |def| {
                const ptr: *align(field.alignment) const field.type = @alignCast(@ptrCast(def));

                const I = @typeInfo(field.type);
                switch (I) {
                    // eg: show "=foo" instead of "=main.EnumName.foo" (not even valid input for parser)
                    .@"enum" => self.print("={s}", .{@tagName(ptr.*)}),
                    else => self.print("={}", .{ptr.*}),
                }
            }
        }

        fn usageStruct(self: *Self, s: Type.Struct) void {
            inline for (s.fields) |field| {
                self.print("{s}(", .{field.name});
                self.usageImpl(field.type);
                self.print(")", .{});
                self.defaultValue(field);
                self.print(" ", .{});
            }
        }

        fn usageUnion(self: *Self, u: Type.Union) void {
            const fields = u.fields;

            self.print("{{", .{});
            inline for (fields[0 .. fields.len - 1]) |field| {
                self.print("{s}(", .{field.name});
                self.usageImpl(field.type);
                self.print("),");
            }
            self.print("{s}(", .{fields[fields.len - 1].name});
            self.usageImpl(fields[fields.len - 1].type);
            self.print(")}}", .{});
        }

        fn usageImpl(self: *Self, T: type) void {
            const I = @typeInfo(T);

            switch (I) {
                .bool, // TODO: Show string literals that cast to bool (?)
                .int,
                .float,
                => self.print("{s}", .{@typeName(T)}),
                .@"enum" => |e| self.usageEnum(e),
                .@"struct" => |s| self.usageStruct(s),
                .@"union" => |u| self.usageUnion(u),
                else => {
                    const msg = "Showing usage for arguments of type '" ++ @typeName(T) ++ "' not supported at the moment.";
                    @compileError(msg);
                },
            }
        }

        fn usage(self: *Self, user_command: UserCommand) void {
            switch (user_command) {
                inline else => |command| {
                    const Cmd = @TypeOf(command);

                    if (@hasDecl(Cmd, "usage")) {
                        self.print("{s}", .{Cmd.usage});
                    } else {
                        // default implementation: introspection of arguments
                        self.print("usage: {s} ", .{@tagName(user_command)});
                        self.usageImpl(Cmd);
                    }
                },
            }
        }

        fn unknown(self: *Self, name: []const u8) void {
            self.print("unknown command: {s}", .{name});
        }

        fn usageFor(self: *Self, name: []const u8) void {
            const I = @typeInfo(UserCommand);

            inline for (I.@"union".fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    self.usage(@unionInit(UserCommand, field.name, undefined));
                    return;
                }
            }

            self.unknown(name);
        }

        fn help(self: *Self) void {
            const B = @typeInfo(BuiltinCommand);
            const I = @typeInfo(UserCommand);

            self.print("Available commands:", .{});
            inline for (B.@"enum".fields) |field| {
                self.print("\n  * {s}", .{field.name});
            }

            inline for (I.@"union".fields) |field| {
                self.print("\n  * {s}", .{field.name});
            }
        }

        fn assertArgsExhausted(self: *Self, parser: *Parser) !void {
            if (parser.tokensLeft()) {
                self.print("Too many args received\n", .{});
                return error.TooManyArgs;
            }
        }

        fn getBuiltinCommand(self: *Self, parser: *Parser) !BuiltinCommand {
            parser.reset();

            const builtin_command = parser.required(BuiltinCommand) catch |err| {
                parser.reset();
                self.unknown(parser.next().?);
                return err;
            };

            switch (builtin_command) {
                .clear,
                .exit,
                .history,
                => try self.assertArgsExhausted(parser),

                .@"!",
                .help,
                => {},
            }

            return builtin_command;
        }

        // NOTE: doesn't return an eror because this function and handle() call each other
        // thus, zig is unable to infer error type
        fn handleBuiltin(self: *Self, command: BuiltinCommand, parser: *Parser) ?void {
            switch (command) {
                .@"!" => {
                    const i = parser.required(usize) catch return null;

                    // remove "! <n>" from history
                    // the command being referenced will be put in history (which makes more sense)
                    _ = self.history.pop();

                    const line: []const u8 = &self.history.get(i);
                    self.handle(line) catch return null;
                },
                .clear => self.print("{s}", .{Escape.Clear}),
                .exit => self.stop_running = true,
                .help => {
                    if (parser.next()) |name| {
                        self.assertArgsExhausted(parser) catch return null;

                        self.usageFor(name);
                    } else {
                        self.help();
                    }
                },
                .history => {
                    for (0.., self.history.buffer[0 .. self.history.len - 1]) |i, line| {
                        self.print("{}: {s}\n", .{ i, line });
                    }
                    self.print("{}: {s}\n", .{ self.history.len - 1, self.history.buffer[self.history.len - 1] });
                }
            }
        }

        fn getUserCommand(self: *Self, parser: *Parser) !?UserCommand {
            return parser.required(UserCommand) catch |err| {
                // no user input, do nothing
                if (parser.successful_parses == 0 and err == error.MissingArg) {
                    return null;
                }

                // name did not exist in UserCommand, try and find into BuiltinCommand
                if (parser.successful_parses == 0 and err == error.InvalidArg) {
                    const builtin_command = try self.getBuiltinCommand(parser);
                    self.handleBuiltin(builtin_command, parser) orelse return error.BuiltinError;
                    return null;
                }

                // something went wrong while parsing
                parser.reset();
                const name = parser.next().?;
                self.usageFor(name);
                return null;
            };
        }

        pub fn handle(self: *Self, line: []const u8) !void {
            var parser = Parser.new(line);

            // only append to history if there has been *some* input
            if (parser.next()) |_| {
                self.appendHistory(line);
            }

            parser.reset();
            var user_command = try self.getUserCommand(&parser) orelse return;

            // if anything goes wrong after this point, show usage
            errdefer self.usage(user_command);

            switch (user_command) {
                inline else => |command| {
                    const Cmd = @TypeOf(command);

                    if (!@hasDecl(Cmd, "allow_extra_args") or !Cmd.allow_extra_args) {
                        try self.assertArgsExhausted(&parser);
                    }
                },
            }

            return user_command.handle(&parser);
        }
    };
}
