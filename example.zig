const std = @import("std");
const xproto = @import("./xproto.zig");

//var msg_buffer : [5000]u8 = undefined;

pub fn main() !void {
    //var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    //var allocator = arena.allocator;
    const allocator = std.heap.page_allocator;

    //const display = "localhost:10.0";
    //const display = "127.0.0.1:10.0";
    //const display = "192.168.0.2:10.0";
    const display = "192.168.0.2:0.0";
    const parsed_display = try xproto.parseDisplay(display);

    const sock = try xproto.connect(allocator, parsed_display.hostSlice(display), null, parsed_display.display_num);
    try sendConnect(sock);

    const reader = SocketReader { .sock = sock };

    const connect_setup = try xproto.readConnectSetup(allocator, reader, .{});
    std.log.debug("connect setup reply is {} bytes", .{connect_setup.buf.len});
    //for (connect_setup.buf) |c, i| {
    //    std.log.debug("[{}] 0x{}", .{i, c});
    //}

    {
        const header = connect_setup.header();
        switch (header.status) {
            .failed => {
                const reason_len = header.status_opt;
                std.debug.warn("Error: connect setup failed, version={}.{}, reason={}\n", .{
                    header.proto_major_ver, header.proto_minor_ver, connect_setup.failReason()
                });
                return error.XConnectSetupFailed;
            },
            .authenticate => {
                std.debug.warn("AUTHENTICATE! not implemented", .{});
                return error.NotImplemetned;
            },
            .success => {
                // TODO: check version?
                std.debug.warn("SUCCESS! version {}.{}\n", .{header.proto_major_ver, header.proto_minor_ver});
            },
            else => |status| {
                std.debug.warn("Error: expected 0, 1 or 2 as first byte of connect setup reply, but got {}", .{status});
                return error.XMalformedReply;
            }
        }
    }

    {
        const fixed = connect_setup.fixed();
        inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
            std.log.debug("{}: {}", .{field.name, @field(fixed, field.name)});
        }
        std.log.debug("vendor: {}", .{try connect_setup.getVendorSlice(fixed.vendor_len)});
        const format_list_offset = xproto.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = xproto.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        std.log.debug("fmt list off={} limit={}", .{format_list_offset, format_list_limit});
        const formats = try connect_setup.getFormatList(format_list_offset, format_list_limit);
        for (formats) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{i, format.depth, format.bits_per_pixel, format.scanline_pad});
        }
        var screen = connect_setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
            std.log.debug("SCREEN 0| {}: {}", .{field.name, @field(screen, field.name)});
        }

    }


//    const msg = xproto.recvMsg(sock, buf, .initial_setup) catch |e| switch (e) {
//        error.PartialXMsg => {
//            std.debug.warn("Error: buffer of size {} is not big enough, need {}\n", .{buf.len, xproto.getMsgLen(buf, .initial_setup)});
//            return error.NotImplemented;
//        },
//        else => return e,
//    };
//    std.debug.warn("got {} bytes (first msg is {} bytes)\n", .{msg.total_received, msg.msg_len});
//    for (buf[0..msg.msg_len]) |b,i| {
//        std.debug.warn("[{}] 0x{x}\n", .{i, b});
//    }
//
}


const SocketReader = struct {
    sock: std.os.socket_t,
    pub fn read(self: @This(), buf: []u8) !usize {
        return try std.os.recv(self.sock, buf, 0);
    }
};



fn sendConnect(sock: std.os.socket_t) !void {
     var msg: [100]u8 = undefined;
     const len = xproto.makeConnectSetupMessage(&msg, 11, 0, .{ .ptr = undefined, .len = 0 }, .{ .ptr = undefined, .len = 0 });
     try send(sock, msg[0..len]);
}

fn send(sock: std.os.socket_t, data: []const u8) !void {
    const sent = try std.os.send(sock, data, 0);
    if (sent != data.len) {
        std.debug.warn("Error: send {} only sent {}\n", .{data.len, sent});
        return error.DidNotSendAllData;
    }
}
