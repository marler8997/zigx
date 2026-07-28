pub const Slice = @import("slicebefore16.zig").Slice;
pub const SliceWithMaxLen = @import("slicebefore16.zig").SliceWithMaxLen;

pub fn NonExhaustive(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .@"enum" => |info| info,
        else => |info| @compileError("expected an Enum type but got a(n) " ++ @tagName(info)),
    };
    std.debug.assert(info.is_exhaustive);
    return @Type(std.builtin.Type{ .@"enum" = .{
        .tag_type = info.tag_type,
        .fields = info.fields,
        .decls = &.{},
        .is_exhaustive = false,
    } });
}

pub fn ArrayPointer(comptime T: type) type {
    const err = "ArrayPointer not implemented for " ++ @typeName(T);
    return switch (@typeInfo(T)) {
        .pointer => |info| {
            switch (info.size) {
                .one => switch (@typeInfo(info.child)) {
                    .Array => |array_info| @Type(std.builtin.Type{ .pointer = .{
                        .size = .Many,
                        .is_const = true,
                        .is_volatile = false,
                        .alignment = @alignOf(array_info.child),
                        .address_space = info.address_space,
                        .child = array_info.child,
                        .is_allowzero = false,
                        .sentinel = array_info.sentinel,
                    } }),
                    else => @compileError(err),
                },
                .slice => @Type(std.builtin.Type{ .pointer = .{
                    .size = .many,
                    .is_const = info.is_const,
                    .is_volatile = info.is_volatile,
                    .alignment = info.alignment,
                    .address_space = info.address_space,
                    .child = info.child,
                    .is_allowzero = info.is_allowzero,
                    .sentinel_ptr = info.sentinel_ptr,
                } }),
                else => @compileError(err),
            }
        },
        else => @compileError(err),
    };
}

const std = @import("std");
