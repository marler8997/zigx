const std = @import("std");

const x = @import("x.zig");

pub const ExtOpcode = enum(u8) {
    get_extension_version = 1,
    list_input_devices = 2,
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
};

pub const get_extension_version = struct {
    pub const non_list_len =
              2 // extension and command opcodes
            + 2 // request length
            + 2 // name length
            + 2 // unused
            ;
    pub fn getLen(name_len: u16) u16 {
        return @intCast(u16, non_list_len + std.mem.alignForward(name_len, 4));
    }
    pub const max_len = non_list_len + 0xffff;
    pub const name_offset = 8;
    pub fn serialize(buf: [*]u8, input_ext_opcode: u8, name: x.Slice(u16, [*]const u8)) void {
        serializeNoNameCopy(buf, input_ext_opcode, name);
        @memcpy(buf + name_offset, name.ptr, name.len);
    }
    pub fn serializeNoNameCopy(buf: [*]u8, input_ext_opcode: u8, name: x.Slice(u16, [*]const u8)) void {
        buf[0] = input_ext_opcode;
        buf[1] = @enumToInt(ExtOpcode.get_extension_version);
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
        buf[1] = @enumToInt(ExtOpcode.list_input_devices);
        x.writeIntNative(u16, buf + 2, len >> 2);
    }
};
