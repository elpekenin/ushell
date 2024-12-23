const std = @import("std");

const ushell = @import("../ushell.zig");

fn Entry(options: ushell.Options) type {
    return struct {
        const Self = @This();

        len: usize,
        line: [options.max_line_size]u8,

        pub fn copy(self: *Self, line: []const u8) void {
            @memset(&self.line, 0);

            for (0.., line) |i, char| {
                self.line[i] = char;
            } 

            self.len = line.len;
        }
    };
}

pub fn History(options: ushell.Options) type {
    const E = Entry(options);

    return struct {
        const Self = @This();

        entries: std.BoundedArray(E, options.max_history_size),

        pub fn new() Self {
            return Self{
                .entries = .{},
            };
        }

        pub fn len(self: *Self) usize {
            return self.entries.len;
        }

        pub fn pop(self: *Self) E {
            return self.entries.pop();
        }

        pub fn append(self: *Self, line: []const u8) void {
            // if filled, remove an item
            if (self.len() == options.max_history_size) {
                _ = self.entries.orderedRemove(0);
            }

            // should never fail, we free a slot (if needed) above
            const entry = self.entries.addOne() catch unreachable;
            entry.copy(line);
        }

        // since .get() returns a copy of the value (temporary, on stack),
        // instead of a reference to it, we *must* inline this function so that
        // the slice being returned is not a dangling pointer
        pub inline fn getLine(self: *Self, i: usize) []const u8 {
            const entry = self.entries.get(i);
            return entry.line[0..entry.len];
        }
    };
}
