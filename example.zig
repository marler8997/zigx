const std = @import("std");
const x = @import("./x.zig");
const common = @import("common.zig");
const Memfd = x.Memfd;
const CircularBuffer = x.CircularBuffer;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = &arena.allocator;

pub fn main() !u8 {
    const conn = try common.connect(allocator);
    defer std.os.shutdown(conn.sock, .both) catch {};

    const screen = blk: {
        const fixed = conn.setup.fixed();
        inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
            std.log.debug("{s}: {any}", .{field.name, @field(fixed, field.name)});
        }
        std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
        const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        std.log.debug("fmt list off={} limit={}", .{format_list_offset, format_list_limit});
        const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
        for (formats) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{i, format.depth, format.bits_per_pixel, format.scanline_pad});
        }
        var screen = conn.setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{field.name, @field(screen, field.name)});
        }
        break :blk screen;
    };

    // TODO: maybe need to call conn.setup.verify or something?

    const window_id = conn.setup.fixed().resource_id_base;
    {
        var msg_buf: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&msg_buf, .{
            .window_id = window_id,
            .parent_window_id = screen.root,
            .x = 0, .y = 0,
            .width = 400, .height = 400,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
//            .bg_pixmap = .copy_from_parent,
            .bg_pixel = 0xaabbccdd,
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
                  x.create_window.event_mask.key_press
                | x.create_window.event_mask.key_release
                | x.create_window.event_mask.button_press
                | x.create_window.event_mask.button_release
                | x.create_window.event_mask.enter_window
                | x.create_window.event_mask.leave_window
                | x.create_window.event_mask.pointer_motion
//                | x.create_window.event_mask.pointer_motion_hint WHAT THIS DO?
//                | x.create_window.event_mask.button1_motion  WHAT THIS DO?
//                | x.create_window.event_mask.button2_motion  WHAT THIS DO?
//                | x.create_window.event_mask.button3_motion  WHAT THIS DO?
//                | x.create_window.event_mask.button4_motion  WHAT THIS DO?
//                | x.create_window.event_mask.button5_motion  WHAT THIS DO?
//                | x.create_window.event_mask.button_motion  WHAT THIS DO?
                | x.create_window.event_mask.keymap_state
                | x.create_window.event_mask.exposure
                ,
//            .dont_propagate = 1,
        });
        try conn.send(msg_buf[0..len]);
    }

    const bg_gc_id = window_id + 1;
    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = bg_gc_id,
            .drawable_id = screen.root,
        }, .{
            .foreground = screen.black_pixel,
        });
        try conn.send(msg_buf[0..len]);
    }
    const fg_gc_id = window_id + 2;
    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = fg_gc_id,
            .drawable_id = screen.root,
        }, .{
            .background = screen.black_pixel,
            .foreground = 0xffaadd,
        });
        try conn.send(msg_buf[0..len]);
    }

    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, window_id);
        try conn.send(&msg);
    }

    const buf_memfd = try Memfd.init("CircularBuffer");
    // no need to deinit
    var buf = try CircularBuffer.initMinSize(buf_memfd, 500);
    std.log.info("circular buffer size is {}", .{buf.size});
    var buf_start: usize = 0;
    while (true) {
        {
            const reserved = buf.cursor - buf_start;
            const recv_buf = buf.nextWithLen(buf.size - reserved);
            if (recv_buf.len == 0) {
                std.log.err("buffer size {} not big enough!", .{buf.size});
                return 1;
            }
            const len = try std.os.recv(conn.sock, recv_buf, 0);
            if (len == 0) {
                std.log.info("X server connection closed", .{});
                return 0;
            }
            //std.log.info("buf start={} cursor={} recvlen={}", .{buf_start, buf.cursor, len});
            if (buf.scroll(len)) {
                buf_start -= buf.size;
            }
            //std.log.info("    start={} cursor={}", .{buf_start, buf.cursor});
        }
        while (true) {
            std.debug.assert(buf_start <= buf.cursor); // TODO: is this necessary?  will I still get an exception on the next line anyway?
            const data = buf.ptr[buf_start .. buf.cursor];
            const msg_len = x.parseMsgLen(@alignCast(4, data));
            if (msg_len == 0)
                break;
            buf_start += msg_len;
            switch (x.serverMsgTaggedUnion(@alignCast(4, data.ptr))) {
                .err => |msg| {
                    std.log.err("{}", .{msg});
                    return 1;
                },
                .reply => |msg| {
                    std.log.info("todo: handle a reply message {}", .{msg});
                    return error.TodoHandleReplyMessage;
                },
                .key_press => |msg| {
                    std.log.info("key_press: {}", .{msg.detail});
                },
                .key_release => |msg| {
                    std.log.info("key_release: {}", .{msg.detail});
                },
                .button_press => |msg| {
                    std.log.info("button_press: {}", .{msg});
                },
                .button_release => |msg| {
                    std.log.info("button_release: {}", .{msg});
                },
                .enter_notify => |msg| {
                    std.log.info("enter_window: {}", .{msg});
                },
                .leave_notify => |msg| {
                    std.log.info("leave_window: {}", .{msg});
                },
                .motion_notify => |msg| {
                    // too much logging
                    _ = msg;
                    //std.log.info("pointer_motion: {}", .{msg});
                },
                .keymap_notify => |msg| {
                    std.log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    try render(conn.sock, window_id, bg_gc_id, fg_gc_id);
                },
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
            }
        }
    }
}

fn render(sock: std.os.socket_t, drawable_id: u32, bg_gc_id: u32, fg_gc_id: u32) !void {
    {
        var msg: [x.poly_fill_rectangle.getLen(1)]u8 = undefined;
        x.poly_fill_rectangle.serialize(&msg, .{
            .drawable_id = drawable_id,
            .gc_id = bg_gc_id,
        }, &[_]x.Rectangle {
            .{ .x = 100, .y = 100, .width = 200, .height = 200 },
        });
        try common.send(sock, &msg);
    }
    {
        const text_literal: []const u8 = "Hello X!";
        const text = x.Slice(u8, [*]const u8) { .ptr = text_literal.ptr, .len = text_literal.len };
        var msg: [x.image_text8.getLen(text.len)]u8 = undefined;
        x.image_text8.serialize(&msg, .{
            .drawable_id = drawable_id,
            .gc_id = fg_gc_id,
            .x = 115, .y = 125,
            .text = text,
        });
        try common.send(sock, &msg);
    }
}
