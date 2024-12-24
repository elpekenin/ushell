//! Show usage of a command or list all available ones

const std = @import("std");
const Type = std.builtin.Type;

const ushell = @import("../ushell.zig");
const Options = ushell.Options;

const utils = @import("../utils.zig");
const BuiltinCommand = utils.BuiltinCommand;

pub fn Help(UserCommand: type, options: Options) type {
    const Shell = ushell.Shell(UserCommand, options);

    return struct {
        fn defaultValue(shell: *Shell, field: Type.StructField) void {
            if (field.default_value) |def| {
                const ptr: *align(field.alignment) const field.type = @alignCast(@ptrCast(def));

                const I = @typeInfo(field.type);
                switch (I) {
                    // eg: show "=foo" instead of "=main.EnumName.foo" (not even valid input for parser)
                    .@"enum" => shell.print("={s}", .{@tagName(ptr.*)}),
                    else => shell.print("={}", .{ptr.*}),
                }
            }
        }

        fn enumUsage(shell: *Shell, e: Type.Enum) void {
            const fields = e.fields;

            shell.print("{{", .{});
            inline for (fields[0 .. fields.len - 1]) |field| {
                shell.print("{s},", .{field.name});
            }
            shell.print("{s}}}", .{fields[fields.len - 1].name});
        }

        fn structUsage(shell: *Shell, s: Type.Struct) void {
            inline for (s.fields) |field| {
                shell.print("{s}(", .{field.name});
                usage(shell, field.type);
                shell.print(")", .{});
                defaultValue(shell, field);
                shell.print(" ", .{});
            }
        }

        fn unionUsage(shell: *Shell, u: Type.Union) void {
            const fields = u.fields;

            shell.print("{{", .{});
            inline for (fields[0 .. fields.len - 1]) |field| {
                shell.print("{s}(", .{field.name});
                usage(shell, field.type);
                shell.print("),");
            }
            shell.print("{s}(", .{fields[fields.len - 1].name});
            usage(shell, fields[fields.len - 1].type);
            shell.print(")}}", .{});
        }

        fn usage(shell: *Shell, T: type) void {
            const I = @typeInfo(T);

            switch (I) {
                .bool, // TODO: Show string literals that cast to bool (?)
                .int,
                .float,
                => shell.print("{s}", .{@typeName(T)}),
                .@"enum" => |e| enumUsage(shell, e),
                .@"struct" => |s| structUsage(shell, s),
                .@"union" => |u| unionUsage(shell, u),
                else => {
                    const msg = "Showing usage for arguments of type '" ++ @typeName(T) ++ "' not supported at the moment.";
                    @compileError(msg);
                },
            }
        }

        fn command(shell: *Shell, name: []const u8, Inner: type) void {
            if (@hasDecl(Inner, "usage")) {
                shell.print("{s}", .{Inner.usage});
            } else {
                // default implementation: introspection of arguments
                shell.print("usage: {s} ", .{name});
                usage(shell, Inner);
            }
        }

        pub fn of(shell: *Shell, name: []const u8) void {
            const I = @typeInfo(UserCommand);

            inline for (I.@"union".fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    command(shell, field.name, field.type);
                    return;
                }
            }

            shell.unknown(name);
        }

        pub fn list(shell: *Shell) void {
            const B = @typeInfo(BuiltinCommand);
            const I = @typeInfo(UserCommand);

            shell.print("Available commands:", .{});
            inline for (B.@"enum".fields) |field| {
                shell.print("\n  * {s}", .{field.name});
            }

            inline for (I.@"union".fields) |field| {
                shell.print("\n  * {s}", .{field.name});
            }
        }
    };
}