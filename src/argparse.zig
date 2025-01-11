//! Tiny argument-parser library
//!
//! Main design goal is to keep it allocation-free.
//!
//! Loosely inspired by Python's stdlib

const std = @import("std");
const t = std.testing;
const Type = std.builtin.Type;

const internal = @import("internal.zig");

// TODO?: Print diagnostics when parsing a line fails

/// Metadata about a command (it is optional)
pub const Meta = struct {
    usage: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

//
// Custom argument types
//

// WARN: Remember to implement `translatedField` for new types here

/// When a field is defined as `name: OptionalFlag`, passing `--name` or `--no-name`
/// will set `name` to `true` or `false` in the parsed type. If neither is found, value is `null`.
///
/// If flag is found twice (even if both times are for the same value), parser will error.
///
/// The parsing of this type is position independent. This is, you can input both `mkdir --parents foo`
/// and `mkdir foo --parents`
pub const OptionalFlag = struct {};

/// Capture remaining tokens.
///
/// Must be the last non-optional field in a command.
pub const TokensLeft = struct {};

// Future ideas:
//   * Flag with default value
//   * Support arrays? If so, should we force N items, or *up* to N items?

//
// User-facing API
//

/// Try and parse a token into the specified type
pub fn parseToken(comptime T: type, token: []const u8) !T {
    const info = @typeInfo(T);

    if (T == []const u8) return token;

    return switch (info) {
        .bool => parseBool(token),
        .@"enum" => parseEnum(T, token),
        .int => parseInt(T, token),
        .float => parseFloat(T, token),
        .optional => |o| try parseToken(o.child, token),
        else => internal.err("Unsupported type of argument: " ++ @typeName(T)),
    };
}

/// Resulting type after parsing the specified type
///
/// Most of the times, output will be the same as input
///
/// However, on special types, a translation occurs (for example: `OptionalFlag` -> `?bool = null`)
pub fn Args(comptime Spec: type) type {
    const spec = switch (@typeInfo(Spec)) {
        .@"struct" => return Struct(Spec),
        .@"union" => |u| u,
        else => internal.err("Invalid argument, must be union(enum)"),
    };
    _ = spec.tag_type orelse internal.err("Union must have a tag_type");

    const in = spec.fields;

    var different = false;

    var out: [in.len]Type.UnionField = undefined;
    for (0.., in) |n, field| {
        switch (@typeInfo(field.type)) {
            .@"struct" => {
                var copy = field;
                copy.type = Struct(field.type);

                out[n] = copy;

                if (copy.type != field.type) different = true;
            },
            else => internal.err("Invalid type of union"),
        }
    }

    if (!different) return Spec;

    var copy = spec;
    copy.fields = &out;

    return @Type(.{ .@"union" = copy });
}

/// This is what you get back after trying to parse some input
///   * A command name + the args provided (success)
///   * Marker that no input was received (error)
///   * A command name + the error thrown while trying to parse its arguments (error)
///   * Name (first token in input) was not a known command (error)
pub fn Result(comptime Spec: type) type {
    return union(enum) {
        ok: struct {
            name: []const u8,
            args: Args(Spec),
        },
        empty_input,
        parsing_error: struct {
            name: []const u8,
            err: anyerror,
        },
        unknown_command: []const u8,
    };
}

/// Some configuration of how the parser works
pub const Options = struct {
    max_tokens: usize,
};

/// Given a collection of commands in the form of a `union(enum)`, this function returns
/// a type whose `.parse([]const u8)` function will try and parse one of them (name and args)
/// from user input
pub fn ArgumentParser(comptime Spec: type, comptime options: Options) type {
    if (options.max_tokens == 0) internal.err("Buffer can't be 0-sized");

    const Parsed = Args(Spec);
    const Return = Result(Spec);
    const fields = internal.unionFields(Spec);

    return struct {
        /// Try and extract a command and its arguments from user input
        pub fn parse(input: []const u8) Return {
            var tokenizer: Tokenizer(options) = .new();
            const tokens = tokenizer.getTokens(input);

            if (tokens.len == 0) return .empty_input;

            const tag = tokens[0];

            // find the struct used by this tag, and parse it
            inline for (fields) |field| {
                if (std.mem.eql(u8, field.name, tag)) {
                    const inner = parseStruct(field.type, tokens[1..]) catch |e| {
                        return .{
                            .parsing_error = .{
                                .name = tag,
                                .err = e,
                            },
                        };
                    };

                    return .{
                        .ok = .{
                            .name = tag,
                            .args = @unionInit(
                                Parsed,
                                field.name,
                                inner,
                            ),
                        },
                    };
                }
            }

            return .{ .unknown_command = tag };
        }
    };
}

// **********************************************
//
// Below this point, there is some internal stuff
//   * Utility types and functions
//   * Small test suite
//   * Private functions used by public API
//
// As a user, you shouldn't need to look at them
//
// **********************************************

//
// Parsing of specific types
//

fn parseBool(token: []const u8) !bool {
    // TODO?: Allow other forms such as 0/1 or y/n
    if (std.mem.eql(u8, "true", token)) {
        return true;
    }

    if (std.mem.eql(u8, "false", token)) {
        return false;
    }

    return error.InvalidArg;
}

fn parseEnum(comptime T: type, token: []const u8) !T {
    inline for (internal.enumFields(T)) |field| {
        if (std.mem.eql(u8, token, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return error.InvalidArg;
}

fn parseFloat(comptime T: type, token: []const u8) !T {
    return std.fmt.parseFloat(T, token) catch return error.InvalidArg;
}

fn parseInt(comptime T: type, token: []const u8) !T {
    return std.fmt.parseInt(T, token, 0) catch return error.InvalidArg;
}

//
// Uncategorized stuff below
//

const dummy: ?bool = null;

/// Make conversions for some types that change during translation
/// eg: `OptionalFlag` -> `?bool = null`
fn translatedField(comptime field: Type.StructField) Type.StructField {
    return switch (field.type) {
        OptionalFlag => .{
            .name = field.name,
            .type = ?bool,
            // &null here is wrong (?)
            .default_value = &dummy,
            .is_comptime = false,
            .alignment = std.meta.alignment(?bool),
        },

        TokensLeft => .{
            .name = field.name,
            .type = []const []const u8,
            .default_value = null,
            .is_comptime = false,
            .alignment = std.meta.alignment([][]const u8),
        },

        else => field,
    };
}

fn indexOfFirstDefault(comptime T: type) ?usize {
    for (0.., internal.structFields(T)) |i, field| {
        if (field.default_value) |_| return i;
    }

    return null;
}

fn validateBefore(comptime fields: []const Type.StructField) void {
    var tokens_left_index: ?usize = null;
    var optional_flags: bool = false;

    for (0.., fields) |n, field| {
        if (tokens_left_index != null) internal.err("TokensLeft must be the last field");

        if (field.type == TokensLeft) {
            if (tokens_left_index) |_| internal.err("TokensLeft can only appear once");

            tokens_left_index = n;
        }

        if (!optional_flags and field.type == OptionalFlag) optional_flags = true;
    }

    if (optional_flags and tokens_left_index != null) internal.err("Can't use OptionalFlag and TokensLeft at the same time");
}

/// Validate some constraints after adjusting type, before using @Type
fn validateAfter(comptime fields: []const Type.StructField) void {
    var first_default: ?usize = null;
    var last_non_default: ?usize = null;

    for (0.., fields) |n, field| {
        if (field.default_value) |_| {
            if (first_default == null) first_default = n;
        } else {
            last_non_default = n;
        }
    }

    if (first_default) |first| {
        if (last_non_default) |last| {
            if (first < last) internal.err("Fields with default values must be last");
        }
    }
}

/// Resulting type after parsing the specified type.
///
/// Most of the times, output will be the same as input.
fn Struct(comptime Spec: type) type {
    const in_fields = internal.structFields(Spec);
    validateBefore(in_fields);

    var different = false;

    var out: [in_fields.len]Type.StructField = undefined;
    for (0.., in_fields) |n, field| {
        const translated = translatedField(field);
        out[n] = translated;

        if (translated.type != field.type) different = true;
    }

    if (!different) return Spec;

    var info = @typeInfo(Spec);
    info.@"struct".decls = &.{}; // @Type doesn't allow decls
    info.@"struct".fields = &out;

    validateAfter(&out);
    return @Type(info);
}

/// Create an instance of the given struct, appyling default value
/// to those fields who have one, and letting others `undefined`
fn defaultStruct(comptime T: type) T {
    const fields = internal.structFields(T);

    var out: T = undefined;
    inline for (fields) |field| {
        if (internal.defaultValueOf(field)) |default| {
            @field(out, field.name) = default;
        }
    }

    return out;
}

/// Consume tokens from a string (delimited by whitespace)
///
/// Handles quoting, such that `"hello world"` emits `hello world`
/// and not `"hello` + `world"`
fn Tokenizer(comptime options: Options) type {
    return struct {
        const Self = @This();

        /// "whitespace" chars to split at (delimit words) when parsing
        const delimiters = " \r\n\t\u{0}";

        buffer: [options.max_tokens][]const u8,

        pub fn new() Self {
            return Self{
                .buffer = .{"no init"} ** options.max_tokens,
            };
        }

        // get next token from iterator, handling quoted strings
        fn next(iterator: *std.mem.TokenIterator(u8, .any)) ?[]const u8 {
            const start = iterator.index;

            const raw = iterator.next() orelse return null;

            const char = raw[0];
            if (char != '"' and char != '\'') {
                return raw;
            }

            // getting here means we got a quoted string
            // keep consuming input until we get its closing counterpart
            while (next(iterator)) |token| {
                if (token[token.len - 1] == char) {
                    const end = iterator.index - 1;
                    return iterator.buffer[start + 2 .. end];
                }
            }

            // exhausted input while looking for closing quote => no token to be returned
            // TODO?: Error?
            return null;
        }

        pub fn getTokens(self: *Self, input: []const u8) []const []const u8 {
            var n: usize = 0;
            var iterator = std.mem.tokenizeAny(u8, input, delimiters);

            while (next(&iterator)) |token| {
                if (n == options.max_tokens) std.debug.panic("Exhausted parser's buffer", .{});

                self.buffer[n] = token;
                n += 1;
            }

            return self.buffer[0..n];
        }
    };
}

/// Wrapper on top of an `ArrayBitSet` to track parsing of fields
///   * Which ones have (not) been found
///   * Which one is the next to be found
///   * Whether we have parsed all non-optional fields
///   * Whether we have found every single field (optionals too)
fn ParsedFields(comptime Parsed: type) type {
    const fields = internal.structFields(Parsed);

    return struct {
        const Self = @This();

        inner: std.bit_set.ArrayBitSet(u32, fields.len),

        fn initEmpty() Self {
            return Self{
                .inner = .initEmpty(),
            };
        }

        fn full(self: *const Self) bool {
            return self.inner.count() == self.inner.capacity();
        }

        fn done(self: *const Self) bool {
            const required = comptime indexOfFirstDefault(Parsed) orelse fields.len;
            return self.inner.count() >= required;
        }

        fn add(self: *Self, comptime index: usize) !void {
            if (self.inner.isSet(index)) return error.RepeatedArg;
            self.inner.set(index);
        }

        fn next(self: *const Self) usize {
            return self.inner.complement().findFirstSet() orelse 0;
        }
    };
}

/// If token starts with "--" parse it as a flag.
fn parseFlag(
    comptime Spec: type,
    token: []const u8,
    ret: *Struct(Spec),
    parsed_fields: *ParsedFields(Struct(Spec)),
) !void {
    const flag = token[2..];

    inline for (0.., internal.structFields(Spec)) |n, field| {
        const maybe_value = if (std.mem.eql(u8, field.name, flag))
            true
        else if (std.mem.eql(u8, "no-" ++ field.name, flag))
            false
        else
            null;

        if (maybe_value) |value| {
            if (field.type != OptionalFlag) return error.InvalidFlag;
            @field(ret, field.name) = value;
            return parsed_fields.add(n);
        }
    }

    return error.UnknownFlag;
}

/// Given an input type, try and parse an instance of it from the stream of tokens.
fn parseStruct(comptime Spec: type, tokens: []const []const u8) !Struct(Spec) {
    const Parsed = Struct(Spec);
    var ret: Parsed = defaultStruct(Parsed);

    // store which fields have been parsed already
    var parsed_fields: ParsedFields(Parsed) = .initEmpty();

    token_loop: for (0.., tokens) |n_token, token| {
        if (parsed_fields.full()) return error.TooManyArgs;

        // if we parsed a flag, skill extra logic
        if (std.mem.startsWith(u8, token, "--")) {
            try parseFlag(Spec, token, &ret, &parsed_fields);
            continue;
        }

        // first field that hasn't been parsed yet
        const next_arg_index = parsed_fields.next();

        // we can't use `const field = fields[index]` because `index` is runtime and `fields` contains
        // comptime-only information (types)... hack around with inline loop
        //
        // on a similar note, can't clean up code with guard clauses because they use runtime information
        inline for (0.., internal.structFields(Spec), internal.structFields(Parsed)) |n_field, in, field| {
            if (n_field == next_arg_index) {
                const is_tokens_left = in.type == TokensLeft;

                // consume everything left
                @field(ret, field.name) = if (is_tokens_left)
                    tokens[n_token..]
                else
                    try parseToken(field.type, token);
                try parsed_fields.add(n_field);

                if (is_tokens_left) break :token_loop;
            }
        }
    }

    if (!parsed_fields.done()) return error.MissingArg;

    return ret;
}
