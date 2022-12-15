/// https://www.x.org/releases/current/doc/renderproto/renderproto.txt
const std = @import("std");

const x = @import("x.zig");

pub const ExtOpcode = enum(u8) {
    query_version = 0,
};

pub const query_version = struct {
    pub const len =
              2 // extension and command opcodes
            + 2 // request length
            + 4 // client major version
            + 4 // client minor version
    ;
    pub const Args = struct {
        major_version: u32,
        minor_version: u32,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) void {
        buf[0] = ext_opcode;
        buf[1] = @enumToInt(ExtOpcode.query_version);
        std.debug.assert(len & 0x3 == 0);
        x.writeIntNative(u16, buf + 2, len >> 2);
        x.writeIntNative(u32, buf + 4, args.major_version);
        x.writeIntNative(u32, buf + 8, args.minor_version);
    }
    pub const Reply = extern struct {
        response_type: x.ReplyKind,
        unused_pad: u8,
        sequence: u16,
        word_len: u32,
        major_version: u32,
        minor_version: u32,
        reserved: [15]u8,
    };
    comptime { std.debug.assert(@sizeOf(Reply) == 32); }
};
