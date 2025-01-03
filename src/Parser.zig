//! Utilities to parse user input

// TODO: Convert `return try foo()` nonsense into `return foo()`
// See: https://github.com/ziglang/zig/issues/16765

const std = @import("std");
const t = std.testing;

const Type = std.builtin.Type;
const Iterator = std.mem.SplitIterator(u8, .any);

const Self = @This();

pub const ArgError = error{
    MissingArg,
    InvalidArg,
    TooManyArgs,
};

/// "whitespace" chars to split at (delimit words) when parsing
const delimiters = " \r\n\t\u{0}";

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
successful_parses: usize,

/// Create this wrapper on top of a string
pub fn new(line: []const u8) Self {
    return Self{
        .iterator = std.mem.splitAny(u8, line, delimiters),
        .successful_parses = 0,
    };
}

/// Get first token of input (command name)
pub fn first(self: *Self) ?[]const u8 {
    const copy = self.*;
    defer self.* = copy;

    self.reset();
    return self.next();
}

/// Back to initial state
pub fn reset(self: *Self) void {
    self.iterator.reset();
    self.successful_parses = 0;
}

/// Return the input exactly as received
pub fn rawLine(self: *const Self) []const u8 {
    return self.iterator.buffer;
}

/// Get next element as is (ie: string)
pub fn next(self: *Self) ?[]const u8 {
    const start = self.iterator.index orelse 0;

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

    const char = raw[0];
    if (char != '"' and char != '\'') {
        return raw;
    }

    // getting here means we got a quoted string
    // keep consuming input until we get its closing counterpart
    while (self.next()) |token| {
        if (token[token.len - 1] == char) {
            const end = if (self.iterator.index) |index|
                // -1 because index is where next token starts
                // another -1 because we want to skip the quote char
                index - 2
            else
                self.iterator.buffer.len - 1;
            return self.iterator.buffer[start + 1 .. end];
        }
    }

    // exhausted input while looking for closing quote => no token to be returned
    return null;
}

pub fn parseToken(_: *Self, T: type, token: []const u8) ArgError!T {
    const I = @typeInfo(T);

    return switch (I) {
        .bool => try parseBoolToken(token),
        .@"enum" => try parseEnumToken(T, token),
        .float => try parseFloatToken(T, token),
        .int => try parseIntToken(T, token),
        .optional => |o| try parseToken(o.child, token),
        else => {
            const msg = "Can't parse a token as type " ++ @typeName(T);
            @compileError(msg);
        },
    };
}

/// Parse the next token as T, or null if iterator was exhausted
pub fn optional(self: *Self, T: type) ArgError!?T {
    const I = @typeInfo(T);

    return switch (T) {
        // special case for strings
        []const u8 => self.next(),
        else => switch (I) {
            .bool => self.parseBool(),
            .@"enum" => self.parseEnum(T),
            .float => self.parseFloat(T),
            .int => self.parseInt(T),
            .optional => |o| self.optional(o.child),
            .@"struct" => self.parseStruct(T),
            .@"union" => self.parseUnion(T),
            else => {
                const msg = "Can't parse arguments of type " ++ @typeName(T);
                @compileError(msg);
            },
        } catch error.InvalidArg, // cast any type of parsing error to InvalidArg
    };
}

/// Parse next token as T, or default value if iterator exhausted
pub fn default(self: *Self, T: type, default_value: T) ArgError!T {
    const val = try self.optional(T) orelse default_value;
    self.successful_parses += 1;
    return val;
}

/// Parse next token as T, or error.MissingArg if iterator exhausted
pub fn required(self: *Self, T: type) ArgError!T {
    const val = try self.optional(T) orelse return error.MissingArg;
    self.successful_parses += 1;
    return val;
}

pub fn tokensLeft(self: *Self) bool {
    const copy = self.iterator;
    defer self.iterator = copy;

    const token = self.next();
    return token != null;
}

pub fn assertExhausted(self: *Self) ArgError!void {
    if (self.tokensLeft()) {
        return error.TooManyArgs;
    }
}

fn parseBoolToken(token: []const u8) ArgError!bool {
    if (token.len > max_bool_arg_len) return error.InvalidArg;

    for (bool_literals) |bool_literal| {
        for (bool_literal.strings) |string| {
            if (std.mem.eql(u8, string, token)) {
                return bool_literal.value;
            }
        }
    }

    return error.InvalidArg;
}

fn parseBool(self: *Self) ArgError!?bool {
    const token = self.next() orelse return null;
    return try parseBoolToken(token);
}

fn parseEnumToken(T: type, token: []const u8) ArgError!T {
    const I = @typeInfo(T);

    inline for (I.@"enum".fields) |field| {
        if (std.mem.eql(u8, token, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return error.InvalidArg;
}

fn parseEnum(self: *Self, T: type) ArgError!?T {
    const token = self.next() orelse return null;

    const val = try parseEnumToken(T, token);
    self.successful_parses += 1;
    return val;
}

fn parseFloatToken(T: type, token: []const u8) ArgError!T {
    return std.fmt.parseFloat(T, token) catch return error.InvalidArg;
}

fn parseFloat(self: *Self, T: type) ArgError!?T {
    const token = self.next() orelse return null;
    return try parseFloatToken(T, token);
}

fn parseIntToken(T: type, token: []const u8) ArgError!T {
    return std.fmt.parseInt(T, token, 0) catch return error.InvalidArg;
}

fn parseInt(self: *Self, T: type) ArgError!?T {
    const token = self.next() orelse return null;
    return try parseIntToken(T, token);
}

fn parseStruct(self: *Self, T: type) ArgError!?T {
    const I = @typeInfo(T);

    var val: T = undefined;
    inline for (I.@"struct".fields) |field| {
        if (field.default_value) |def| {
            const ptr: *align(field.alignment) const field.type = @alignCast(@ptrCast(def));
            const value = try self.default(field.type, ptr.*);
            @field(val, field.name) = value;
        } else {
            @field(val, field.name) = try self.required(field.type);
        }
    }

    return val;
}

fn parseUnion(self: *Self, T: type) ArgError!?T {
    const token = self.next() orelse return null;

    const I = @typeInfo(T);

    inline for (I.@"union".fields) |field| {
        if (std.mem.eql(u8, token, field.name)) {
            self.successful_parses += 1;
            return @unionInit(T, field.name, try self.required(field.type));
        }
    }

    return error.InvalidArg;
}

// Confirm that parsing primitives work as intended
//
// This is:
//   - next()
//   - optional(T)
//   - default(T, value)
//   - required(T)
// Return {null, value, error} on empty and invalid inputs
//
// NOTE: parse<T> functions are intentionally not tested, because they are internal API.
// They probably won't change in the slightest, but user will not interact with them anyway.
test "bad input" {
    var empty = new("  \t \t \r");
    try t.expectEqual(null, empty.next());

    empty.reset();
    try t.expectEqual(null, try empty.optional(bool));

    empty.reset();
    try t.expectEqual(true, try empty.default(bool, true));

    empty.reset();
    try t.expectError(ArgError.MissingArg, empty.required(bool));

    //

    var invalid = new("invalid  value");
    try t.expectEqualSlices(u8, "invalid", invalid.next().?);
    try t.expectEqualSlices(u8, "value", invalid.next().?); // not a 0-len slice between both whitespaces
    try t.expectEqual(null, invalid.next());

    invalid.reset();
    try t.expectError(ArgError.InvalidArg, invalid.optional(bool));

    invalid.reset();
    try t.expectError(ArgError.InvalidArg, invalid.default(bool, true));

    invalid.reset();
    try t.expectError(ArgError.InvalidArg, invalid.required(bool));
}

test "quoted" {
    var only_quotes = new("'foo bar'");
    try t.expectEqualSlices(u8, "foo bar", only_quotes.next().?);
    try t.expectEqual(null, only_quotes.next());

    var quotes_and_word = new("\"foo bar\" baz");
    try t.expectEqualSlices(u8, "foo bar", quotes_and_word.next().?);
    try t.expectEqualSlices(u8, "baz", quotes_and_word.next().?);
    try t.expectEqual(null, quotes_and_word.next());

    var not_closed = new("'foo bar error");
    try t.expectEqual(null, not_closed.next());

    var different_delimiters = new("'foo bar\" baz'");
    try t.expectEqualSlices(u8, "foo bar\" baz", different_delimiters.next().?);
    try t.expectEqual(null, different_delimiters.next());
}

// Check that parsing a bool works, not only with "true"/"false" but also with the extra "literals" defined
test "bool" {
    var parser = new("true");
    try t.expectEqual(true, try parser.required(bool));

    parser = new("no");
    try t.expectEqual(false, try parser.required(bool));
}

test "enum" {
    const TestEnum = enum { foo, bar };

    var parser = new("foo");
    try t.expectEqual(TestEnum.foo, try parser.required(TestEnum));

    parser = new("");
    try t.expectEqual(TestEnum.bar, try parser.default(TestEnum, .bar));

    parser = new("Foo");
    try t.expectError(ArgError.InvalidArg, parser.parseEnum(TestEnum));
}

test "float" {
    var parser = new("12.34");
    try t.expectEqual(12.34, try parser.required(f32));

    parser = new("-0x1.2e2");
    try t.expectEqual(-0x1.2e2, try parser.required(f32));
}

test "int" {
    var parser = new("42");
    try t.expectEqual(42, try parser.required(u8));

    parser = new("256");
    try t.expectError(ArgError.InvalidArg, parser.required(u8));

    parser.reset();
    try t.expectEqual(256, try parser.required(u16));

    parser = new("0x16");
    try t.expectEqual(0x16, try parser.required(u8));

    parser = new("-0b1_0");
    try t.expectEqual(-0b10, try parser.required(i8));
}

test "struct" {
    const TestStruct = struct {
        foo: bool,
        bar: u32,
        baz: u8 = 2,
    };

    // value overwrites default
    var parser = new("true 42 16");
    try t.expectEqual(TestStruct{ .foo = true, .bar = 42, .baz = 16 }, try parser.required(TestStruct));

    // default value is taken, not ignored/error out
    parser = new("false 1");
    try t.expectEqual(TestStruct{ .foo = false, .bar = 1 }, try parser.required(TestStruct));
}

test "union" {
    const TestUnion = union(enum) {
        foo: u8,
        bar: u16,
    };

    var parser = new("foo 0x16");
    try t.expectEqual(TestUnion{ .foo = 0x16 }, try parser.required(TestUnion));

    parser = new("bar 1000");
    try t.expectEqual(TestUnion{ .bar = 1000 }, try parser.required(TestUnion));
}

test "nested" {
    const TestType = struct {
        e: enum {
            first,
            second,
        },
        u: union(enum) {
            bar: struct { u8, bool },
            baz: bool,
        },
    };

    var parser = new("second bar 10 true");
    try t.expectEqualDeep(TestType{ .e = .second, .u = .{ .bar = .{ 10, true } } }, try parser.required(TestType));
}
