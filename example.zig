const std = @import("std");
const x = @import("./x.zig");
const common = @import("common.zig");
const Memfd = x.Memfd;
const CircularBuffer = x.CircularBuffer;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = &arena.allocator;

pub fn main() !void {
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
            const len = try std.os.recv(conn.sock, buf.next(), 0);
            if (len == 0) {
                std.log.info("X server connection closed", .{});
                break;
            }
            buf.scroll(len);
            std.log.info("got {} bytes", .{len});
        }
        while (true) {
            while (buf_start > buf.cursor) {
                buf_start -= buf.size;
            }
            std.debug.assert(buf_start <= buf.cursor); // TODO: is this necessary?  will I still get an exception on the next line anyway?
            const data = buf.ptr[buf_start .. buf.cursor];
            const parsed = x.parseMsg(@alignCast(4, data));
            if (parsed.len == 0)
                break;
            buf_start += parsed.len;
            const msg = parsed.msg;
            switch (msg.generic.kind) {
                .err => {
                    const generic_error = @ptrCast(*x.ErrorReply, msg);
                    switch (generic_error.code) {
                        .length => std.log.debug("{}", .{@ptrCast(*x.ErrorReplyLength, generic_error)}),
                        else => std.log.debug("{}", .{generic_error}),
                    }
                },
                .reply => {
                    std.log.info("todo: handle a reply message", .{});
                    return error.TodoHandleReplyMessage;
                },
                .key_press => {
                    const event = @ptrCast(*x.Event.KeyOrButton, msg);
                    std.log.info("key_press: {}", .{event.detail});
                },
                .key_release => {
                    const event = @ptrCast(*x.Event.KeyOrButton, msg);
                    std.log.info("key_release: {}", .{event.detail});
                },
                .button_press => {
                    const event = @ptrCast(*x.Event.KeyOrButton, msg);
                    std.log.info("button_press: {}", .{event});
                },
                .button_release => {
                    const event = @ptrCast(*x.Event.KeyOrButton, msg);
                    std.log.info("button_release: {}", .{event});
                },
                .enter_notify => {
                    const event = @ptrCast(*x.Event.Generic, msg);
                    std.log.info("enter_window: {}", .{event});
                },
                .leave_notify => {
                    const event = @ptrCast(*x.Event.Generic, msg);
                    std.log.info("leave_window: {}", .{event});
                },
                .motion_notify => {
                    // too much logging
                    //const event = @ptrCast(*x.Event.Generic, msg);
                    //std.log.info("pointer_motion: {}", .{event});
                },
                .keymap_notify => {
                    const event = @ptrCast(*x.Event, msg);
                    std.log.info("keymap_state: {}", .{event});
                },
                .expose => {
                    const event = @ptrCast(*x.Event.Expose, msg);
                    std.log.info("expose: {}", .{event});
                    try render(conn.sock, window_id, bg_gc_id, fg_gc_id);
                },
                else => {
                    const event = @ptrCast(*x.Event, msg);
                    std.log.info("todo: handle event {}", .{event});
                    return error.UnhandledEventKind;
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
