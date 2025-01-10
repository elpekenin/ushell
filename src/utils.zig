//! Utilities for user's QOL

const std = @import("std");
const Type = std.builtin.Type;

const internal = @import("internal.zig");

/// Find all items on `items` that start with `needle`.
/// Useful to implement tab completion
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
            else => internal.err("Invalid argument type: " ++ @typeName(items)),
        };

        if (std.mem.startsWith(u8, name, needle)) {
            buffer[n] = name;
            n += 1;
        }
    }

    return buffer[0..n];
}
