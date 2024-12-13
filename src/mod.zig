// TODO: Add argument parsing facilities (?)

const std = @import("std");
const Type = std.builtin.Type;

const logger = std.log.scoped(.terminal);

pub const Escape = @import("Escape.zig");
pub const Keys = @import("Keys.zig");
pub const Parser = @import("Parser.zig");

fn Handler(Inner: type) type {
    return *const fn (*Inner, *Parser) anyerror!void;
}

fn findSpecial(Inner: type, name: []const u8) ?Handler(Inner) {
    if (!@hasDecl(Inner, "Special")) return null;
    if (!@hasDecl(Inner.Special, name)) return null;
    return @field(Inner.Special, name);
}

/// Wrap a struct that "defines" a shell, adding some utilities.
///
/// `Inner` is expected to provide:
///  * `fn readByte(*Inner) !u8`: A function used by this wrapper to read user input.
///  * `Inner.Commands`: A `pub struct` defining commands
///    * Each (pub) decl is a `fn <command_name>(*Inner, *ArgIterator)`. This is, a method where the second argument is an iterator to read the remaining of the input (eg: to parse arguments).
///    * If present, the one named `@" "` will get executed if none matched (eg: to print error message).
///
/// `Outer` (the type returned) provides:
///  * `fn new(Inner) Outer`: Create an instance from an instance of `Inner`
///  * `fn readline(*Outer) ![]const u8`: Consume input until "\n" is received, retuning the string read.
///  * `fn handle(*Outer, []const u8) !void`: Finds command name (first word in input) and -tries- executes the function with the same name within `Inner.Commands`, falling back to `@"not-found"` if available.
///
/// NOTE: Writing back (for user feedback) is out of scope -for now?- and has to be handled completely within `Inner`'s logic.
pub fn Wrapper(comptime Inner: type) type {
    if (@typeInfo(Inner) != .@"struct" or !@hasDecl(Inner, "Commands") or @typeInfo(Inner.Commands) != .@"struct") {
        const msg = "Invalid input passed to `Wrapper()`, check the documentation comment";
        @compileError(msg);
    }

    const maybe_tab = findSpecial(Inner, "tab");
    const maybe_fallback = findSpecial(Inner, "fallback");

    const Outer = struct {
        const Self = @This();

        const Fn = Handler(Inner);
        const KeyVal = struct { []const u8, Fn };
        const CommandMap = std.StaticStringMap(Fn);

        const rx_len = 1024;
        const Buff = std.BoundedArray(u8, rx_len);

        inner: Inner,
        commands: CommandMap,
        buffer: Buff,

        fn getKeyVals() []KeyVal {
            const commands = @typeInfo(Inner.Commands).@"struct".decls;

            var buffer: [commands.len]KeyVal = undefined;

            for (commands, 0..) |command, i| {
                const key = command.name;
                const val = @field(Inner.Commands, key);

                buffer[i] = KeyVal{ key, val };
            }

            return buffer[0..commands.len];
        }

        pub fn new(inner: Inner) Self {
            const key_vals = comptime getKeyVals();
            const map = CommandMap.initComptime(key_vals);

            return Self{
                .inner = inner,
                .commands = map,
                // has size rx_len (>0), can't fail
                .buffer = Buff.init(0) catch unreachable,
            };
        }

        /// Read one byte at a time, or null if nothing was to be read
        fn read(self: *Self) !?u8 {
            return self.inner.readByte() catch |err| switch (err) {
                error.EndOfStream => return null, // nothing was read
                else => |e| {
                    logger.err("Unknown error on reader ({any})", .{e});
                    return e;
                },
            };
        }

        /// Call `.read()` in a loop until a newline is received, returning the string at that point
        pub fn readline(self: *Self) ![]const u8 {
            self.buffer.clear(); // cleanup before using

            while (true) {
                const byte = try self.read() orelse continue;

                switch (byte) {
                    Keys.Newline => {
                        // input ready, return it to be handled
                        return self.buffer.constSlice();
                    },
                    Keys.Tab => {
                        if (maybe_tab) |tab| {
                            var args = Parser.new(self.buffer.constSlice());
                            try tab(&self.inner, &args);
                        }
                    },
                    Keys.Backspace => {
                        // backspace deletes previous char (if any)
                        _ = self.buffer.popOrNull();
                    },
                    else => {
                        self.buffer.append(byte) catch std.debug.panic("Exhausted rx_buffer", .{});
                    },
                }
            }
        }

        pub fn handle(self: *Self, line: []const u8) !void {
            var args = Parser.new(line);

            const command_name = try args.commandName();
            if (self.commands.get(command_name)) |func| {
                return func(&self.inner, &args);
            }

            if (maybe_fallback) |fallback| {
                return fallback(&self.inner, &args);
            }
        }
    };

    return Outer;
}
