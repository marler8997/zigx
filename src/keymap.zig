const std = @import("std");
const posix = std.posix;
const x11 = @import("x.zig");
const log = std.log.scoped(.x11);

fn sendOne(sock: std.posix.socket_t, sequence: *u16, data: []const u8) !void {
    const sent = try x11.writeSock(sock, data, 0);
    if (sent != data.len) {
        std.log.err("send {} only sent {}\n", .{ data.len, sent });
        return error.DidNotSendAllData;
    }
    sequence.* +%= 1;
}
fn readSocket(sock: posix.socket_t, buffer: []u8) !usize {
    return x11.readSock(sock, buffer, 0);
}
pub const SocketReader = std.io.Reader(posix.socket_t, posix.RecvFromError, readSocket);

pub const Reply = struct {
    keycode_count: u8,
    syms_per_code: u8,
    syms: []u32,

    pub fn deinit(self: Reply, allocator: std.mem.Allocator) void {
        allocator.free(self.syms);
    }
};
// TODO: use a generic X connection rather than sock
// request the keymap from the server.
// this function sends a messages and expects a reply to that message so this must
// be done before registering for any asynchronouse events from the server.
pub fn request(
    allocator: std.mem.Allocator,
    sock: posix.socket_t,
    sequence: *u16,
    fixed: x11.ConnectSetup.Fixed,
) !Reply {
    const keycode_count: u8 = fixed.max_keycode - fixed.min_keycode + 1;

    {
        var msg: [x11.get_keyboard_mapping.len]u8 = undefined;
        x11.get_keyboard_mapping.serialize(&msg, fixed.min_keycode, keycode_count);
        try sendOne(sock, sequence, &msg);
    }

    var header: [32]u8 align(4) = undefined;
    try x11.readFull(SocketReader{ .context = sock }, &header);

    {
        const generic: *x11.ServerMsg.Generic = @ptrCast(&header);
        if (generic.kind != .reply) {
            std.log.err("GetKeyboardMapping failed, expected 'reply' but got '{}': {}", .{
                generic.kind,
                generic,
            });
            return error.UnexpectedXServerReply;
        }
    }

    const reply: *x11.ServerMsg.GetKeyboardMapping = @ptrCast(&header);
    const syms_len = x11.readIntNative(u32, header[4..]);
    std.debug.assert(@as(usize, reply.syms_per_code) * @as(usize, keycode_count) == syms_len);

    const syms = try allocator.alloc(u32, syms_len);
    errdefer allocator.free(syms);

    try x11.readFull(SocketReader{ .context = sock }, @as([*]u8, @ptrCast(syms.ptr))[0 .. syms_len * 4]);

    return Reply{
        .keycode_count = keycode_count,
        .syms_per_code = reply.syms_per_code,
        .syms = syms,
    };
}

pub const Full = struct {
    array: [248][4]x11.charset.Combined,
    pub fn initVoid() Full {
        var result: Full = undefined;
        for (&result.array) |*entry_ref| {
            // TODO: initialize to VoidSymbol instead of 0
            entry_ref.* = [1]x11.charset.Combined{@enumFromInt(0)} ** 4;
        }
        return result;
    }

    pub const LoadError = error{
        MinKeycodeTooSmall,
        KeycodeCountTooBig,
        KeyMap0SymsPerCode,
    };
    pub fn load(self: *Full, min_keycode: u8, reply: Reply) LoadError!void {
        if (min_keycode < 8) {
            log.err("keymap min_keycode {} is too small", .{min_keycode});
            return error.MinKeycodeTooSmall;
        }
        if (reply.keycode_count > 248) {
            log.err("keymap has too many keycodes {}", .{reply.keycode_count});
            return error.KeycodeCountTooBig;
        }
        if (reply.syms_per_code == 0) return error.KeyMap0SymsPerCode;

        log.info("Keymap: syms_per_code={} total_syms={}", .{ reply.syms_per_code, reply.syms.len });
        var keycode_index: usize = 0;
        var sym_offset: usize = 0;
        while (keycode_index < reply.keycode_count) : (keycode_index += 1) {
            const keycode: u8 = @intCast(min_keycode + keycode_index);
            self.array[keycode - 8] = keymapEntrySyms(
                reply.syms_per_code,
                reply.syms[sym_offset..],
            );
            sym_offset += reply.syms_per_code;
        }
    }
    pub fn getKeysym(self: Full, keycode: u8, mod: x11.KeycodeMod) error{KeycodeTooSmall}!x11.charset.Combined {
        if (keycode < 8) return error.KeycodeTooSmall;
        return self.array[keycode - 8][@intFromEnum(mod)];
    }
};

pub fn keymapEntrySyms(syms_per_code: u8, syms: []u32) [4]x11.charset.Combined {
    std.debug.assert(syms.len >= syms_per_code);
    switch (syms_per_code) {
        0 => @panic("keymap syms_per_code can't be 0"),
        1 => @panic("todo"),
        2 => @panic("todo"),
        3 => @panic("todo"),
        4...255 => return [4]x11.charset.Combined{
            @enumFromInt(syms[0] & 0xffff),
            @enumFromInt(syms[1] & 0xffff),
            @enumFromInt(syms[2] & 0xffff),
            @enumFromInt(syms[3] & 0xffff),
        },
    }
}
