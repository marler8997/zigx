const std = @import("std");

const x = @import("x.zig");

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

pub const get_version = struct {
    pub const len =
        2 // extension and command opcodes
        + 2 // request length
        + 1 // wanted major version
        + 1 // unused
        + 2 // wanted minor version
    ;
    pub const Args = struct {
        ext_opcode: u8,
        wanted_major_version: u8,
        wanted_minor_version: u16,
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = args.ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.get_version);
        comptime {
            std.debug.assert(len & 0x3 == 0);
        }
        x.writeIntNative(u16, buf + 2, len >> 2);
        buf[4] = args.wanted_major_version;
        buf[5] = 0; // unused
        x.writeIntNative(u16, buf + 6, args.wanted_minor_version);
    }

    comptime {
        std.debug.assert(@sizeOf(Reply) == 32);
    }
    pub const Reply = extern struct {
        response_type: x.ReplyKind,
        major_version: u8,
        sequence: u16,
        word_len: u32, // length in 4-byte words
        minor_version: u16,
        unused_pad: [22]u8,
    };
};

/// Simulate input events (key presses, button presses, mouse motion).
/// Can also simulate raw device events if `device_id` is specified.
pub const fake_input = struct {
    pub const len =
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
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.fake_input);
        x.writeIntNative(u16, buf + 2, len >> 2);

        switch (args) {
            .key_press, .button_press => |args_value| {
                buf[4] = @intFromEnum(args_value.event_type);
                buf[5] = args_value.detail;
                // unused
                x.writeIntNative(u16, buf + 6, 0);
                x.writeIntNative(u32, buf + 8, args_value.delay_ms);
                // unused root window ID
                x.writeIntNative(u32, buf + 12, 0);
                // unused
                x.writeIntNative(u64, buf + 16, 0);
                // unused x position
                x.writeIntNative(i16, buf + 24, 0);
                // unused y position
                x.writeIntNative(i16, buf + 26, 0);
                buf[28] = args_value.device_id orelse 0;
                // unused
                x.writeIntNative(u56, buf + 29, 0);
            },
            .mouse_notify => |args_value| {
                buf[4] = @intFromEnum(args_value.event_type);
                buf[5] = @intFromEnum(args_value.detail);
                // unused
                x.writeIntNative(u16, buf + 6, 0);
                x.writeIntNative(u32, buf + 8, args_value.delay_ms);
                x.writeIntNative(u32, buf + 12, args_value.root_window_id);
                // unused
                x.writeIntNative(u64, buf + 16, 0);
                x.writeIntNative(i16, buf + 24, args_value.x_position);
                x.writeIntNative(i16, buf + 26, args_value.y_position);
                // device ID is not supported yet
                buf[28] = 0;
                // unused
                x.writeIntNative(u56, buf + 29, 0);
            },
        }
    }
};
