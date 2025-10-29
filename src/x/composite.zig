const std = @import("std");

const x11 = @import("../x.zig");

pub const name: x11.Slice(u16, [*]const u8) = .initComptime("Composite");

pub const Opcode = enum(u8) {
    QueryVersion = 0,
    // RedirectWindow = 1,
    RedirectSubwindows = 2,
    // UnredirectWindow = 3,
    // UnredirectSubwindows = 4,
    // CreateRegionFromBorderClip = 5,

    /// new in version 0.2
    NameWindowPixmap = 6,

    /// new in version 0.3
    GetOverlayWindow = 7,
    ReleaseOverlayWindow = 8,
};

pub const UpdateType = enum(u8) {
    automatic = 0,
    manual = 1,
};

pub const request = struct {
    pub fn QueryVersion(
        sink: *x11.RequestSink,
        ext_opcode: u8,
        wanted_major_version: u32,
        wanted_minor_version: u32,
    ) error{WriteFailed}!void {
        const msg_len =
            2 // extension and command opcodes
            + 2 // request length
            + 4 // wanted major version
            + 4 // wanted minor version
        ;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @intFromEnum(Opcode.QueryVersion),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, wanted_major_version);
        try x11.writeInt(sink.writer, &offset, u32, wanted_minor_version);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn RedirectSubwindows(
        sink: *x11.RequestSink,
        ext_opcode: u8,
        window_id: u32,
        update_type: UpdateType,
    ) error{WriteFailed}!void {
        const msg_len =
            2 // extension and command opcodes
            + 2 // request length
            + 4 // window_id
            + 1 // update type
            + 3 // unused pad
        ;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @intFromEnum(Opcode.RedirectSubwindows),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, window_id);
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(update_type),
            0, // unused pad
            0, // unused pad
            0, // unused pad
        });
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn NameWindowPixmap(
        sink: *x11.RequestSink,
        ext_opcode: u8,
        window_id: u32,
        pixmap_id: u32,
    ) error{WriteFailed}!void {
        const msg_len =
            2 // extension and command opcodes
            + 2 // request length
            + 4 // window_id
            + 4 // pixmap ID
        ;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @intFromEnum(Opcode.NameWindowPixmap),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, window_id);
        try x11.writeInt(sink.writer, &offset, u32, pixmap_id);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn GetOverlayWindow(
        sink: *x11.RequestSink,
        ext_opcode: u8,
        window_id: u32,
    ) error{WriteFailed}!void {
        const msg_len =
            2 // extension and command opcodes
            + 2 // request length
            + 4 // window_id
        ;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @intFromEnum(Opcode.GetOverlayWindow),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, window_id);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn ReleaseOverlayWindow(
        sink: *x11.RequestSink,
        ext_opcode: u8,
        overlay_window_id: u32,
    ) error{WriteFailed}!void {
        const msg_len =
            2 // extension and command opcodes
            + 2 // request length
            + 4 // window_id
        ;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @intFromEnum(Opcode.ReleaseOverlayWindow),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, overlay_window_id);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }
};
