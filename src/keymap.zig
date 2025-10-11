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

pub const Reply = struct {
    keycode_count: u8,
    syms_per_code: u8,
    syms: []u32,

    pub fn deinit(self: Reply, allocator: std.mem.Allocator) void {
        allocator.free(self.syms);
    }
};
// request the keymap from the server.
// this function sends a messages and expects a reply to that message so this must
// be done before registering for any asynchronouse events from the server.
pub fn request(
    allocator: std.mem.Allocator,
    sink: *x11.RequestSink,
    reader: *x11.Reader,
    fixed: *const x11.ConnectSetup.Fixed,
) !Reply {
    const keycode_count: u8 = fixed.max_keycode - fixed.min_keycode + 1;

    try sink.GetKeyboardMapping(fixed.min_keycode, keycode_count);
    const sequence = sink.sequence;
    try sink.writer.flush();

    const msg1 = try x11.read1(reader);
    if (msg1.kind != .Reply) std.debug.panic(
        "expected Reply but got {f}",
        .{msg1.readFmt(reader)},
    );
    const reply = try msg1.read2(.Reply, reader);
    if (reply.sequence != sequence) std.debug.panic(
        "expected sequence {} but got {f}",
        .{ sequence, reply.readFmt(reader) },
    );
    try reader.discardAll(24);
    const syms = try allocator.alloc(u32, reply.word_count);
    errdefer allocator.free(syms);
    try reader.readSliceAll(@as([*]u8, @ptrCast(syms.ptr))[0 .. syms.len * 4]);
    return .{
        .keycode_count = keycode_count,
        .syms_per_code = reply.flexible,
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
