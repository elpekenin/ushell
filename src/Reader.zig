//! Tokenize user input

// TODO: Handle some non-printable input (Control+Backspace for example) properly

const std = @import("std");

const control = std.ascii.control_code;

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

    fn c(b: u8) Token {
        return .{ .char = b };
    }

    // Aliases for convenience
    const up: Token = .{ .arrow = .up };
    const down: Token = .{ .arrow = .down };
    const left: Token = .{ .arrow = .left };
    const right: Token = .{ .arrow = .right };
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
        control.bs => .backspace,
        control.ht => .tab,
        control.lf => .newline,
        control.esc => {
            if (try self.readByte() != '[') {
                return error.InvalidEscapeSequence;
            }

            return switch (try self.readByte()) {
                'A' => .up,
                'B' => .down,
                'C' => .left,
                'D' => .right,
                else => return error.UnknownEscapeSequence,
            };
        },
        else => .c(byte),
    };
}
