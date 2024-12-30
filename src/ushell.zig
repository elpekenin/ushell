//! Utilities to make a shell-like interface.

const std = @import("std");
const Type = std.builtin.Type;

const builtins = @import("builtins.zig");
const BuiltinCommand = builtins.BuiltinCommand;
const find = @import("find.zig");
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
            errdefer self.helpFor(@tagName(command.*));

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
                self.helpFor(name);
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

        fn defaultValue(self: *Self, field: Type.StructField) void {
            if (field.default_value) |def| {
                self.print("=", .{});

                const T = field.type;

                const ptr: *align(field.alignment) const T = @alignCast(@ptrCast(def));
                const val = ptr.*;

                const I = @typeInfo(field.type);
                switch (T) {
                    []const u8 => self.print("{s}", .{val}),
                    ?[]const u8 => self.print("{?s}", .{val}),
                    else => switch (I) {
                        // eg: show "=foo" instead of "=main.EnumName.foo" (not even valid input for parser)
                        .@"enum" => self.print("{s}", .{@tagName(val)}),
                        .optional => self.print("{?}", .{val}),
                        else => self.print("{}", .{val}),
                    },
                }
            }
        }

        fn enumUsage(self: *Self, e: Type.Enum) void {
            const fields = e.fields;

            self.print("{{", .{});
            inline for (fields[0 .. fields.len - 1]) |field| {
                self.print("{s},", .{field.name});
            }
            self.print("{s}}}", .{fields[fields.len - 1].name});
        }

        fn structUsage(self: *Self, s: Type.Struct) void {
            inline for (s.fields) |field| {
                self.print("{s}(", .{field.name});
                self.typeUsage(field.type);
                self.print(")", .{});
                self.defaultValue(field);
                self.print(" ", .{});
            }
        }

        fn unionUsage(self: *Self, u: Type.Union) void {
            const fields = u.fields;

            self.print("{{", .{});
            inline for (fields[0 .. fields.len - 1]) |field| {
                self.print("{s}(", .{field.name});
                self.typeUsage(field.type);
                self.print("),");
            }
            self.print("{s}(", .{fields[fields.len - 1].name});
            self.typeUsage(fields[fields.len - 1].type);
            self.print(")}}", .{});
        }

        fn typeUsage(self: *Self, T: type) void {
            const I = @typeInfo(T);

            switch (T) {
                // TODO?: show string literals that cast to bool values
                bool => self.print("bool", .{}),
                []const u8 => self.print("string", .{}),
                ?[]const u8 => self.print("optional string", .{}),
                else => switch (I) {
                    .int,
                    .float,
                    => self.print("{s}", .{@typeName(T)}),
                    .@"enum" => |e| self.enumUsage(e),
                    .@"struct" => |s| self.structUsage(s),
                    .@"union" => |u| self.unionUsage(u),
                    else => {
                        const msg = "Showing usage for arguments of type '" ++ @typeName(T) ++ "' not supported at the moment.";
                        @compileError(msg);
                    },
                },
            }
        }

        fn helpInner(self: *Self, name: []const u8, Inner: type) void {
            if (@hasDecl(Inner, "usage")) {
                self.print("{s}", .{Inner.usage});
            } else {
                // default implementation: introspection of arguments
                self.print("usage: {s} ", .{name});
                self.typeUsage(Inner);

                if (@hasDecl(Inner, "description")) {
                    self.print("-- {s}", .{Inner.description});
                }
            }
        }

        pub fn helpFor(self: *Self, name: []const u8) void {
            // NOTE: Not using a Parser here so that we can identify commands from partial input
            //
            // This is, if we have a `foo: struct { n: u32 }` command and we receive an input of "foo",
            // we can't fully parse the type (`n` is missing), but we can identify the type that
            // it uses internally (the anonymous struct with a u32 field), and show the usage
            // based on this knowledge

            const U = @typeInfo(UserCommand);
            const B = @typeInfo(BuiltinCommand);

            inline for (U.@"union".fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    self.helpInner(field.name, field.type);
                    return;
                }
            }

            inline for (B.@"enum".fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    const builtin: BuiltinCommand = @enumFromInt(field.value);
                    self.print("{s}", .{builtin.usage()});
                    return;
                }
            }

            self.unknown(name);
        }

        pub fn listCommands(self: *Self) void {
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
    };
}
