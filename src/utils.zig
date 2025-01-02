const std = @import("std");
const Type = std.builtin.Type;

pub inline fn findMatches(items: anytype, needle: []const u8) [][]const u8 {
    var n: usize = 0;
    var buffer: [items.len][]const u8 = undefined;

    inline for (items) |item| {
        const T = @TypeOf(item);
        const name = switch (T) {
            []const u8 => item,
            Type.EnumField,
            Type.UnionField,
            => item.name,
            else => {
                const msg = "Argument of type '" ++ @typeName(items) ++ "' not supported";
                @compileError(msg);
            },
        };

        if (std.mem.startsWith(u8, name, needle)) {
            buffer[n] = name;
            n += 1;
        }
    }

    return buffer[0..n];
}
