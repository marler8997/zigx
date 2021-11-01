const std = @import("std");
const xproto = @import("./xproto.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = &arena.allocator;

pub fn main() !void {
    const display = xproto.getDisplay();

    const sock = xproto.connect(display) catch |err| {
        std.log.err("failed to connect to display '{s}': {s}", .{display, @errorName(err)});
        std.os.exit(0xff);
    };
    defer xproto.disconnect(sock);

    {
        const len = comptime xproto.connect_setup.getLen(0, 0);
        var msg: [len]u8 = undefined;
        xproto.connect_setup.serialize(&msg, 11, 0, .{ .ptr = undefined, .len = 0 }, .{ .ptr = undefined, .len = 0 });
        try send(sock, &msg);
    }

    const reader = std.io.Reader(std.os.socket_t, std.os.RecvFromError, readSocket) { .context = sock };
    const connect_setup_header = try xproto.readConnectSetupHeader(reader, .{});
    switch (connect_setup_header.status) {
        .failed => {
            std.log.err("connect setup failed, version={}.{}, reason='{s}'", .{
                connect_setup_header.proto_major_ver,
                connect_setup_header.proto_minor_ver,
                connect_setup_header.readFailReason(reader),
            });
            std.os.exit(0xff);
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
            std.os.exit(0xff);
        }
    }

    const connect_setup = xproto.ConnectSetup {
        .buf = try allocator.allocWithOptions(u8, connect_setup_header.getReplyLen(), 4, null),
    };
    defer allocator.free(connect_setup.buf);
    std.log.debug("connect setup reply is {} bytes", .{connect_setup.buf.len});
    try xproto.readFull(reader, connect_setup.buf);

    const screen = blk: {
        const fixed = connect_setup.fixed();
        inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
            std.log.debug("{s}: {any}", .{field.name, @field(fixed, field.name)});
        }
        std.log.debug("vendor: {s}", .{try connect_setup.getVendorSlice(fixed.vendor_len)});
        const format_list_offset = xproto.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = xproto.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        std.log.debug("fmt list off={} limit={}", .{format_list_offset, format_list_limit});
        const formats = try connect_setup.getFormatList(format_list_offset, format_list_limit);
        for (formats) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{i, format.depth, format.bits_per_pixel, format.scanline_pad});
        }
        var screen = connect_setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{field.name, @field(screen, field.name)});
        }
        break :blk screen;
    };

    // TODO: maybe need to call connect_setup.verify or something?

    const window_id = connect_setup.fixed().resource_id_base;
    {
        var msg_buf: [xproto.create_window.max_len]u8 = undefined;
        const len = xproto.create_window.serialize(&msg_buf, .{
            .window_id = window_id,
            .parent_window_id = screen.root,
            .x = 0, .y = 0,
            .width = 400, .height = 200,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
//            .bg_pixmap = .copy_from_parent,
//            .bg_pixel = 0xaabbccdd,
//            //.border_pixmap =
//            .border_pixel = 0x01fa8ec9,
//            .bit_gravity = .north_west,
//            .win_gravity = .east,
//            .backing_store = .when_mapped,
//            .backing_planes = 0x1234,
//            .backing_pixel = 0xbbeeeeff,
//            .override_redirect = true,
//            .save_under = true,
            .event_mask =
                  xproto.create_window.event_mask.key_press
                | xproto.create_window.event_mask.key_release
                | xproto.create_window.event_mask.button_press
                | xproto.create_window.event_mask.button_release
                | xproto.create_window.event_mask.enter_window
                | xproto.create_window.event_mask.leave_window
                | xproto.create_window.event_mask.pointer_motion
//                | xproto.create_window.event_mask.pointer_motion_hint WHAT THIS DO?
//                | xproto.create_window.event_mask.button1_motion  WHAT THIS DO?
//                | xproto.create_window.event_mask.button2_motion  WHAT THIS DO?
//                | xproto.create_window.event_mask.button3_motion  WHAT THIS DO?
//                | xproto.create_window.event_mask.button4_motion  WHAT THIS DO?
//                | xproto.create_window.event_mask.button5_motion  WHAT THIS DO?
//                | xproto.create_window.event_mask.button_motion  WHAT THIS DO?
                | xproto.create_window.event_mask.keymap_state

                ,
//            .dont_propagate = 1,
        });
        try send(sock, msg_buf[0..len]);
    }
    {
        var msg: [xproto.map_window.len]u8 = undefined;
        xproto.map_window.serialize(&msg, window_id);
        try send(sock, &msg);
    }

    //var buf align(4): [500]u8 = undefined;
    var buf align(4) = [_]u8 {undefined} ** 500;
    var reply_reader = xproto.ReplyReader { .buf = &buf, .offset = 0, .limit = 0 };
    while (true) {
        const reply = try reply_reader.read(sock);
        _ = reply;
    //    for (buf[0 .. result.total_received]) |c, i| {
    //        std.log.debug("[{}] 0x{x} ({1})", .{i, c});
    //    }
        switch (@intToEnum(xproto.ReplyType, buf[0])) {
            .err => {
                const generic_error = @ptrCast(*xproto.ErrorReply, &buf);
                switch (generic_error.code) {
                    .length => std.log.debug("{}", .{@ptrCast(*xproto.ErrorReplyLength, generic_error)}),
                    else => std.log.debug("{}", .{generic_error}),
                }
            },
            .normal => {
                std.log.info("todo: handle a reply message", .{});
                std.os.exit(0xff);
            },
            .key_press => {
                const event = @ptrCast(*xproto.Event.KeyOrButton, &buf);
                std.log.info("key_press: {}", .{event.detail});
            },
            .key_release => {
                const event = @ptrCast(*xproto.Event.KeyOrButton, &buf);
                std.log.info("key_release: {}", .{event.detail});
            },
            .button_press => {
                const event = @ptrCast(*xproto.Event.KeyOrButton, &buf);
                std.log.info("button_press: {}", .{event});
            },
            .button_release => {
                const event = @ptrCast(*xproto.Event.KeyOrButton, &buf);
                std.log.info("button_release: {}", .{event});
            },
            .enter_notify => {
                const event = @ptrCast(*xproto.Event.Generic, &buf);
                std.log.info("enter_window: {}", .{event});
            },
            .leave_notify => {
                const event = @ptrCast(*xproto.Event.Generic, &buf);
                std.log.info("leave_window: {}", .{event});
            },
            .motion_notify => {
                // too much logging
                //const event = @ptrCast(*xproto.Event.Generic, &buf);
                //std.log.info("pointer_motion: {}", .{event});
            },
            .keymap_notify => {
                const event = @ptrCast(*xproto.Event, &buf);
                std.log.info("keymap_state: {}", .{event});
            },
            else => {
                const event = @ptrCast(*xproto.Event, &buf);
                std.log.info("todo: handle event {}", .{event});
                std.os.exit(0xff);
            },
        }
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
