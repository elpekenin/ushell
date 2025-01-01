//! Tokenize user input

// TODO: Handle some non-printable input (Control+Backspace for example) properly

const std = @import("std");

const Ascii = @import("Ascii.zig");

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

    // Aliases for convenience
    const Backspace: Token = .backspace;
    const Tab: Token = .tab;
    const Newline: Token = .newline;
    const Up: Token = .{ .arrow = .up };
    const Down: Token = .{ .arrow = .down };
    const Left: Token = .{ .arrow = .left };
    const Right: Token = .{ .arrow = .right };
};

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
        Ascii.Backspace => Token.Backspace,
        Ascii.Tab => Token.Tab,
        Ascii.Newline => Token.Newline,
        Ascii.Escape => {
            if (try self.readByte() != '[') {
                return error.InvalidEscapeSequence;
            }

            return switch (try self.readByte()) {
                'A' => Token.Up,
                'B' => Token.Down,
                'C' => Token.Left,
                'D' => Token.Right,
                else => return error.UnknownEscapeSequence,
            };
        },
        else => Token{ .char = byte },
    };
}
