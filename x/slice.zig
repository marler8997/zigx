const std = @import("std");

pub fn Slice(comptime LenType: type, comptime Ptr: type) type { return struct {
    const Self = @This();
    const ptr_info = @typeInfo(Ptr).Pointer;
    pub const NativeSlice = @Type(std.builtin.Type {
        .Pointer = .{
            .size = .Slice,
            .is_const = ptr_info.is_const,
            .is_volatile = ptr_info.is_volatile,
            .alignment = ptr_info.alignment,
            .address_space = ptr_info.address_space,
            .child = ptr_info.child,
            .is_allowzero = ptr_info.is_allowzero,
            .sentinel = ptr_info.sentinel,
        },
    });

    ptr: Ptr,
    len: LenType,

    pub fn nativeSlice(self: @This()) NativeSlice {
        return self.ptr[0 .. self.len];
    }

    pub fn initComptime(comptime ct_slice: NativeSlice) @This() {
        return .{ .ptr = ct_slice.ptr, .len = @intCast(LenType, ct_slice.len) };
    }

    pub fn lenCast(self: @This(), comptime NewLenType: type) Slice(NewLenType, Ptr) {
        return .{ .ptr = self.ptr, .len = @intCast(NewLenType, self.len) };
    }

    pub usingnamespace switch (@typeInfo(Ptr).Pointer.child) {
        u8 => struct {
            pub fn format(
                self: Self,
                comptime fmt: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                _ = fmt; _ = options;
                try writer.writeAll(self.ptr[0 .. self.len]);
            }
        },
        else => struct {},
    };
};}
