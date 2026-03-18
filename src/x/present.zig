/// Present extension - https://www.x.org/releases/current/doc/presentproto/present.txt
const std = @import("std");
const x11 = @import("../x.zig");

pub const name: x11.Slice(u16, [*]const u8) = .initComptime("Present");

pub const Opcode = enum(u8) {
    query_version = 0,
    pixmap = 1,
    notify_msc = 2,
    select_input = 3,
};

pub const EventType = enum(u16) {
    configure_notify = 0,
    complete_notify = 1,
    idle_notify = 2,
};

pub const EventMask = packed struct(u32) {
    configure_notify: bool = false,
    complete_notify: bool = false,
    idle_notify: bool = false,
    _padding: u29 = 0,
};

pub const CompleteKind = enum(u8) {
    pixmap = 0,
    notify_msc = 1,
};

pub const CompleteMode = enum(u8) {
    copy = 0,
    flip = 1,
    skip = 2,
    suboptimal_copy = 3, // version 1.2
};

pub fn queryVersion(
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
        @intFromEnum(Opcode.query_version),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    try x11.writeInt(sink.writer, &offset, u32, major_version);
    try x11.writeInt(sink.writer, &offset, u32, minor_version);
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

pub fn selectInput(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    eid: u32,
    window: x11.Window,
    event_mask: EventMask,
) error{WriteFailed}!void {
    const msg_len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // eid
        + 4 // window
        + 4 // event mask
    ;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(Opcode.select_input),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    try x11.writeInt(sink.writer, &offset, u32, eid);
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(window));
    try x11.writeInt(sink.writer, &offset, u32, @bitCast(event_mask));
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

pub fn presentPixmap(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    window: x11.Window,
    pixmap: x11.Pixmap,
    serial: u32,
    target_msc: u64,
    divisor: u64,
    remainder: u64,
) error{WriteFailed}!void {
    const msg_len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // window
        + 4 // pixmap
        + 4 // serial
        + 4 // valid (REGION, 0 = None)
        + 4 // update (REGION, 0 = None)
        + 2 // x_off
        + 2 // y_off
        + 4 // target_crtc (0 = None)
        + 4 // wait_fence (0 = None)
        + 4 // idle_fence (0 = None)
        + 4 // options
        + 4 // pad
        + 8 // target_msc
        + 8 // divisor
        + 8 // remainder
    ;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(Opcode.pixmap),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(window));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(pixmap));
    try x11.writeInt(sink.writer, &offset, u32, serial);
    try x11.writeInt(sink.writer, &offset, u32, 0); // valid = None
    try x11.writeInt(sink.writer, &offset, u32, 0); // update = None
    try x11.writeInt(sink.writer, &offset, i16, 0); // x_off
    try x11.writeInt(sink.writer, &offset, i16, 0); // y_off
    try x11.writeInt(sink.writer, &offset, u32, 0); // target_crtc = None
    try x11.writeInt(sink.writer, &offset, u32, 0); // wait_fence = None
    try x11.writeInt(sink.writer, &offset, u32, 0); // idle_fence = None
    try x11.writeInt(sink.writer, &offset, u32, 0); // options
    try x11.writeInt(sink.writer, &offset, u32, 0); // pad
    try x11.writeInt(sink.writer, &offset, u64, target_msc);
    try x11.writeInt(sink.writer, &offset, u64, divisor);
    try x11.writeInt(sink.writer, &offset, u64, remainder);
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}
