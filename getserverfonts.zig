const std = @import("std");
const x = @import("./x.zig");
const Memfd = x.Memfd;
const CircularBuffer = x.CircularBuffer;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = &arena.allocator;

pub fn main() !u8 {
    main2() catch |err| switch (err) {
        //error.AlreadyReported => return 0xff,
        else => |e| return e,
    };
    return 0;
}
fn main2() !void {
    const display = x.getDisplay();

    const sock = x.connect(display) catch |err| {
        std.log.err("failed to connect to display '{s}': {s}", .{display, @errorName(err)});
        std.os.exit(0xff);
    };
    defer x.disconnect(sock);

    {
        const len = comptime x.connect_setup.getLen(0, 0);
        var msg: [len]u8 = undefined;
        x.connect_setup.serialize(&msg, 11, 0, .{ .ptr = undefined, .len = 0 }, .{ .ptr = undefined, .len = 0 });
        try send(sock, &msg);
    }
    
    const reader = std.io.Reader(std.os.socket_t, std.os.RecvFromError, readSocket) { .context = sock };
    const connect_setup_header = try x.readConnectSetupHeader(reader, .{});
    switch (connect_setup_header.status) {
        .failed => {
            std.log.err("connect setup failed, version={}.{}, reason='{s}'", .{
                connect_setup_header.proto_major_ver,
                connect_setup_header.proto_minor_ver,
                connect_setup_header.readFailReason(reader),
            });
            return error.ConnectSetupFailed;
        },
        .authenticate => {
            std.log.err("AUTHENTICATE! not implemented", .{});
            return error.NotImplemetned;
        },
        .success => {
            // TODO: check version?
            std.log.info("SUCCESS! version {}.{}", .{connect_setup_header.proto_major_ver, connect_setup_header.proto_minor_ver});
        },
        else => |status| {
            std.log.err("Error: expected 0, 1 or 2 as first byte of connect setup reply, but got {}", .{status});
            return error.MalformedXReply;
        }
    }

    const connect_setup = x.ConnectSetup {
        .buf = try allocator.allocWithOptions(u8, connect_setup_header.getReplyLen(), 4, null),
    };
    defer allocator.free(connect_setup.buf);
    std.log.debug("connect setup reply is {} bytes", .{connect_setup.buf.len});
    try x.readFull(reader, connect_setup.buf);

    {
        var msg: [x.get_font_path.len]u8 = undefined;
        x.get_font_path.serialize(&msg);
        try send(sock, &msg);
    }

    {
        const msg_bytes = try x.readOneMsgAlloc(allocator, reader);
        defer allocator.free(msg_bytes);
        const generic_msg = @ptrCast(*x.ServerMsg.Generic, msg_bytes.ptr);
        if (generic_msg.kind != .reply) {
            std.log.err("expected reply but got {}", .{generic_msg});
            return error.UnexpectedReply;
        }
        const msg = @ptrCast(*x.ServerMsg.GetFontPath, generic_msg);
        std.log.info("got msg of {} bytes: {}", .{msg_bytes.len, msg});
        const path = msg.getPath();
        std.log.info("path is {d}", .{path});
        std.log.info("path is '{s}'", .{path});
    }
    
}

fn readSocket(sock: std.os.socket_t, buffer: []u8) !usize {
    return std.os.recv(sock, buffer, 0);
}

fn send(sock: std.os.socket_t, data: []const u8) !void {
    const sent = try std.os.send(sock, data, 0);
    if (sent != data.len) {
        std.log.err("send {} only sent {}\n", .{data.len, sent});
        return error.DidNotSendAllData;
    }
}
