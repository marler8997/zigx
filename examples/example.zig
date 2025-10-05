const std = @import("std");
const x11 = @import("x11");
const common = @import("common.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 400;
const window_height = 400;

const Ids = struct {
    base: x11.ResourceBase,
    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn bg_gc(self: Ids) x11.GraphicsContext {
        return self.base.add(1).graphicsContext();
    }
    pub fn fg_gc(self: Ids) x11.GraphicsContext {
        return self.base.add(2).graphicsContext();
    }
};

pub fn main() !u8 {
    try x11.wsaStartup();
    const conn = try common.connect(allocator);
    defer std.posix.shutdown(conn.sock, .both) catch {};

    const screen = blk: {
        const fixed = conn.setup.fixed();
        inline for (@typeInfo(@TypeOf(fixed.*)).@"struct".fields) |field| {
            std.log.debug("{s}: {any}", .{ field.name, @field(fixed, field.name) });
        }
        std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
        const format_list_offset = x11.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = x11.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        std.log.debug("fmt list off={} limit={}", .{ format_list_offset, format_list_limit });
        const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
        for (formats, 0..) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{ i, format.depth, format.bits_per_pixel, format.scanline_pad });
        }
        const screen = conn.setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).@"struct".fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
        }
        break :blk screen;
    };

    // TODO: maybe need to call conn.setup.verify or something?
    var sequence: u16 = 0;

    const ids: Ids = .{ .base = conn.setup.fixed().resource_id_base };

    {
        var msg_buf: [x11.create_window.max_len]u8 = undefined;
        const len = x11.create_window.serialize(&msg_buf, .{
            .window_id = ids.window(),
            .parent_window_id = screen.root,
            .depth = 0, // we don't care, just inherit from the parent
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
            // .bg_pixmap = .copy_from_parent,
            .bg_pixel = 0xaabbccdd,
            // .border_pixmap =
            // .border_pixel = 0x01fa8ec9,
            // .bit_gravity = .north_west,
            // .win_gravity = .east,
            // .backing_store = .when_mapped,
            // .backing_planes = 0x1234,
            // .backing_pixel = 0xbbeeeeff,
            // .override_redirect = true,
            // .save_under = true,
            .event_mask = .{
                .key_press = 1,
                .key_release = 1,
                .button_press = 1,
                .button_release = 1,
                .enter_window = 1,
                .leave_window = 1,
                .pointer_motion = 1,
                .keymap_state = 1,
                .exposure = 1,
            },
            // .dont_propagate = 1,
        });
        try conn.sendOne(&sequence, msg_buf[0..len]);
    }

    {
        var msg_buf: [x11.create_gc.max_len]u8 = undefined;
        const len = x11.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.bg_gc(),
            .drawable_id = ids.window().drawable(),
        }, .{
            .foreground = screen.black_pixel,
        });
        try conn.sendOne(&sequence, msg_buf[0..len]);
    }
    {
        var msg_buf: [x11.create_gc.max_len]u8 = undefined;
        const len = x11.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.fg_gc(),
            .drawable_id = ids.window().drawable(),
        }, .{
            .background = screen.black_pixel,
            .foreground = 0xffaadd,
        });
        try conn.sendOne(&sequence, msg_buf[0..len]);
    }

    // get some font information
    {
        const text_literal = [_]u16{'m'};
        const text = x11.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        var msg: [x11.query_text_extents.getLen(text.len)]u8 = undefined;
        x11.query_text_extents.serialize(&msg, ids.fg_gc().fontable(), text);
        try conn.sendOne(&sequence, &msg);
    }

    const double_buf = try x11.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.heap.pageSize()),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    // double_buf.deinit() (not necessary)
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    const font_dims: FontDims = blk: {
        _ = try x11.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x11.ServerMsg.QueryTextExtents = @ptrCast(msg_reply);
                break :blk .{
                    .width = @intCast(msg.overall_width),
                    .height = @intCast(msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(msg.overall_left),
                    .font_ascent = msg.font_ascent,
                };
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return 1;
            },
        }
    };

    {
        var msg: [x11.map_window.len]u8 = undefined;
        x11.map_window.serialize(&msg, ids.window());
        try conn.sendOne(&sequence, &msg);
    }

    while (true) {
        {
            const recv_buf = buf.nextReadBuffer();
            if (recv_buf.len == 0) {
                std.log.err("buffer size {} not big enough!", .{buf.half_len});
                return 1;
            }
            const len = try x11.readSock(conn.sock, recv_buf, 0);
            if (len == 0) {
                std.log.info("X server connection closed", .{});
                return 0;
            }
            buf.reserve(len);
        }
        while (true) {
            const data = buf.nextReservedBuffer();
            if (data.len < 32)
                break;
            const msg_len = x11.parseMsgLen(data[0..32].*);
            if (data.len < msg_len)
                break;
            buf.release(msg_len);
            //buf.resetIfEmpty();
            switch (x11.serverMsgTaggedUnion(@alignCast(data.ptr))) {
                .err => |msg| {
                    std.log.err("{}", .{msg});
                    return 1;
                },
                .reply => |msg| {
                    std.log.info("todo: handle a reply message {}", .{msg});
                    return error.TodoHandleReplyMessage;
                },
                .key_press => |msg| {
                    std.log.info("key_press: keycode={}", .{msg.keycode});
                },
                .key_release => |msg| {
                    std.log.info("key_release: keycode={}", .{msg.keycode});
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
                    try render(conn.sock, &sequence, ids.window(), ids.bg_gc(), ids.fg_gc(), font_dims);
                },
                .mapping_notify => |msg| {
                    std.log.info("mapping_notify: {}", .{msg});
                },
                .no_exposure => |msg| std.debug.panic("unexpected no_exposure {}", .{msg}),
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
                .destroy_notify,
                .unmap_notify,
                .map_notify,
                .reparent_notify,
                .configure_notify,
                => unreachable, // did not register for these
            }
        }
    }
}

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

fn render(
    sock: std.posix.socket_t,
    sequence: *u16,
    window_id: x11.Window,
    bg_gc_id: x11.GraphicsContext,
    fg_gc_id: x11.GraphicsContext,
    font_dims: FontDims,
) !void {
    {
        var msg: [x11.poly_fill_rectangle.getLen(1)]u8 = undefined;
        x11.poly_fill_rectangle.serialize(&msg, .{
            .drawable_id = window_id.drawable(),
            .gc_id = bg_gc_id,
        }, &[_]x11.Rectangle{
            .{ .x = 100, .y = 100, .width = 200, .height = 200 },
        });
        try common.sendOne(sock, sequence, &msg);
    }
    {
        var msg: [x11.clear_area.len]u8 = undefined;
        x11.clear_area.serialize(&msg, false, window_id, .{
            .x = 150,
            .y = 150,
            .width = 100,
            .height = 100,
        });
        try common.sendOne(sock, sequence, &msg);
    }
    {
        const text_literal: []const u8 = "Hello X!";
        const text = x11.Slice(u8, [*]const u8){ .ptr = text_literal.ptr, .len = text_literal.len };
        var msg: [x11.image_text8.getLen(text.len)]u8 = undefined;

        const text_width = font_dims.width * text_literal.len;

        x11.image_text8.serialize(&msg, text, .{
            .drawable_id = window_id.drawable(),
            .gc_id = fg_gc_id,
            .x = @divTrunc((window_width - @as(i16, @intCast(text_width))), 2) + font_dims.font_left,
            .y = @divTrunc((window_height - @as(i16, @intCast(font_dims.height))), 2) + font_dims.font_ascent,
        });
        try common.sendOne(sock, sequence, &msg);
    }
}
