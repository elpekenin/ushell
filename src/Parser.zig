//! Utilities to parse user input

const std = @import("std");

const Type = std.builtin.Type;
const Iterator = std.mem.SplitIterator(u8, .any);

const Self = @This();

const ArgError = error{
    MissingArg,
    InvalidArg,
};

/// "whitespace" chars to split at (delimit words) when parsing
const delimiters = " \r\n";

const BoolLiteral = struct {
    value: bool,
    strings: []const []const u8,
};

/// Strings that will be interpreted as true/false
const bool_literals: []const BoolLiteral = &.{
    .{
        .value = false,
        .strings = &.{ "n", "no", "false", "0" },
    },
    .{
        .value = true,
        .strings = &.{ "y", "yes", "true", "1" },
    },
};

const max_bool_arg_len = blk: {
    var max_len = 0;

    for (bool_literals) |bool_literal| {
        for (bool_literal.strings) |string| {
            max_len = @max(string.len, max_len);
        }
    }

    break :blk max_len;
};

iterator: Iterator,
command_name: ?[]const u8 = null,

fn info(T: type) Type {
    return @typeInfo(T);
}

/// Create this wrapper on top of a string
pub fn new(line: []const u8) Self {
    return Self{
        .iterator = std.mem.splitAny(u8, line, delimiters),
    };
}

/// Return the input exactly as received
pub fn rawLine(self: *const Self) []const u8 {
    return self.iterator.buffer;
}

/// Get the command name (first word in input)
pub fn commandName(self: *Self) ![]const u8 {
    if (self.command_name == null) {
        self.iterator.reset();
        self.command_name = self.next() orelse {
            return error.NoCommand;
        };
    }

    return self.command_name.?;
}

/// Get next element as is (ie: string)
pub fn next(self: *Self) ?[]const u8 {
    const raw = self.iterator.next() orelse {
        // iterator exhausted
        return null;
    };

    // a "token" of len 0 would be detected on "foo  bar"
    //                      between these 2 spaces ^^
    // if this happens, run another iteration
    if (raw.len == 0) {
        return self.next();
    }

    return raw;
}

/// Parse the next token as T, or null if iterator was exhausted
pub fn optional(self: *Self, T: type) ArgError!?T {
    const token = self.next() orelse return null;

    const I = info(T);

    return switch (I) {
        .bool => self.Bool(token),
        .@"enum" => self.Enum(T, token),
        .float => self.Float(T, token),
        .int => self.Int(T, token),
        else => {
            const msg = "Parsing arguments of type '" ++ @typeName(T) ++ "' not supported at the moment.";
            @compileError(msg);
        },
    } catch error.InvalidArg;
}

/// Parse next token as T, or default value if iterator exhausted
pub fn default(self: *Self, T: type, default_value: T) ArgError!T {
    return try self.optional(T) orelse default_value;
}

/// Parse next token as T, or error.MissingArg if iterator exhausted
pub fn required(self: *Self, T: type) ArgError!T {
    return try self.optional(T) orelse error.MissingArg;
}

/// Confirm that is nothing left to parse
pub fn tokensLeft(self: *Self) bool {
    const copy = self.iterator;
    defer self.iterator = copy;

    const token = self.next();
    return token != null;
}

fn Bool(_: *Self, token: []const u8) !bool {
    if (token.len > max_bool_arg_len) return error.InvalidArg;

    var buff: [max_bool_arg_len]u8 = undefined;
    const lower = std.ascii.lowerString(&buff, token);

    for (bool_literals) |bool_literal| {
        for (bool_literal.strings) |string| {
            if (std.mem.eql(u8, string, lower)) {
                return bool_literal.value;
            }
        }
    }

    return error.InvalidArg;
}

fn Enum(_: *Self, T: type, token: []const u8) !T {
    const I = info(T);

    inline for (I.@"enum".fields) |field| {
        if (std.mem.eql(u8, token, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return error.InvalidArg;
}

fn Float(_: *Self, T: type, token: []const u8) !T {
    return std.fmt.parseFloat(T, token);
}

fn Int(_: *Self, T: type, token: []const u8) !T {
    return std.fmt.parseInt(T, token, 0);
}
