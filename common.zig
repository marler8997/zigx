const std = @import("std");
const x = @import("x.zig");
const common = @This();

pub const SocketReader = std.io.Reader(std.os.socket_t, std.os.RecvFromError, readSocket);

pub fn send(sock: std.os.socket_t, data: []const u8) !void {
    const sent = try x.writeSock(sock, data, 0);
    if (sent != data.len) {
        std.log.err("send {} only sent {}\n", .{data.len, sent});
        return error.DidNotSendAllData;
    }
}

pub const ConnectResult = struct {
    sock: std.os.socket_t,
    setup: x.ConnectSetup,
    pub fn reader(self: ConnectResult) SocketReader {
        return .{ .context = self.sock };
    }
    pub fn send(self: ConnectResult, data: []const u8) !void {
        try common.send(self.sock, data);
    }
};

pub fn connect(allocator: std.mem.Allocator) !ConnectResult {
    const display = x.getDisplay();

    var connection_buf: [1024]u8 = undefined;
    var connection_fixed_buf = std.heap.FixedBufferAllocator.init(&connection_buf);
    var connection = x.connect(connection_fixed_buf.allocator(), display) catch |err| {
        std.log.err("failed to connect to display '{s}': {s}", .{display, @errorName(err)});
        std.os.exit(0xff);
    };
    defer connection.deinit();

    {
        const auth_name = connection.authentication.getName();
        const auth_data = connection.authentication.getData();

        const len = x.connect_setup.getLen(@intCast(auth_name.len), @intCast(auth_data.len));
        var msg_buf: [1024]u8 = undefined;
        if(len > msg_buf.len)
            return error.SetupTooLarge;

        x.connect_setup.serialize(&msg_buf, 11, 0, .{ .ptr = auth_name.ptr, .len = @intCast(auth_name.len) }, .{ .ptr = auth_data.ptr, .len = @intCast(auth_data.len) });
        try send(connection.socket.?, msg_buf[0..len]);
    }
    
    const reader = SocketReader { .context = connection.socket.? };
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
            // TODO: Print error reason
            std.log.err("Authentication failed! not implemented", .{});
            return error.AuthenticationFailed;
        },
        .success => {
            // TODO: check version?
            std.log.debug("SUCCESS! version {}.{}", .{connect_setup_header.proto_major_ver, connect_setup_header.proto_minor_ver});
        },
        else => |status| {
            std.log.err("Error: expected 0, 1 or 2 as first byte of connect setup reply, but got {}", .{status});
            return error.MalformedXReply;
        }
    }

    const connect_setup = x.ConnectSetup {
        .buf = try allocator.allocWithOptions(u8, connect_setup_header.getReplyLen(), 4, null),
    };
    std.log.debug("connect setup reply is {} bytes", .{connect_setup.buf.len});
    try x.readFull(reader, connect_setup.buf);

    return ConnectResult{ .sock = connection.takeSocket(), .setup = connect_setup };
}

pub fn asReply(comptime T: type, msg_bytes: []align(4) u8) !*T {
    const generic_msg: *x.ServerMsg.Generic = @ptrCast(msg_bytes.ptr);
    if (generic_msg.kind != .reply) {
        std.log.err("expected reply but got {}", .{generic_msg});
        return error.UnexpectedReply;
    }
    return @alignCast(@ptrCast(generic_msg));
}

fn readSocket(sock: std.os.socket_t, buffer: []u8) !usize {
    return x.readSock(sock, buffer, 0);
}
