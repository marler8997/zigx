/// XFixes extension - https://www.x.org/releases/current/doc/fixesproto/fixesproto.txt
pub const name: x11.Slice(u16, [*]const u8) = .initComptime("XFIXES");

pub const Region = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Region {
        return @enumFromInt(i);
    }
};

pub const Opcode = enum(u8) {
    QueryVersion = 0,
    // ChangeSaveSet = 1,
    // SelectSelectionInput = 2,
    // SelectCursorInput = 3,
    // GetCursorImage = 4,
    CreateRegion = 5,
    CreateRegionFromBitmap = 6,
    CreateRegionFromWindow = 7,
    CreateRegionFromGc = 8,
    CreateRegionFromPicture = 9,
    DestroyRegion = 10,
    SetRegion = 11,
    // CopyRegion = 12,
    // UnionRegion = 13,
    // IntersectRegion = 14,
    // SubtractRegion = 15,
    // InvertRegion = 16,
    // TranslateRegion = 17,
    // RegionExtents = 18,
    // FetchRegion = 19,
    // SetGcClipRegion = 20,
    SetWindowShapeRegion = 21,
    // SetPictureClipRegion = 22,
    // SetCursorName = 23,
    // GetCursorName = 24,
    // GetCursorImageAndName = 25,
    // ChangeCursor = 26,
    // ChangeCursorByName = 27,
    // ExpandRegion = 28,
    // HideCursor = 29,
    // ShowCursor = 30,
    // CreatePointerBarrier = 31,
    // DeletePointerBarrier = 32,
};

pub const request = struct {
    pub fn QueryVersion(
        sink: *x11.RequestSink,
        ext_opcode: u8,
        major_version: u32,
        minor_version: u32,
    ) error{WriteFailed}!void {
        const msg_len =
            2 // extension and command opcodes
            + 2 // request length
            + 4 // major version
            + 4 // minor version
        ;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @intFromEnum(Opcode.QueryVersion),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, major_version);
        try x11.writeInt(sink.writer, &offset, u32, minor_version);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn CreateRegion(
        sink: *x11.RequestSink,
        ext_opcode: u8,
        region: Region,
        rectangles: []const x11.Rectangle,
    ) error{WriteFailed}!void {
        const non_list_len: u16 =
            2 // extension and command opcodes
            + 2 // request length
            + 4 // region id
        ;
        const msg_len = non_list_len + @as(u16, @intCast(rectangles.len)) * @sizeOf(x11.Rectangle);
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @intFromEnum(Opcode.CreateRegion),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(region));
        for (rectangles) |rect| {
            try x11.writeInt(sink.writer, &offset, i16, rect.x);
            try x11.writeInt(sink.writer, &offset, i16, rect.y);
            try x11.writeInt(sink.writer, &offset, u16, rect.width);
            try x11.writeInt(sink.writer, &offset, u16, rect.height);
        }
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn DestroyRegion(
        sink: *x11.RequestSink,
        ext_opcode: u8,
        region: Region,
    ) error{WriteFailed}!void {
        const msg_len =
            2 // extension and command opcodes
            + 2 // request length
            + 4 // region id
        ;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @intFromEnum(Opcode.DestroyRegion),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(region));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    /// Set the shape of a window to a region.
    /// Use shape.Kind.input for input passthrough.
    /// Set region to .none to reset to default (rectangular) shape.
    pub fn SetWindowShapeRegion(
        sink: *x11.RequestSink,
        ext_opcode: u8,
        window_id: x11.Window,
        shape_kind: enum(u8) {
            bounding = 0,
            clip = 1,
            input = 2,
        },
        x_offset: i16,
        y_offset: i16,
        region: Region,
    ) error{WriteFailed}!void {
        const msg_len =
            2 // extension and command opcodes
            + 2 // request length
            + 4 // window id
            + 1 // shape kind
            + 3 // padding
            + 2 // x offset
            + 2 // y offset
            + 4 // region id
        ;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @intFromEnum(Opcode.SetWindowShapeRegion),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(window_id));
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(shape_kind),
            0, // padding
            0,
            0,
        });
        try x11.writeInt(sink.writer, &offset, i16, x_offset);
        try x11.writeInt(sink.writer, &offset, i16, y_offset);
        try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(region));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }
};

pub const stage3 = struct {
    pub const QueryVersion = extern struct {
        major: u32,
        minor: u32,
        unused: [16]u8,
    };
};

const std = @import("std");
const x11 = @import("../x.zig");
