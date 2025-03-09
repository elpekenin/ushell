const std = @import("std");

const ushell = @import("ushell.zig");

fn Entry(options: ushell.Options) type {
    return struct {
        const Self = @This();

        line: [options.max_line_size + 1]u8,

        pub fn copy(self: *Self, line: []const u8) void {
            @memset(&self.line, 0);
            for (0.., line) |i, char| {
                self.line[i] = char;
            }
            self.line[line.len] = 0;
        }
    };
}

pub fn History(options: ushell.Options) type {
    const E = Entry(options);

    return struct {
        const Self = @This();

        offset: usize,
        entries: std.BoundedArray(E, options.max_history_size),

        pub fn new() Self {
            return Self{
                .offset = 0,
                .entries = .{},
            };
        }

        pub fn len(self: *Self) usize {
            return self.entries.len;
        }

        pub fn pop(self: *Self) ?E {
            return self.entries.pop();
        }

        pub fn append(self: *Self, line: []const u8) void {
            // if filled, remove an item
            if (self.len() == options.max_history_size) {
                _ = self.entries.orderedRemove(0);
                self.offset += 1;
            }

            // should never fail, we free a slot (if needed) above
            const entry = self.entries.addOne() catch unreachable;
            entry.copy(line);
        }

        // since .get() returns a copy of the value (temporary, on stack),
        // instead of a reference to it, we *must* inline this function so that
        // the slice being returned is not a dangling pointer
        pub inline fn getLine(self: *Self, i: usize) ![]const u8 {
            if (i < self.offset or self.offset + self.len() <= i) return error.LineNotFound;

            const entry = self.entries.get(i - self.offset);
            return std.mem.sliceTo(&entry.line, 0);
        }
    };
}
