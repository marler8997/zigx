const std = @import("std");

pub fn Slice(comptime LenType: type, comptime Ptr: type) type {
    return struct {
        const Self = @This();
        const ptr_info = @typeInfo(Ptr).pointer;
        pub const NativeSlice = @Type(std.builtin.Type{
            .pointer = .{
                .size = .slice,
                .is_const = ptr_info.is_const,
                .is_volatile = ptr_info.is_volatile,
                .alignment = ptr_info.alignment,
                .address_space = ptr_info.address_space,
                .child = ptr_info.child,
                .is_allowzero = ptr_info.is_allowzero,
                .sentinel_ptr = ptr_info.sentinel_ptr,
            },
        });

        ptr: Ptr,
        len: LenType,

        pub fn nativeSlice(self: @This()) NativeSlice {
            return self.ptr[0..self.len];
        }

        pub fn initComptime(comptime ct_slice: NativeSlice) @This() {
            return .{ .ptr = ct_slice.ptr, .len = @intCast(ct_slice.len) };
        }

        pub fn lenCast(self: @This(), comptime NewLenType: type) Slice(NewLenType, Ptr) {
            return .{ .ptr = self.ptr, .len = @intCast(self.len) };
        }

        pub usingnamespace switch (@typeInfo(Ptr).pointer.child) {
            u8 => struct {
                pub fn format(
                    self: Self,
                    comptime fmt: []const u8,
                    options: std.fmt.FormatOptions,
                    writer: anytype,
                ) !void {
                    _ = fmt;
                    _ = options;
                    try writer.writeAll(self.ptr[0..self.len]);
                }
            },
            else => struct {},
        };
    };
}

pub fn SliceWithMaxLen(comptime LenType: type, comptime Ptr: type, comptime max_len_arg: LenType) type {
    return struct {
        pub const max_len = max_len_arg;
        pub const undefined_max_len: @This() = .{ .ptr = undefined, .len = max_len };

        const Self = @This();
        const ptr_info = @typeInfo(Ptr).pointer;
        pub const NativeSlice = @Type(std.builtin.Type{
            .pointer = .{
                .size = .slice,
                .is_const = ptr_info.is_const,
                .is_volatile = ptr_info.is_volatile,
                .alignment = ptr_info.alignment,
                .address_space = ptr_info.address_space,
                .child = ptr_info.child,
                .is_allowzero = ptr_info.is_allowzero,
                .sentinel_ptr = ptr_info.sentinel_ptr,
            },
        });

        ptr: Ptr,
        len: LenType,

        pub fn validateMaxLen(self: @This()) void {
            std.debug.assert(self.len <= max_len);
        }

        pub fn nativeSlice(self: @This()) NativeSlice {
            return self.ptr[0..self.len];
        }

        pub fn initComptime(comptime ct_slice: NativeSlice) @This() {
            std.debug.assert(ct_slice.len <= max_len);
            return .{ .ptr = ct_slice.ptr, .len = @intCast(ct_slice.len) };
        }

        pub fn lenCast(self: @This(), comptime NewLenType: type) Slice(NewLenType, Ptr) {
            return .{ .ptr = self.ptr, .len = @intCast(self.len) };
        }

        pub usingnamespace switch (@typeInfo(Ptr).pointer.child) {
            u8 => struct {
                pub fn format(
                    self: Self,
                    comptime fmt: []const u8,
                    options: std.fmt.FormatOptions,
                    writer: anytype,
                ) !void {
                    _ = fmt;
                    _ = options;
                    try writer.writeAll(self.ptr[0..self.len]);
                }
            },
            else => struct {},
        };
    };
}
