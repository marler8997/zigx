const std = @import("std");
const xproto = @import("./xproto.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    std.debug.warn("\n", .{});

    //const display = "localhost:10.0";
    //const display = "127.0.0.1:10.0";
    //const display = "192.168.0.2:10.0";
    const display = "192.168.0.2:0.0";
    const parsed_display = try xproto.parseDisplay(display);

    const sock = try xproto.connect(&arena.allocator, parsed_display.hostSlice(display), null, parsed_display.display_num);
    try sendConnect(sock);

    var stack_buffer: [100]u8 = undefined;
    const buf : []u8 = &stack_buffer;
    const result = try std.os.recv(sock, buf, 0);
    if (result == 0) {
        std.debug.warn("connection dropped\n", .{});
        return error.ConnectionDropped;
    }
    std.debug.warn("got {} bytes\n", .{result});
    for (buf[0..result]) |b,i| {
        std.debug.warn("[{}] 0x{x}\n", .{i, b});
    }
    if (buf[0] == 0) {
        std.debug.warn("FAIL!", .{});
        if (result < 8) {
            std.debug.warn("Error: malformed response, is only {} bytes\n", .{result});
            return error.MalformedResponse;
        }
        const reason_len = buf[1];
        const major = xproto.readIntNative(u16, buf.ptr + 2);
        const minor = xproto.readIntNative(u16, buf.ptr + 2);
        // TODO: check major/minor version
        if (8 + reason_len > result) {
            std.debug.warn("Error: malformed response, expected at least {} bytes but got {}\n", .{8 + reason_len, result});
            return error.MalformedResponse;
        }
        const reason = buf[8 .. 8 + reason_len];
        std.debug.warn("Error: connection rejected (version {}.{}) {}\n", .{major, minor, reason});
        return error.Rejected;

    } else if (buf[0] == 2) {
        std.debug.warn("AUTHENTICATE!", .{});
    } else if (buf[0] == 1) {
        std.debug.warn("SUCCESS!", .{});
    }



}

fn sendConnect(sock: std.os.socket_t) !void {
     var msg: [100]u8 = undefined;
     const len = xproto.makeConnectSetupMessage(&msg, 11, 0, .{ .ptr = undefined, .len = 0 }, .{ .ptr = undefined, .len = 0 });
     try send(sock, msg[0..len]);
}

fn send(sock: std.os.socket_t, data: []const u8) !void {
    const sent = try std.os.send(sock, data, 0);
    if (sent != data.len) {
        std.debug.warn("Error: send {} only sent {}", .{data.len, sent});
        return error.DidNotSendAllData;
    }
}
