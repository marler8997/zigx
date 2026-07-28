pub const Slice = @import("sliceatleast16.zig").Slice;
pub const SliceWithMaxLen = @import("sliceatleast16.zig").SliceWithMaxLen;

pub fn NonExhaustive(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .@"enum" => |info| info,
        else => |info| @compileError("expected an Enum type but got a(n) " ++ @tagName(info)),
    };
    std.debug.assert(info.is_exhaustive);
    var names: [info.fields.len][]const u8 = undefined;
    var values: [info.fields.len]info.tag_type = undefined;
    for (&names, &values, info.fields) |*name, *value, field| {
        name.* = field.name;
        value.* = field.value;
    }
    return @Enum(info.tag_type, .nonexhaustive, &names, &values);
}

pub fn ArrayPointer(comptime T: type) type {
    const err = "ArrayPointer not implemented for " ++ @typeName(T);
    return switch (@typeInfo(T)) {
        .pointer => |info| {
            switch (info.size) {
                .one => switch (@typeInfo(info.child)) {
                    .Array => |array_info| @Pointer(
                        .many,
                        .{
                            .@"const" = true,
                        },
                        array_info.child,
                        array_info.sentinel,
                    ),
                    else => @compileError(err),
                },
                .slice => @Pointer(
                    .many,
                    .{
                        .@"const" = info.is_const,
                        .@"volatile" = info.is_volatile,
                        .@"align" = info.alignment,
                        .@"addrspace" = info.address_space,
                        .@"allowzero" = info.is_allowzero,
                    },
                    info.child,
                    info.sentinel_ptr,
                ),
                else => @compileError(err),
            }
        },
        else => @compileError(err),
    };
}

const std = @import("std");
