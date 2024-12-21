// TODO: Add argument parsing facilities (?)

const std = @import("std");
const Type = std.builtin.Type;

const logger = std.log.scoped(.ushell);

pub const Escape = @import("Escape.zig");
pub const Keys = @import("Keys.zig");
pub const Parser = @import("Parser.zig");

const BuiltinCommand = enum {
    clear,
    help,
    exit,
};

fn validate(T: type) void {
    const I = @typeInfo(T);

    if (I != .@"union") {
        const msg = "Commands must be represented with a `union(enum)`";
        @compileError(msg);
    }
}

pub const ShellOptions = struct {
    buffer_size: usize = 200,
    prompt: []const u8 = "$ ",
};

/// A shell's type is defined by a `union(enum)` of different commands and some optional arguments.
///
/// At runtime, an isntance of this type is created by calling `Shell.new` with a reader and writer.
///
/// See `examples/echo.zig` for a small demo.
pub fn Shell(UserCommand: type, options: ShellOptions) type {
    validate(UserCommand);

    return struct {
        const Self = @This();

        reader: std.io.AnyReader,
        writer: std.io.AnyWriter,
        buffer: std.BoundedArray(u8, options.buffer_size),

        stop_running: bool,

        pub fn new(
            reader: std.io.AnyReader,
            writer: std.io.AnyWriter,
        ) Self {
            return Self{
                .reader = reader,
                .writer = writer,
                .buffer = undefined,
                .stop_running = false,
            };
        }

        fn readByte(self: *Self) !?u8 {
            return self.reader.readByte() catch |err| switch (err) {
                error.EndOfStream => return null, // nothing was read
                else => |e| {
                    logger.err("Unknown error on reader ({any})", .{e});
                    return e;
                },
            };
        }

        pub fn readline(self: *Self) ![]const u8 {
            self.buffer.clear();

            while (true) {
                const byte = try self.readByte() orelse continue;

                switch (byte) {
                    Keys.Newline => {
                        // input ready, return it to be handled
                        return self.buffer.constSlice();
                    },
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

        fn usageStruct(self: *Self, s: Type.Struct) void {
            inline for (s.fields) |field| {
                self.print("{s}(", .{field.name});
                self.usageImpl(field.type);
                self.print(") ", .{});
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

        fn usage(self: *Self, cmd: UserCommand) void {
            self.print("usage: {s} ", .{@tagName(cmd)});

            switch (cmd) {
                inline else => |child| self.usageImpl(@TypeOf(child)),
            }
        }

        fn help(self: *Self) void {
            const I = @typeInfo(UserCommand);

            self.print("Available commands:", .{});
            inline for (I.@"union".fields) |field| {
                self.print("\n  * {s}", .{field.name});
            }
        }

        pub fn handle(self: *Self, line: []const u8) !void {
            var parser = Parser.new(line);

            var command = parser.required(UserCommand) catch |err| {
                logger.debug("Couldn't parse as UserCommand ({s})", .{@errorName(err)});

                // no user input, do nothing
                if (parser.successful_parses == 0 and err == error.MissingArg) {
                    logger.debug("No input received", .{});
                    return;
                }

                // name did not exist in UserCommand, try and find into BuiltinCommand
                if (parser.successful_parses == 0 and err == error.InvalidArg) {
                    parser.reset();

                    const builtin_command = parser.required(BuiltinCommand) catch {
                        logger.debug("Couldn't parse as BuiltinCommand", .{});

                        parser.reset();
                        self.print("unknown command: {s}", .{parser.next().?});

                        return;
                    };

                    // TODO: Assert no extra args?
                    switch (builtin_command) {
                        .clear => self.print("{s}", .{Escape.Clear}),
                        .exit => self.stop_running = true,
                        .help => self.help(),
                    }

                    return;
                }

                // something went wrong while parsing
                parser.reset();
                const name = parser.next().?;

                const I = @typeInfo(UserCommand);

                inline for (I.@"union".fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) {
                        self.usage(@unionInit(UserCommand, field.name, undefined));
                    }
                }

                return;
            };

            // TODO: Implement something like
            // ```zig
            // if (!@hasDecl(Command, "allow_extra_args") or !Command.allow_extra_args) {
            //     if (parser.tokensLeft()) return error.TooManyArgs;
            // }
            // ```
            logger.debug("Parsed ({any})", .{command});
            return command.handle(&parser) catch |err| {
                logger.debug("command.handle() ({s})", .{@errorName(err)});
                self.usage(command);
                return err;
            };
        }
    };
}
