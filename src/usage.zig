const std = @import("std");
const p = std.fmt.comptimePrint;
const Type = std.builtin.Type;

const argparse = @import("argparse.zig");
const internal = @import("internal.zig");

// TODO: support for OptionalFlag and TokensLeft

fn defaultValue(comptime field: Type.StructField) []const u8 {
    const value = internal.defaultValueOf(field) orelse return "";

    const T = field.type;
    const I = @typeInfo(field.type);

    return "=" ++ switch (T) {
        []const u8 => p("{s}", .{value}),
        ?[]const u8 => p("{?s}", .{value}),
        else => switch (I) {
            // eg: show "=foo" instead of "=main.EnumName.foo" (not even valid input for parser)
            .@"enum" => p("{s}", .{@tagName(value)}),
            .optional => p("{?}", .{value}),
            else => p("{}", .{value}),
        },
    };
}

fn ofEnum(comptime fields: []const Type.EnumField) []const u8 {
    var usage: []const u8 = "{";
    inline for (fields[0 .. fields.len - 1]) |field| {
        usage = p("{s}{s},", .{ usage, field.name });
    }

    const last = fields[fields.len - 1];
    usage = p("{s}{s}}}", .{ usage, last.name });

    return usage;
}

fn ofStruct(comptime fields: []const Type.StructField) []const u8 {
    var usage: []const u8 = "";
    inline for (fields) |field| {
        usage = p("{s}{s}", .{ usage,  ofField(field) });
    }
    return usage;
}

fn ofType(comptime T: type) []const u8 {
    const I = @typeInfo(T);

    return switch (T) {
        bool => "bool", // TODO?: show string literals that cast to bool values
        []const u8 => "string",
        ?[]const u8 => "optional string",
        else => switch (I) {
            .int,
            .float,
            => @typeName(T),

            .@"enum" => |e| ofEnum(e.fields),
            else => internal.err("Cant show usage for arguments of type " ++ @typeName(T)),
        },
    };
}

fn ofField(comptime field: Type.StructField) []const u8 {
    const T = field.type;

    // special case
    // without this, we would print `flag: [--flag,--no-flag]`
    if (T == argparse.OptionalFlag) return p(" [--{0s},--no-{0s}]", .{ field.name });

    return p(" {s}({s}){s}", .{field.name, ofType(T), defaultValue(field) });
}

pub fn of(comptime T: type, comptime meta: argparse.Meta, comptime name: []const u8) []const u8 {
    // user-defined message
    if (meta.usage) |usage| {
        return usage;
    }

    // introspection of arguments
    const fields = internal.structFields(T);
    var usage: []const u8 = p("usage: {s} {s}", .{ name, ofStruct(fields) });

    // append description, if provided
    if (meta.description) |description| {
        usage = p("{s} -- {s}", .{ usage, description });
    }

    return usage;
}
