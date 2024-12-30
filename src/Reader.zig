//! Tokenize user input

const std = @import("std");

const Self = @This();

pub const Token = union(enum) {
    char: u8,
    backspace,
    tab,
    newline,
    arrow: enum {
        up,
        down,
        left,
        right,
    },
};

// Aliases for convenience
const Backspace: Token = .backspace;
const Tab: Token = .tab;
const Newline: Token = .newline;
const Up: Token = .{ .arrow = .up };
const Down: Token = .{ .arrow = .down };
const Left: Token = .{ .arrow = .left };
const Right: Token = .{ .arrow = .right };

inner: std.io.AnyReader,

pub fn new(reader: std.io.AnyReader) Self {
    return Self{
        .inner = reader,
    };
}

fn maybeReadByte(self: *Self) !?u8 {
    return self.inner.readByte() catch |err| switch (err) {
        error.EndOfStream => return null, // nothing was read
        else => return err,
    };
}

fn readByte(self: *Self) !u8 {
    while (true) {
        if (try self.maybeReadByte()) |byte| {
            return byte;
        }
    }
}

pub fn next(self: *Self) !Token {
    const byte = try self.readByte();

    return switch (byte) {
        8 => Backspace,
        9 => Tab,
        10 => Newline,
        27 => {
            if (try self.readByte() != '[') {
                return error.InvalidEscapeSequence;
            }

            return switch (try self.readByte()) {
                'A' => Up,
                'B' => Down,
                'C' => Left,
                'D' => Right,
                else => return error.UnknownEscapeSequence,
            };
        },
        else => Token{ .char = byte },
    };
}
