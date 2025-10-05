/// Protocol Specification: https://www.x.org/docs/XProtocol/proto.pdf
const std = @import("std");
const x = @import("x.zig");

pub const name = x.Slice(u16, [*]const u8).initComptime("DOUBLE-BUFFER");

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
        x.writeIntNative(u16, buf + 2, len >> 2);
        buf[4] = args.wanted_major_version;
        buf[5] = args.wanted_minor_version;
        buf[6] = 0; // unused
        buf[7] = 0; // unused
    }

    comptime {
        std.debug.assert(@sizeOf(Reply) == 32);
    }
    pub const Reply = extern struct {
        response_type: x.ReplyKind,
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

pub const allocate = struct {
    pub const len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // window
        + 4 // backbuffer
        + 1 // swapaction
        + 3 // pad
    ;
    pub const Args = struct {
        ext_opcode: u8,
        window: x.Window,
        backbuffer: x.Drawable,
        swapaction: SwapAction,
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = args.ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.allocate);
        comptime {
            std.debug.assert(len & 0x3 == 0);
        }
        x.writeIntNative(u16, buf + 2, len >> 2);
        x.writeIntNative(u32, buf + 4, @intFromEnum(args.window));
        x.writeIntNative(u32, buf + 8, @intFromEnum(args.backbuffer));
        buf[12] = @intFromEnum(args.swapaction);
        buf[13] = 0; // unused
        buf[14] = 0; // unused
        buf[15] = 0; // unused
    }
};

pub const deallocate = struct {
    pub const len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // backbuffer
    ;
    pub const Args = struct {
        ext_opcode: u8,
        backbuffer: x.Drawable,
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = args.ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.deallocate);
        comptime {
            std.debug.assert(len & 0x3 == 0);
        }
        x.writeIntNative(u16, buf + 2, len >> 2);
        x.writeIntNative(u32, buf + 4, @intFromEnum(args.backbuffer));
    }
};

pub const SwapInfo = struct {
    window: x.Window,
    action: SwapAction,
};

pub const swap = struct {
    pub const non_list_len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // swap info count
    ;
    pub fn getLen(swap_info_count: u32) u18 {
        return @intCast(non_list_len + (swap_info_count * 8));
    }
    pub const Args = struct {
        ext_opcode: u8,
    };
    pub fn serialize(buf: [*]u8, swap_infos: x.Slice(u32, [*]const SwapInfo), args: Args) void {
        buf[0] = args.ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.swap);
        x.writeIntNative(u32, buf + 4, swap_infos.len);

        var i: usize = non_list_len;
        for (swap_infos.nativeSlice()) |info| {
            x.writeIntNative(u32, buf + i + 0, @intFromEnum(info.window));
            buf[i + 4] = @intFromEnum(info.action);
            buf[i + 5] = 0; // unused
            buf[i + 6] = 0; // unused
            buf[i + 7] = 0; // unused
            i += 8;
        }
        std.debug.assert(i == getLen(swap_infos.len));
        std.debug.assert((i & 0x3) == 0);
        x.writeIntNative(u16, buf + 2, @intCast(i >> 2));
    }
};
