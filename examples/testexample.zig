// A working example to test various parts of the API
const std = @import("std");
const x = @import("x");
const common = @import("common.zig");

const Endian = std.builtin.Endian;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 400;
const window_height = 400;

pub const Ids = struct {
    base: u32,
    pub fn window(self: Ids) u32 {
        return self.base;
    }
    pub fn bg_gc(self: Ids) u32 {
        return self.base + 1;
    }
    pub fn fg_gc(self: Ids) u32 {
        return self.base + 2;
    }
    pub fn pixmap(self: Ids) u32 {
        return self.base + 3;
    }
};

// ZFormat
// depth:
//     bits-per-pixel: 1, 4, 8, 16, 24, 32
//         bpp can be larger than depth, when it is, the
//         least significant bits hold the pixmap data
//         when bpp is 4, order of nibbles in the bytes is the
//         same as the image "byte-order"
//     scanline-pad: 8, 16, 32
const ImageFormat = struct {
    endian: Endian,
    depth: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
};
fn getImageFormat(
    endian: Endian,
    formats: []align(4) const x.Format,
    root_depth: u8,
) !ImageFormat {
    var opt_match_index: ?usize = null;
    for (formats, 0..) |format, i| {
        if (format.depth == root_depth) {
            if (opt_match_index) |_|
                return error.MultiplePixmapFormatsSameDepth;
            opt_match_index = i;
        }
    }
    const match_index = opt_match_index orelse
        return error.MissingPixmapFormat;
    return ImageFormat{
        .endian = endian,
        .depth = root_depth,
        .bits_per_pixel = formats[match_index].bits_per_pixel,
        .scanline_pad = formats[match_index].scanline_pad,
    };
}

pub fn main() !u8 {
    try x.wsaStartup();
    const conn = try common.connect(allocator);
    defer std.posix.shutdown(conn.sock, .both) catch {};

    const conn_setup_result = blk: {
        const fixed = conn.setup.fixed();
        inline for (@typeInfo(@TypeOf(fixed.*)).@"struct".fields) |field| {
            std.log.debug("{s}: {any}", .{ field.name, @field(fixed, field.name) });
        }
        const image_endian: Endian = switch (fixed.image_byte_order) {
            .lsb_first => .little,
            .msb_first => .big,
            else => |order| {
                std.log.err("unknown image-byte-order {}", .{order});
                return 0xff;
            },
        };
        std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
        const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        std.log.debug("fmt list off={} limit={}", .{ format_list_offset, format_list_limit });
        const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
        for (formats, 0..) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{ i, format.depth, format.bits_per_pixel, format.scanline_pad });
        }
        const screen = conn.setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).@"struct".fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
        }
        break :blk .{
            .screen = screen,
            .image_format = getImageFormat(
                image_endian,
                formats,
                screen.root_depth,
            ) catch |err| {
                std.log.err("can't resolve root depth {} format: {s}", .{ screen.root_depth, @errorName(err) });
                return 0xff;
            },
        };
    };
    const screen = conn_setup_result.screen;

    // TODO: maybe need to call conn.setup.verify or something?

    const ids = Ids{ .base = conn.setup.fixed().resource_id_base };
    {
        var msg_buf: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&msg_buf, .{
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
            //            .bg_pixmap = .copy_from_parent,
            .bg_pixel = x.rgb24To(0xbbccdd, screen.root_depth),
            //            //.border_pixmap =
            //            .border_pixel = 0x01fa8ec9,
            //            .bit_gravity = .north_west,
            //            .win_gravity = .east,
            //            .backing_store = .when_mapped,
            //            .backing_planes = 0x1234,
            //            .backing_pixel = 0xbbeeeeff,
            //            .override_redirect = true,
            //            .save_under = true,
            .event_mask = x.event.key_press | x.event.key_release | x.event.button_press | x.event.button_release | x.event.enter_window | x.event.leave_window | x.event.pointer_motion
                //                | x.event.pointer_motion_hint WHAT THIS DO?
                //                | x.event.button1_motion  WHAT THIS DO?
                //                | x.event.button2_motion  WHAT THIS DO?
                //                | x.event.button3_motion  WHAT THIS DO?
                //                | x.event.button4_motion  WHAT THIS DO?
                //                | x.event.button5_motion  WHAT THIS DO?
                //                | x.event.button_motion  WHAT THIS DO?
            | x.event.keymap_state | x.event.exposure | x.event.structure_notify,
            //            .dont_propagate = 1,
        });
        try conn.send(msg_buf[0..len]);
    }

    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.bg_gc(),
            .drawable_id = ids.window(),
        }, .{
            .foreground = screen.black_pixel,
        });
        try conn.send(msg_buf[0..len]);
    }
    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.fg_gc(),
            .drawable_id = ids.window(),
        }, .{
            .background = screen.black_pixel,
            .foreground = x.rgb24To(0xffaadd, screen.root_depth),
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
        });
        try conn.send(msg_buf[0..len]);
    }

    // get some font information
    {
        const text_literal = [_]u16{'m'};
        const text = x.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        var msg: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&msg, ids.fg_gc(), text);
        try conn.send(&msg);
    }

    const double_buf = try x.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.heap.page_size_min),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    defer double_buf.deinit(); // not necessary but good to test
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    const font_dims: FontDims = blk: {
        _ = try x.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.ServerMsg.QueryTextExtents = @ptrCast(msg_reply);
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


    const opt_render_ext = try common.getExtensionInfo(
        conn.sock,
        &buf,
        "RENDER"
    );
    if (opt_render_ext) |render_ext| {
        const expected_version: common.ExtensionVersion = .{ .major_version = 0, .minor_version = 11 };
        {
            var msg: [x.render.query_version.len]u8 = undefined;
            x.render.query_version.serialize(&msg, render_ext.opcode, .{
                .major_version = expected_version.major_version,
                .minor_version = expected_version.minor_version,
            });
            try conn.send(&msg);
        }
        _ = try x.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.render.query_version.Reply = @ptrCast(msg_reply);
                std.log.info("X RENDER extension: version {}.{}", .{msg.major_version, msg.minor_version});
                if (msg.major_version != expected_version.major_version) {
                    std.log.err("X RENDER extension major version is {} but we expect {}", .{
                        msg.major_version,
                        expected_version.major_version,
                    });
                    return 1;
                }
                if (msg.minor_version < expected_version.minor_version) {
                    std.log.err("X RENDER extension minor version is {}.{} but I've only tested >= {}.{})", .{
                        msg.major_version,
                        msg.minor_version,
                        expected_version.major_version,
                        expected_version.minor_version,
                    });
                    return 1;
                }
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return 1;
            },
        }
    }

    const opt_test_ext = try common.getExtensionInfo(
        conn.sock,
        &buf,
        "XTEST"
    );
    if (opt_test_ext) |test_ext| {
        const expected_version: common.ExtensionVersion = .{ .major_version = 2, .minor_version = 2 };
        {
            var msg: [x.testext.get_version.len]u8 = undefined;
            x.testext.get_version.serialize(&msg, .{
                .ext_opcode = test_ext.opcode,
                .wanted_major_version = expected_version.major_version,
                .wanted_minor_version = expected_version.minor_version,
            });
            try conn.send(&msg);
        }
        _ = try x.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.testext.get_version.Reply = @ptrCast(msg_reply);
                std.log.info("XTEST extension: version {}.{}", .{msg.major_version, msg.minor_version});
                if (msg.major_version != expected_version.major_version) {
                    std.log.err("XTEST extension major version is {} but we expect {}", .{
                        msg.major_version,
                        expected_version.major_version,
                    });
                    return 1;
                }
                if (msg.minor_version < expected_version.minor_version) {
                    std.log.err("XTEST extension minor version is {}.{} but I've only tested >= {}.{})", .{
                        msg.major_version,
                        msg.minor_version,
                        expected_version.major_version,
                        expected_version.minor_version,
                    });
                    return 1;
                }
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return 1;
            },
        }
    }

    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, ids.window());
        try conn.send(&msg);
    }

    // Send a fake mouse left-click event
    if (opt_test_ext) |test_ext| {
        {
            var msg: [x.testext.fake_input.len]u8 = undefined;
            x.testext.fake_input.serialize(&msg, test_ext.opcode, .{
                .button_press = .{
                    .event_type = x.testext.FakeEventType.button_press,
                    .detail = 1,
                    .delay_ms = 0,
                    .device_id = null,
                },
            });
            try conn.send(&msg);
        }

        {
            var msg: [x.testext.fake_input.len]u8 = undefined;
            x.testext.fake_input.serialize(&msg, test_ext.opcode, .{
                .button_press = .{
                    .event_type = x.testext.FakeEventType.button_release,
                    .detail = 1,
                    .delay_ms = 0,
                    .device_id = null,
                },
            });
            try conn.send(&msg);
        }
    }

    while (true) {
        {
            const recv_buf = buf.nextReadBuffer();
            if (recv_buf.len == 0) {
                std.log.err("buffer size {} not big enough!", .{buf.half_len});
                return 1;
            }
            const len = try x.readSock(conn.sock, recv_buf, 0);
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
            const msg_len = x.parseMsgLen(data[0..32].*);
            if (data.len < msg_len)
                break;
            buf.release(msg_len);
            //buf.resetIfEmpty();
            switch (x.serverMsgTaggedUnion(@alignCast(data.ptr))) {
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
                    try render(
                        conn.sock,
                        screen.root_depth,
                        conn_setup_result.image_format,
                        ids,
                        font_dims,
                    );
                },
                .mapping_notify => |msg| {
                    std.log.info("mapping_notify: {}", .{msg});
                },
                .no_exposure => |msg| std.debug.panic("unexpected no_exposure {}", .{msg}),
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
                .map_notify => |msg| std.log.info("map_notify: {}", .{msg}),
                .reparent_notify => |msg| std.log.info("reparent_notify: {}", .{msg}),
                .configure_notify => |msg| std.log.info("configure_notify: {}", .{msg}),
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
    depth: u8,
    image_format: ImageFormat,
    ids: Ids,
    font_dims: FontDims,
) !void {
    {
        var msg: [x.poly_fill_rectangle.getLen(1)]u8 = undefined;
        x.poly_fill_rectangle.serialize(&msg, .{
            .drawable_id = ids.window(),
            .gc_id = ids.bg_gc(),
        }, &[_]x.Rectangle{
            .{ .x = 100, .y = 100, .width = 200, .height = 200 },
        });
        try common.send(sock, &msg);
    }
    {
        var msg: [x.clear_area.len]u8 = undefined;
        x.clear_area.serialize(&msg, false, ids.window(), .{
            .x = 150,
            .y = 150,
            .width = 100,
            .height = 100,
        });
        try common.send(sock, &msg);
    }

    try changeGcColor(sock, ids.fg_gc(), x.rgb24To(0xffaadd, depth));
    {
        const text_literal: []const u8 = "Hello X!";
        const text = x.Slice(u8, [*]const u8){ .ptr = text_literal.ptr, .len = text_literal.len };
        var msg: [x.image_text8.getLen(text.len)]u8 = undefined;

        const text_width = font_dims.width * text_literal.len;

        x.image_text8.serialize(&msg, text, .{
            .drawable_id = ids.window(),
            .gc_id = ids.fg_gc(),
            .x = @divTrunc((window_width - @as(i16, @intCast(text_width))), 2) + font_dims.font_left,
            .y = @divTrunc((window_height - @as(i16, @intCast(font_dims.height))), 2) + font_dims.font_ascent,
        });
        try common.send(sock, &msg);
    }

    try changeGcColor(sock, ids.fg_gc(), x.rgb24To(0x00ff00, depth));
    {
        const rectangles = [_]x.Rectangle{
            .{ .x = 20, .y = 20, .width = 15, .height = 15 },
            .{ .x = 40, .y = 20, .width = 15, .height = 15 },
        };
        var msg: [x.poly_fill_rectangle.getLen(rectangles.len)]u8 = undefined;
        x.poly_fill_rectangle.serialize(&msg, .{
            .drawable_id = ids.window(),
            .gc_id = ids.fg_gc(),
        }, &rectangles);
        try common.send(sock, &msg);
    }
    try changeGcColor(sock, ids.fg_gc(), x.rgb24To(0x0000ff, depth));
    {
        const rectangles = [_]x.Rectangle{
            .{ .x = 60, .y = 20, .width = 15, .height = 15 },
            .{ .x = 80, .y = 20, .width = 15, .height = 15 },
        };
        var msg: [x.poly_rectangle.getLen(rectangles.len)]u8 = undefined;
        x.poly_rectangle.serialize(&msg, .{
            .drawable_id = ids.window(),
            .gc_id = ids.fg_gc(),
        }, &rectangles);
        try common.send(sock, &msg);
    }

    const test_image = struct {
        pub const width = 15;
        pub const height = 15;

        pub const max_bytes_per_pixel = 4;
        const max_scanline_pad = 32;
        pub const max_scanline_len = std.mem.alignForward(
            u16,
            max_bytes_per_pixel * width,
            max_scanline_pad / 8, // max scanline pad
        );
        const max_data_len = height * max_scanline_len;
    };

    const test_image_scanline_len = blk: {
        const bytes_per_pixel = image_format.bits_per_pixel / 8;
        std.debug.assert(bytes_per_pixel <= test_image.max_bytes_per_pixel);
        break :blk std.mem.alignForward(
            u16,
            bytes_per_pixel * test_image.width,
            image_format.scanline_pad / 8,
        );
    };
    const test_image_data_len: u18 = @intCast(test_image.height * test_image_scanline_len);
    std.debug.assert(test_image_data_len <= test_image.max_data_len);

    {
        var put_image_msg: [x.put_image.getLen(test_image.max_data_len)]u8 = undefined;
        populateTestImage(
            image_format,
            test_image.width,
            test_image.height,
            test_image_scanline_len,
            put_image_msg[x.put_image.data_offset..],
        );
        x.put_image.serializeNoDataCopy(&put_image_msg, test_image_data_len, .{
            .format = .z_pixmap,
            .drawable_id = ids.window(),
            .gc_id = ids.fg_gc(),
            .width = test_image.width,
            .height = test_image.height,
            .x = 100,
            .y = 20,
            .left_pad = 0,
            .depth = image_format.depth,
        });
        try common.send(sock, put_image_msg[0..x.put_image.getLen(test_image_data_len)]);

        // test a pixmap
        {
            var msg: [x.create_pixmap.len]u8 = undefined;
            x.create_pixmap.serialize(&msg, .{
                .id = ids.pixmap(),
                .drawable_id = ids.window(),
                .depth = image_format.depth,
                .width = test_image.width,
                .height = test_image.height,
            });
            try common.send(sock, &msg);
        }
        x.put_image.serializeNoDataCopy(&put_image_msg, test_image_data_len, .{
            .format = .z_pixmap,
            .drawable_id = ids.pixmap(),
            .gc_id = ids.fg_gc(),
            .width = test_image.width,
            .height = test_image.height,
            .x = 0,
            .y = 0,
            .left_pad = 0,
            .depth = image_format.depth,
        });
        try common.send(sock, put_image_msg[0..x.put_image.getLen(test_image_data_len)]);

        {
            var msg: [x.copy_area.len]u8 = undefined;
            x.copy_area.serialize(&msg, .{
                .src_drawable_id = ids.pixmap(),
                .dst_drawable_id = ids.window(),
                .gc_id = ids.fg_gc(),
                .src_x = 0,
                .src_y = 0,
                .dst_x = 120,
                .dst_y = 20,
                .width = test_image.width,
                .height = test_image.height,
            });
            try common.send(sock, &msg);
        }

        {
            var msg: [x.free_pixmap.len]u8 = undefined;
            x.free_pixmap.serialize(&msg, ids.pixmap());
            try common.send(sock, &msg);
        }
    }
}

fn changeGcColor(sock: std.posix.socket_t, gc_id: u32, color: u32) !void {
    var msg_buf: [x.change_gc.max_len]u8 = undefined;
    const len = x.change_gc.serialize(&msg_buf, gc_id, .{
        .foreground = color,
    });
    try common.send(sock, msg_buf[0..len]);
}

fn populateTestImage(
    image_format: ImageFormat,
    width: u16,
    height: u16,
    stride: usize,
    data: []u8,
) void {
    var row: usize = 0;
    while (row < height) : (row += 1) {
        var data_off: usize = row * stride;

        var color: u24 = 0;
        if (row < 5) {
            color |= 0xff0000;
        } else if (row < 10) {
            color |= 0xff00;
        } else {
            color |= 0xff;
        }

        var col: usize = 0;
        while (col < width) : (col += 1) {
            switch (image_format.depth) {
                16 => std.mem.writeInt(
                    u16,
                    data[data_off..][0..2],
                    x.rgb24To16(color),
                    image_format.endian,
                ),
                24 => std.mem.writeInt(
                    u24,
                    data[data_off..][0..3],
                    color,
                    image_format.endian,
                ),
                32 => std.mem.writeInt(
                    u32,
                    data[data_off..][0..4],
                    x.rgb24To(color, 32),
                    image_format.endian,
                ),
                else => std.debug.panic("TODO: implement image depth {}", .{image_format.depth}),
            }
            data_off += (image_format.bits_per_pixel / 8);
        }
    }
}
