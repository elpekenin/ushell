//! Utilities *not* to be seen by users of the library
//!
//! This includes some meta-programming and tiny utility functions

const std = @import("std");
const Type = std.builtin.Type;

/// Bail out of compilation, adding this indirection before
/// calling `@compileError` is useful so that error message
/// looks like `@compilerError(msg)` instead of something like
/// `@compilerError("Invalid type " ++ @typeName(T))` which would
/// be less readable
pub fn err(comptime msg: []const u8) noreturn {
    @compileError(msg);
}

/// Get all the fields in an enum
pub fn enumFields(comptime T: type) []const Type.EnumField {
    return @typeInfo(T).@"enum".fields;
}

/// Get all the fields in a struct
pub fn structFields(comptime T: type) []const Type.StructField {
    return @typeInfo(T).@"struct".fields;
}

/// Get all the fields in a union
pub fn unionFields(comptime T: type) []const Type.UnionField {
    return @typeInfo(T).@"union".fields;
}
