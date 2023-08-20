const std = @import("std");
const os = std.os;
const x = @import("x.zig");

pub fn send(sock: std.os.socket_t, data: []const u8) !void {
    const sent = try x.writeSock(sock, data, 0);
    if (sent != data.len) {
        std.log.err("send {} only sent {}\n", .{data.len, sent});
        return error.DidNotSendAllData;
    }
}
fn readSocket(sock: os.socket_t, buffer: []u8) !usize {
    return x.readSock(sock, buffer, 0);
}
pub const SocketReader = std.io.Reader(os.socket_t, os.RecvFromError, readSocket);

pub const Keymap = struct {
    keycode_count: u8,
    syms_per_code: u8,
    syms: []u32,

    pub fn deinit(self: Keymap, allocator: std.mem.Allocator) void {
        allocator.free(self.syms);
    }
};
// TODO: use a generic X connection rather than sock
// request the keymap from the server.
// this function sends a messages and expects a reply to that message so this must
// be done before registering for any asynchronouse events from the server.
pub fn request(allocator: std.mem.Allocator, sock: os.socket_t, fixed: x.ConnectSetup.Fixed) !Keymap {
    const keycode_count: u8 = fixed.max_keycode - fixed.min_keycode + 1;

    {
        var msg: [x.get_keyboard_mapping.len]u8 = undefined;
        x.get_keyboard_mapping.serialize(&msg, fixed.min_keycode, keycode_count);
        try send(sock, &msg);
    }

    var header: [32]u8 align(4) = undefined;
    try x.readFull(SocketReader{ .context = sock }, &header);

    {
        const generic: *x.ServerMsg.Generic = @ptrCast(&header);
        if (generic.kind != .reply) {
            std.log.err("GetKeyboardMapping failed, expected 'reply' but got '{}': {}", .{
                generic.kind,
                generic,
            });
            return error.UnexpectedXServerReply;
        }
    }

    const reply: *x.ServerMsg.GetKeyboardMapping = @ptrCast(&header);
    const syms_len = x.readIntNative(u32, header[4..]);
    std.debug.assert(@as(usize, reply.syms_per_code) * @as(usize, keycode_count) == syms_len);

    const syms = try allocator.alloc(u32, syms_len);
    errdefer allocator.free(syms);

    try x.readFull(SocketReader{ .context = sock }, @as([*]u8, @ptrCast(syms.ptr))[0 .. syms_len * 4]);

    return Keymap{
        .keycode_count = keycode_count,
        .syms_per_code = reply.syms_per_code,
        .syms = syms,
    };
}
