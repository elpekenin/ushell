const std = @import("std");
const p = std.fmt.comptimePrint;
const Type = std.builtin.Type;

fn defaultValue(field: Type.StructField) [:0]const u8 {
    if (field.default_value) |def| {
        const T = field.type;
        const I = @typeInfo(field.type);

        const ptr: *align(field.alignment) const T = @alignCast(@ptrCast(def));
        const val = ptr.*;

        return "=" ++ switch (T) {
            []const u8 => p("{s}", .{val}),
            ?[]const u8 => p("{?s}", .{val}),
            else => switch (I) {
                // eg: show "=foo" instead of "=main.EnumName.foo" (not even valid input for parser)
                .@"enum" => p("{s}", .{@tagName(val)}),
                .optional => p("{?}", .{val}),
                else => p("{}", .{val}),
            },
        };
    }

    return "";
}

fn ofEnum(e: Type.Enum) [:0]const u8 {
    const fields = e.fields;

    var usage: [:0]const u8 = "{";
    inline for (fields[0 .. fields.len - 1]) |field| {
        usage = p("{s}{s},", .{ usage, field.name });
    }

    const last = fields[fields.len - 1];
    usage = p("{s}{s}}}", .{ usage, last.name });

    return usage;
}

fn ofStruct(s: Type.Struct) [:0]const u8 {
    var usage: [:0]const u8 = "";
    inline for (s.fields) |field| {
        usage = p("{s} {s}({s}){s}", .{ usage, field.name, ofType(field.type), defaultValue(field) });
    }
    return usage;
}

fn ofUnion(u: Type.Union) [:0]const u8 {
    const fields = u.fields;

    var usage = "{";
    inline for (fields[0 .. fields.len - 1]) |field| {
        usage = p("{s}{s}({s}),", .{ usage, field.name, ofType(field.type) });
    }

    const last = fields[fields.len - 1];
    usage = p("{s}{s}({s})", .{ usage, last.name, ofType(last.type) });

    return usage;
}

fn ofType(T: type) [:0]const u8 {
    const I = @typeInfo(T);

    return switch (T) {
        // TODO?: show string literals that cast to bool values
        bool => "bool",
        []const u8 => "string",
        ?[]const u8 => "optional string",
        else => switch (I) {
            .int,
            .float,
            => @typeName(T),

            .@"enum" => |e| ofEnum(e),
            .@"struct" => |s| ofStruct(s),
            .@"union" => |u| ofUnion(u),
            else => {
                const msg = "Cant show usage for arguments of type " ++ @typeName(T);
                @compileError(msg);
            },
        },
    };
}

pub fn from(T: type, comptime name: []const u8) []const u8 {
    // user-defined message
    if (@hasDecl(T, "usage")) return T.usage;

    // introspection of arguments
    const I = @typeInfo(T);
    const spacing = switch (I) {
        .@"enum" => " ",
        else => "",
    };

    var usage: [:0]const u8 = p("usage: {s}{s}{s}", .{ name, spacing, ofType(T) });

    if (@hasDecl(T, "description")) {
        usage = p("{s} -- {s}", .{ usage, T.description });
    }

    return usage;
}
