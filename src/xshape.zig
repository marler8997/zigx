const std = @import("std");

const x = @import("x.zig");

pub const ExtOpcode = enum(u8) {
    query_version = 0,
    rectangles = 1,
    // mask = 2,
    // combine = 3,
    // offset = 4,
    // query_extents = 5,
    // select_input = 6,
    // input_selected = 7,
    // get_rectangles = 8,
};

pub const Kind = enum(u8) {
    bounding = 0,
    clip = 1,
    input = 2,
};

pub const Operation = enum(u8) {
    set = 0,
    @"union" = 1,
    intersect = 2,
    subtract = 3,
    invert = 4,
};

pub const Ordering = enum(u8) {
    unsorted = 0,
    y_sorted = 1,
    yx_sorted = 2,
    yx_banded = 3,
};

pub const query_version = struct {
    pub const len =
              2 // extension and command opcodes
            + 2 // request length
    ;
    pub fn serialize(buf: [*]u8, ext_opcode: u8) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.query_version);
        x.writeIntNative(u16, buf + 2, len >> 2);
    }
    pub const Reply = extern struct {
        response_type: x.ReplyKind,
        unused_pad: u8,
        sequence: u16,
        word_len: u32,
        major_version: u16,
        minor_version: u16,
        reserved: [20]u8,
    };
    comptime { std.debug.assert(@sizeOf(Reply) == 32); }
};


pub const rectangles = struct {
    pub const non_list_len =
              2 // extension and command opcodes
            + 2 // request length
            + 1 // operation
            + 1 // destination kind
            + 1 // ordering
            + 1 // unused
            + 4 // destination window
            + 2 // x offset
            + 2 // y offset
    ;
    pub fn getLen(number_of_rectangles: u16) u16 {
        return non_list_len + (@sizeOf(x.Rectangle) * number_of_rectangles);
    }
    pub const Args = struct {
        destination_window_id: u32,
        destination_kind: Kind,
        operation: Operation,
        x_offset: i16,
        y_offset: i16,
        ordering: Ordering,
        rectangles: []const x.Rectangle,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.rectangles);
        const len = getLen(@intCast(args.rectangles.len));
        x.writeIntNative(u16, buf + 2, len >> 2);
        buf[4] = @intFromEnum(args.operation);
        buf[5] = @intFromEnum(args.destination_kind);
        buf[6] = @intFromEnum( args.ordering);
        buf[7] = 0; // unused
        x.writeIntNative(u32, buf + 8, args.destination_window_id);
        x.writeIntNative(i16, buf + 12, args.x_offset);
        x.writeIntNative(i16, buf + 14, args.y_offset);
        var current_offset: u16 = non_list_len;
        for (args.rectangles) |rectangle| {
            x.writeIntNative(i16, buf + current_offset + 0, rectangle.x);
            x.writeIntNative(i16, buf + current_offset + 2, rectangle.y);
            x.writeIntNative(u16, buf + current_offset + 4, rectangle.width);
            x.writeIntNative(u16, buf + current_offset + 6, rectangle.height);
            current_offset += @sizeOf(x.Rectangle);
        }
    }
};
