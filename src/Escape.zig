//! ASCII escape sequences
//!
//! Gathered from https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797

const ushell = @import("ushell.zig");

pub const Clear = "\x1b[2J";

pub fn styleFor(style: ushell.TextStyle) []const u8 {
    // TODO: implement background and mode support
    return switch (style.foreground) {
        .black => "\x1b[0;30m",
        .red => "\x1b[0;31m",
        .green => "\x1b[0;32m",
        .yellow => "\x1b[0;33m",
        .blue => "\x1b[0;34m",
        .magenta => "\x1b[0;35m",
        .cyan => "\x1b[0;36m",
        .white => "\x1b[0;37m",
        .default => "\x1b[0;39m",
        .reset => "\x1b[0;0m",
    };
}
