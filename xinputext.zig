const std = @import("std");

const x = @import("x.zig");

pub const ListInputDevicesReplyKind = enum(u8) { opcode = 2 };

pub const ExtOpcode = enum(u8) {
    get_extension_version = 1,
    list_input_devices = @intFromEnum(ListInputDevicesReplyKind.opcode),
    open_device = 3,
    close_device = 4,
    set_device_mode = 5,
    select_extension_event = 6,
    get_selected_extension_events = 7,
    change_dont_propagate_list = 8,
    get_device_dont_propagate_list = 9,
    get_device_motion_events = 10,
    change_keyboard_device = 11,
    change_pointer_device = 12,
    grab_device = 13,
    ungrab_device = 14,
    grab_device_key = 15,
    ungrab_device_key = 16,
    grab_device_button = 17,
    ungrab_device_button = 18,
    allow_device_events = 19,
    get_device_focus = 20,
    set_device_focus = 21,
    get_feedback_control = 22,
    change_feedback_control = 23,
    get_device_key_mapping = 24,
    change_device_key_mapping = 25,
    get_device_modifier_mapping = 26,
    select_events = 46,
    query_version = 47,
    change_property = 57,
    get_property = 59,
};

pub const ExtEventCode = enum(u8) {
    device_changed = 1,
    key_press = 2,
    key_release = 3,
    button_press = 4,
    button_release = 5,
    motion = 6,
    enter = 7,
    leave = 8,
    focus_in = 9,
    focus_out = 10,
    hierarchy = 11,
    property = 12,
    raw_key_press = 13,
    raw_key_release = 14,
    raw_button_press = 15,
    raw_button_release = 16,
    raw_motion = 17,
    touch_begin = 18,
    touch_update = 19,
    touch_end = 20,
    touch_ownership = 21,
    raw_touch_begin = 22,
    raw_touch_update = 23,
    raw_touch_end = 24,
    barrier_hit = 25,
    barrier_leave = 26,
    gesture_pinch_begin = 27,
    gesture_pinch_update = 28,
    gesture_pinch_end = 29,
    gesture_swipe_begin = 30,
    gesture_swipe_update = 31,
    gesture_swipe_end = 32,
};

// Abbreviated as `FP3232` in X Input extension protocol documentation.
pub const fixed_point_32_32 = extern struct {
    integral: i32,
    fractional: u32,
};

pub const ExtEvent = struct {
    pub const RawButtonPress = extern struct {
        response_type: x.GenericEventKind,
        /// The major opcode of the extension.
        ext_opcode: u8,
        sequence: u16,
        /// The length field specifies the number of 4-byte blocks after the
        /// initial 32 bytes. If length is 0, the event is 32 bytes long.
        word_len: u32, // length in 4-byte words
        event_opcode: u16,
        device_id: u16,
        timestamp: u32,

        detail: u32,
        source_device_id: u16,
        valuators_len: u16,
        pointer_event_flags: u32,
        // TODO: Handle the rest
        // unused2: u32, // padding
        // valuators_mask: u32,
        // axis_values: fixed_point_32_32,
        // axis_values_raw: fixed_point_32_32,
    };
};

pub const GenericExtensionEventTaggedUnion = union(enum) {
    unhandled: *align(4) x.ServerMsg.GenericExtensionEvent,
    raw_button_press: *align(4) ExtEvent.RawButtonPress,
};

pub fn genericExtensionEventTaggedUnion(msg_ptr: [*]align(4) u8) GenericExtensionEventTaggedUnion {
    // `msg_ptr[8]` points at the `event_opcode` part of the event.
    switch (@as(ExtEventCode, @enumFromInt(0x7f & msg_ptr[8]))) {
        .raw_button_press => return .{ .raw_button_press = @ptrCast(msg_ptr) },
        else => return .{ .unhandled = @ptrCast(msg_ptr) },
    }
}

pub const get_extension_version = struct {
    pub const non_list_len =
              2 // extension and command opcodes
            + 2 // request length
            + 2 // name length
            + 2 // unused
            ;
    pub fn getLen(name_len: u16) u16 {
        return non_list_len + std.mem.alignForward(u16, name_len, 4);
    }
    pub const max_len = non_list_len + 0xffff;
    pub const name_offset = 8;
    pub fn serialize(buf: [*]u8, input_ext_opcode: u8, name: x.Slice(u16, [*]const u8)) void {
        serializeNoNameCopy(buf, input_ext_opcode, name);
        @memcpy(buf[name_offset..][0..name.len], name.nativeSlice());
    }
    pub fn serializeNoNameCopy(buf: [*]u8, input_ext_opcode: u8, name: x.Slice(u16, [*]const u8)) void {
        buf[0] = input_ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.get_extension_version);
        const request_len = getLen(name.len);
        std.debug.assert(request_len & 0x3 == 0);
        x.writeIntNative(u16, buf + 2, request_len >> 2);
        x.writeIntNative(u32, buf + 4, name.len);
        buf[6] = 0; // unused
        buf[7] = 0; // unused
    }
    pub const Reply = extern struct {
        response_type: x.ReplyKind,
        unused_pad: u8,
        sequence: u16,
        word_len: u32,
        // The `xi_reply_type` field is listed in the XCB XML protocol definitions but I
        // don't see it in actual scenarios. It's also not part of the `libxi` ->
        // `xGetExtensionVersionReply` definition.
        //
        //xi_reply_type: u8,
        major_version: u16,
        minor_version: u16,
        present: bool,
        reserved: [19]u8,
    };
    comptime { std.debug.assert(@sizeOf(Reply) == 32); }
};

pub const query_version = struct {
    pub const len =
              2 // extension and command opcodes
            + 2 // request length
            + 2 // client major version
            + 2 // client minor version
    ;
    pub const Args = struct {
        major_version: u16,
        minor_version: u16,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.query_version);
        std.debug.assert(len & 0x3 == 0);
        x.writeIntNative(u16, buf + 2, len >> 2);
        x.writeIntNative(u16, buf + 4, args.major_version);
        x.writeIntNative(u16, buf + 6, args.minor_version);
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

pub const list_input_devices = struct {
    pub const len = 4;
    pub fn serialize(buf: [*]u8, input_ext_opcode: u8) void {
        buf[0] = input_ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.list_input_devices);
        x.writeIntNative(u16, buf + 2, len >> 2);
    }
};

pub const change_property = struct {
    pub const non_list_len =
          2 // extension and command opcodes
        + 2 // request length
        + 2 // device id
        + 2 // mode and format
        + 4 // property atom
        + 4 // type
        + 4 // value length
    ;
    pub const Mode = enum(u8) {
        replace = 0,
        prepend = 1,
        append = 2,
    };
    pub fn withFormat(comptime T: type) type {
        return struct {
            pub fn getLen(value_count: u16) u16 {
                return non_list_len + std.mem.alignForward(u16, value_count * @sizeOf(T), 4);
            }
            pub const Args = struct {
                device_id: u16,
                mode: Mode,
                value_format: u8 = @sizeOf(T),
                property: u32, // atom
                @"type": u32, // atom or AnyPropertyType
                values: x.Slice(u16, [*]const T),
            };
            pub fn serialize(buf: [*]u8, input_ext_opcode: u8, args: Args) void {
                buf[0] = input_ext_opcode;
                buf[1] = @intFromEnum(ExtOpcode.change_property);
                const request_len = getLen(args.values.len);
                std.debug.assert(request_len & 0x3 == 0);
                x.writeIntNative(u16, buf + 2, request_len >> 2);
                x.writeIntNative(u16, buf + 4, args.device_id);
                buf[6] = @intFromEnum(args.mode);
                buf[7] = @sizeOf(T) * 8;
                x.writeIntNative(u32, buf + 8, args.property);
                x.writeIntNative(u32, buf + 12, args.@"type");
                x.writeIntNative(u32, buf + 16, args.values.len);
                @memcpy(@as([*]align(1) T, @ptrCast(buf + 20))[0..args.values.len], args.values.nativeSlice());
            }
        };
    }
};

pub const get_property = struct {
    pub const len = 24;
    pub const Args = struct {
        device_id: u16,
        property: u32, // atom
        @"type": u32, // atom or AnyPropertyType
        offset: u32,
        len: u32,
        delete: bool,
    };
    pub fn serialize(buf: [*]u8, input_ext_opcode: u8, args: Args) void {
        buf[0] = input_ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.get_property);
        x.writeIntNative(u16, buf + 2, len >> 2);
        x.writeIntNative(u16, buf + 4, args.device_id);
        x.writeIntNative(u8, buf + 6, @intFromBool(args.delete));
        buf[7] = 0; // unused pad
        x.writeIntNative(u32, buf + 8, args.property);
        x.writeIntNative(u32, buf + 12, args.@"type");
        x.writeIntNative(u32, buf + 16, args.offset);
        x.writeIntNative(u32, buf + 20, args.len);
    }
    pub const Reply = extern struct {
        response_type: x.ReplyKind,
        unused_pad: u8,
        sequence: u16,
        word_len: u32,
        @"type": u32,
        bytes_after: u32,
        value_count: u32,
        format: u8,
        pad: [11]u8,
    };
    comptime { std.debug.assert(@sizeOf(Reply) == 32); }
};



pub const DeviceUse = enum(u8) {
    pointer = 0,
    keyboard = 1,
    extension = 2,
    extension_keyboard = 3,
    extension_pointer = 4,
};

pub const DeviceInfo = extern struct {
    device_type: u32,
    id: u8,
    class_count: u8,
    use: DeviceUse,
    unused: u8,
};
comptime { std.debug.assert(@sizeOf(DeviceInfo) == 8); }

pub const InputClassIdKeyKind = enum(u8) { id = 0 };
pub const InputClassIdButtonKind = enum(u8) { id = 1 };
pub const InputClassIdValuatorKind = enum(u8) { id = 2 };
pub const InputClassId = enum(u8) {
    key = @intFromEnum(InputClassIdKeyKind.id),
    button = @intFromEnum(InputClassIdButtonKind.id),
    valuator = @intFromEnum(InputClassIdValuatorKind.id),
};

pub fn Length(comptime T: type, comptime value: T) type {
    return enum(T) { value = value };
}

pub const UnknownInfo = extern struct {
    class_id: u8,
    length: u8,
    pub fn format(
        self: *const UnknownInfo,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const bytes = @as([*]const u8, @ptrCast(self))[0..self.length];
        try writer.print("Unknown length={} data={}", .{self.length, std.fmt.fmtSliceHexUpper(bytes)});
    }
};

pub const KeyInfo = extern struct {
    class_id: InputClassIdKeyKind,
    length: Length(u8, 8),
    min_keycode: u8,
    max_keycode: u8,
    key_count: u16,
    unused: u16,
    pub fn format(
        self: KeyInfo,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Key min={}, max={} count={}", .{self.min_keycode, self.max_keycode, self.key_count});
    }
};
comptime { std.debug.assert(@sizeOf(KeyInfo) == 8); }

pub const ButtonInfo = extern struct {
    class_id: InputClassIdButtonKind,
    length: Length(u8, 4),
    button_count: u16,
    pub fn format(
        self: ButtonInfo,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Button count={}", .{self.button_count});
    }
};
comptime { std.debug.assert(@sizeOf(ButtonInfo) == 4); }

pub const ValuatorInfo = extern struct {
    class_id: InputClassIdValuatorKind,
    length: u8,
    number_of_axes: u8,
    mode: u8,
    motion_buffer_size: u32,
    pub fn format(
        self: ValuatorInfo,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Valuator axes={}, mode=0x{x}, motion_buf_size={}", .{self.number_of_axes, self.mode, self.motion_buffer_size});
    }
};

pub const InputInfoIterator = struct {
    ptr: [*]align(4) const u8,

    const TaggedUnion = union(enum) {
        key: *align(4) const KeyInfo,
        button: *align(4) const ButtonInfo,
        valuator: *align(4) const ValuatorInfo,
        unknown: *align(4) const UnknownInfo,
        pub fn format(
            self: TaggedUnion,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            switch (self) {
                .key => |key| try key.format(fmt, options, writer),
                .button => |button| try button.format(fmt, options, writer),
                .valuator => |valuator| try valuator.format(fmt, options, writer),
                .unknown => |unknown| try unknown.format(fmt, options, writer),
            }
        }
    };

    pub fn front(self: InputInfoIterator) TaggedUnion {
        return switch (self.ptr[0]) {
            @intFromEnum(InputClassId.key     ) =>
                return TaggedUnion{ .key      = @ptrCast(self.ptr) },
            @intFromEnum(InputClassId.button  ) =>
                return TaggedUnion{ .button   = @ptrCast(self.ptr) },
            @intFromEnum(InputClassId.valuator) =>
                return TaggedUnion{ .valuator = @ptrCast(self.ptr) },
            else                              =>
                return TaggedUnion{ .unknown  = @ptrCast(self.ptr) },
        };
    }
    pub fn pop(self: *InputInfoIterator) void {
        self.ptr = @alignCast(self.ptr + self.ptr[1]);
    }
};

pub const ListInputDevicesReply = extern struct {
    response_type: x.ReplyKind,
    opcode: ListInputDevicesReplyKind,
    sequence: u16,
    word_len: u32, // length in 4-byte words
    device_count: u8,
    unused: [23]u8,

    pub fn deviceInfos(self: *const ListInputDevicesReply) x.Slice(u8, [*]const DeviceInfo) {
        return .{
            .ptr = @ptrFromInt(@intFromPtr(self) + @sizeOf(ListInputDevicesReply)),
            .len = self.device_count,
        };
    }
    pub fn inputInfoIterator(self: *const ListInputDevicesReply) InputInfoIterator {
        const addr = @intFromPtr(self) + @sizeOf(ListInputDevicesReply) + (self.device_count * @sizeOf(DeviceInfo));
        return InputInfoIterator{ .ptr = @ptrFromInt(addr) };
    }
    pub fn findNames(self: *const ListInputDevicesReply) x.StringListIterator {
        var input_info_it = self.inputInfoIterator();
        for (self.deviceInfos().nativeSlice()) |*device| {
            var info_index: u8 = 0;
            while (info_index < device.class_count) : (info_index += 1) {
                input_info_it.pop();
            }
        }
        const offset = @intFromPtr(input_info_it.ptr) - @intFromPtr(self);
        return .{
            .mem = input_info_it.ptr[0 .. 32 + (4 * self.word_len - offset)],
            .left = self.device_count,
        };
    }
};
comptime { std.debug.assert(@sizeOf(ListInputDevicesReply) == 32); }

pub const event = struct {
    pub const device_changed: u32 = (1 << 1);
    pub const key_press: u32 = (1 << 2);
    pub const key_release: u32 = (1 << 3);
    pub const button_press: u32 = (1 << 4);
    pub const button_release: u32 = (1 << 5);
    pub const motion: u32 = (1 << 6);
    pub const enter: u32 = (1 << 7);
    pub const leave: u32 = (1 << 8);
    pub const focus_in: u32 = (1 << 9);
    pub const focus_out: u32 = (1 << 10);
    pub const hierarchy: u32 = (1 << 11);
    pub const property: u32 = (1 << 12);
    // Events (v2.1)
    pub const raw_key_press: u32 = (1 << 13);
    pub const raw_key_release: u32 = (1 << 14);
    pub const raw_button_press: u32 = (1 << 15);
    pub const raw_button_release: u32 = (1 << 16);
    pub const raw_motion: u32 = (1 << 17);
    // Events (v2.2)
    pub const touch_begin: u32 = (1 << 18);
    pub const touch_update: u32 = (1 << 19);
    pub const touch_end: u32 = (1 << 20);
    pub const touch_ownership: u32 = (1 << 21);
    pub const raw_touch_begin: u32 = (1 << 22);
    pub const raw_touch_update: u32 = (1 << 23);
    pub const raw_touch_end: u32 = (1 << 24);
    // Events (v2.3)
    pub const barrier_hit: u32 = (1 << 25);
    pub const barrier_leave: u32 = (1 << 26);
};

pub const Device = enum(u16) {
    all = 0,
    all_master = 1,
};

pub const EventMask = struct {
    device_id: x.NonExhaustive(Device),
    /// Bit mask made up of `x.inputext.event.*` constants that you're interested in.
    /// ex. `x.inputext.event.raw_button_press | x.inputext.event.raw_key_release`
    mask: u32,
};

/// Specify which X Input events this window is interested in.
pub const select_events = struct {
    const size_of_event_mask_over_the_wire =
          2 // device_id
        + 2 // mask_len
        + 4 // mask
    ;
    comptime { std.debug.assert(size_of_event_mask_over_the_wire == 8); }

    pub const non_option_len =
              2 // extension and command opcodes
              + 2 // request length
              + 4 // window_id
              + 2 // num_mask
              + 2 // padding
    ;
    comptime { std.debug.assert(non_option_len == 12); }

    pub fn getLen(num_masks: u16) u16 {
        return non_option_len +
            (size_of_event_mask_over_the_wire * num_masks);
    }

    pub const Args = struct {
        window_id: u32,
        masks: []EventMask,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) u16 {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.select_events);
        const calculated_length = getLen(@as(u16, @intCast(args.masks.len)));
        x.writeIntNative(u16, buf + 2, calculated_length >> 2);
        x.writeIntNative(u32, buf + 4, args.window_id);
        x.writeIntNative(u16, buf + 8, @as(u16, @intCast(args.masks.len)));
        // 2 bytes of padding

        var current_request_len: u16 = non_option_len;

        // Length of mask in 4 byte units. Since our masks are always u32, this is always 1.
        const mask_len: u16 = @sizeOf(u32) / 4;
        for (args.masks) |mask| {
            x.writeIntNative(u16, buf + current_request_len, @intFromEnum(mask.device_id));
            x.writeIntNative(u16, buf + current_request_len + 2, mask_len);
            x.writeIntNative(u32, buf + current_request_len + 4, mask.mask);

            current_request_len += size_of_event_mask_over_the_wire;
        }

        // Quick sanity check that are assembled length is the same as the length we calculated.
        std.debug.assert(current_request_len == calculated_length);

        return current_request_len;
    }
};
