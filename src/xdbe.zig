/// Protocol Specification: https://www.x.org/docs/XProtocol/proto.pdf
const std = @import("std");
const x11 = @import("x.zig");

pub const name: x11.Slice(u16, [*]const u8) = .initComptime("DOUBLE-BUFFER");

pub const ExtOpcode = enum(u8) {
    get_version = 0,
    allocate = 1,
    deallocate = 2,
    swap = 3,
    begin_idiom = 4,
    end_idiom = 5,
    visual_info = 6,
    get_attributes = 7,
};

pub const get_version = struct {
    pub const len =
        2 // extension and command opcodes
        + 2 // request length
        + 2 // wanted major/minor version
        + 2 // unused
    ;
    pub const Args = struct {
        ext_opcode: u8,
        wanted_major_version: u8,
        wanted_minor_version: u8,
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = args.ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.get_version);
        comptime {
            std.debug.assert(len & 0x3 == 0);
        }
        x11.writeIntNative(u16, buf + 2, len >> 2);
        buf[4] = args.wanted_major_version;
        buf[5] = args.wanted_minor_version;
        buf[6] = 0; // unused
        buf[7] = 0; // unused
    }

    comptime {
        std.debug.assert(@sizeOf(Reply) == 32);
    }
    pub const Reply = extern struct {
        response_type: x11.ReplyKind,
        unused: u8,
        sequence: u16,
        word_len: u32, // length in 4-byte words
        major_version: u8,
        minor_version: u8,
        unused_pad: [22]u8,
    };
};

// determines how the server will re-initialize a backbuffer
// that has just been swapped out from being the frontbuffer.
pub const SwapAction = enum(u8) {
    dontcare = 0,
    // initialize the backbuffer with the window background color
    background = 1,
    untouched = 2,
    copied = 3,
    _,
};

pub fn Allocate(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    window: x11.Window,
    backbuffer: x11.Drawable,
    swapaction: SwapAction,
) x11.Writer.Error!void {
    const msg_len = 16;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(ExtOpcode.allocate),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(window));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(backbuffer));
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        @intFromEnum(swapaction),
        0, // unused
        0, // unused
        0, // unused
    });
    std.debug.assert(msg_len == offset);
    sink.sequence +%= 1;
}

pub fn Deallocate(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    backbuffer: x11.Drawable,
) x11.Writer.Error!void {
    const msg_len = 8;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(ExtOpcode.deallocate),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(backbuffer));
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

pub const SwapInfo = struct {
    window: x11.Window,
    action: SwapAction,
};

pub fn Swap(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    swap_infos: x11.Slice(u32, [*]const SwapInfo),
) x11.Writer.Error!void {
    const msg_len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // swap info count
        + swap_infos.len * 8; // each SwapInfo is 8 bytes
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(ExtOpcode.swap),
    });
    try x11.writeInt(sink.writer, &offset, u16, @intCast(msg_len >> 2));
    try x11.writeInt(sink.writer, &offset, u32, swap_infos.len);
    for (swap_infos.nativeSlice()) |info| {
        try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(info.window));
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(info.action),
            0, // unused
            0, // unused
            0, // unused
        });
    }
    std.debug.assert((offset & 0x3) == 0);
    std.debug.assert(msg_len == offset);
    sink.sequence +%= 1;
}
