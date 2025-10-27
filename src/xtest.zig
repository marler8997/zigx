const std = @import("std");

const x11 = @import("x.zig");

pub const name: x11.Slice(u16, [*]const u8) = .initComptime("XTEST");

pub const ExtOpcode = enum(u8) {
    get_version = 0,
    // compare_cursor = 1,
    fake_input = 2,
    // grab_control = 3,
};

pub const FakeEventType = enum(u8) {
    key_press = 2,
    key_release = 3,
    button_press = 4,
    button_release = 5,
    motion_notify = 6,
};

/// Whether the `x_position`/`y_position` fields are relative or absolute
pub const PositionType = enum(u8) {
    absolute = 0,
    relative = 1,
};

pub fn GetVersion(
    sink: *x11.RequestSink,
    named: struct {
        ext_opcode_base: u8,
        wanted_major_version: u8,
        wanted_minor_version: u16,
    },
) error{WriteFailed}!void {
    const msg_len =
        2 // extension and command opcodes
        + 2 // request length
        + 1 // wanted major version
        + 1 // unused
        + 2 // wanted minor version
    ;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        named.ext_opcode_base,
        @intFromEnum(ExtOpcode.get_version),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        named.wanted_major_version,
        0, // unused
    });
    try x11.writeInt(sink.writer, &offset, u16, named.wanted_minor_version);
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

/// Simulate input events (key presses, button presses, mouse motion).
/// Can also simulate raw device events if `device_id` is specified.
pub fn FakeInput(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    args: fake_input.Args,
) error{WriteFailed}!void {
    const msg_len =
        2 // extension and command opcodes
        + 2 // request length
        + 1 // fake event type
        + 1 // detail
        + 2 // unused
        + 4 // delay
        + 4 // root window ID for MotionNotify
        + 8 // unused
        + 2 // x position for MotionNotify
        + 2 // y position for MotionNotify
        + 1 // device id
        + 7 // unused
    ;
    std.debug.assert(msg_len & 3 == 0);
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(ExtOpcode.fake_input),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    switch (args) {
        .key_press, .button_press => |args_value| {
            try x11.writeAll(sink.writer, &offset, &[_]u8{
                @intFromEnum(args_value.event_type),
                args_value.detail,
                0, 0, // unused
            });
            try x11.writeInt(sink.writer, &offset, u32, args_value.delay_ms); // offset 8
            try x11.writeInt(sink.writer, &offset, u32, 0); // unused root window id (offset 12)
            try x11.writeInt(sink.writer, &offset, u64, 0); // unused (offset 16)
            try x11.writeInt(sink.writer, &offset, i16, 0); // unused x position (offset 24)
            try x11.writeInt(sink.writer, &offset, i16, 0); // unused y position (offset 26)
            try x11.writeAll(
                sink.writer,
                &offset,
                &[_]u8{ args_value.device_id orelse 0, 0, 0, 0, 0, 0, 0, 0 },
            );
        },
        .mouse_notify => |args_value| {
            try x11.writeAll(sink.writer, &offset, &[_]u8{
                @intFromEnum(args_value.event_type),
                @intFromEnum(args_value.detail),
                0, 0, // unused
            });
            try x11.writeInt(sink.writer, &offset, u32, args_value.delay_ms); // offset 8
            try x11.writeInt(sink.writer, &offset, u32, args_value.root_window_id); // unused root window id (offset 12)
            try x11.writeInt(sink.writer, &offset, u64, 0); // unused (offset 16)
            try x11.writeInt(sink.writer, &offset, i16, args_value.x_position); // offset 24
            try x11.writeInt(sink.writer, &offset, i16, args_value.y_position); // offset 26
            try x11.writeAll(
                sink.writer,
                &offset,
                &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
            );
        },
    }
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}
pub const fake_input = struct {
    /// Simulate a key or button press/release
    pub const KeyOrButtonPressArgs = struct {
        event_type: FakeEventType,
        detail: u8,
        delay_ms: u32,
        device_id: ?u8,
    };
    /// Simulate mouse motion
    ///
    /// Raw device motion events (using `device_id`) are not supported yet since we
    /// would also need to send the variable-length state of the axes
    pub const MouseNotifyArgs = struct {
        event_type: FakeEventType,
        detail: PositionType,
        delay_ms: u32,
        /// This field is the ID of the root window on which the new motion is to take
        /// place. If None (0) is specified, the root window of the screen the pointer is
        /// currently on is used instead. If this field is not a valid window, then a
        /// Window error occurs.
        root_window_id: u32,
        /// These fields indicate relative distance or absolute pointer coordinates,
        /// according to the setting of detail. If the specified coordinates are
        /// off-screen, the closest on-screen coordinates will be substituted.
        x_position: i16,
        y_position: i16,
        // device_id: ?u8,
    };
    pub const Args = union(enum) {
        key_press: KeyOrButtonPressArgs,
        button_press: KeyOrButtonPressArgs,
        mouse_notify: MouseNotifyArgs,
    };
};
