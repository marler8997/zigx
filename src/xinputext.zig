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
    change_property = 57,
    get_property = 59,
};

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
                type: u32, // atom or AnyPropertyType
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
                x.writeIntNative(u32, buf + 12, args.type);
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
        type: u32, // atom or AnyPropertyType
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
        x.writeIntNative(u32, buf + 12, args.type);
        x.writeIntNative(u32, buf + 16, args.offset);
        x.writeIntNative(u32, buf + 20, args.len);
    }
    pub const Reply = extern struct {
        response_type: x.ReplyKind,
        unused_pad: u8,
        sequence: u16,
        word_len: u32,
        type: u32,
        bytes_after: u32,
        value_count: u32,
        format: u8,
        pad: [11]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(Reply) == 32);
    }
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
comptime {
    std.debug.assert(@sizeOf(DeviceInfo) == 8);
}

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
        try writer.print("Unknown length={} data={}", .{ self.length, std.fmt.fmtSliceHexUpper(bytes) });
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
        try writer.print("Key min={}, max={} count={}", .{ self.min_keycode, self.max_keycode, self.key_count });
    }
};
comptime {
    std.debug.assert(@sizeOf(KeyInfo) == 8);
}

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
comptime {
    std.debug.assert(@sizeOf(ButtonInfo) == 4);
}

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
        try writer.print(
            "Valuator axes={}, mode=0x{x}, motion_buf_size={}",
            .{ self.number_of_axes, self.mode, self.motion_buffer_size },
        );
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
            @intFromEnum(InputClassId.key) => return TaggedUnion{ .key = @ptrCast(self.ptr) },
            @intFromEnum(InputClassId.button) => return TaggedUnion{ .button = @ptrCast(self.ptr) },
            @intFromEnum(InputClassId.valuator) => return TaggedUnion{ .valuator = @ptrCast(self.ptr) },
            else => return TaggedUnion{ .unknown = @ptrCast(self.ptr) },
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
comptime {
    std.debug.assert(@sizeOf(ListInputDevicesReply) == 32);
}
