// A working example to test various parts of the API
const std = @import("std");
const x = @import("./x.zig");
const common = @import("common.zig");

const Endian = std.builtin.Endian;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 400;
const window_height = 400;

pub const Ids = struct {
    base: u32,
    pub fn window(self: Ids) u32 { return self.base; }
    pub fn bg_gc(self: Ids) u32 { return self.base + 1; }
    pub fn fg_gc(self: Ids) u32 { return self.base + 2; }
};

const ImageFormat = struct {
    endian: Endian,
    depth: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
};
fn getImageFormat(
    endian: Endian,
    formats: []const align(4) x.Format,
    root_depth: u8,
) !ImageFormat {
    var opt_match_index: ?usize = null;
    for (formats) |format, i| {
        if (format.depth == root_depth) {
            if (opt_match_index) |_|
                return error.MultiplePixmapFormatsSameDepth;
            opt_match_index = i;
        }
    }
    const match_index = opt_match_index orelse
        return error.MissingPixmapFormat;
    return ImageFormat {
        .endian = endian,
        .depth = root_depth,
        .bits_per_pixel = formats[match_index].bits_per_pixel,
        .scanline_pad = formats[match_index].scanline_pad,
    };
}

pub fn main() !u8 {
    try x.wsaStartup();
    const conn = try common.connect(allocator);
    defer std.os.shutdown(conn.sock, .both) catch {};

    const conn_setup_result = blk: {
        const fixed = conn.setup.fixed();
        inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
            std.log.debug("{s}: {any}", .{field.name, @field(fixed, field.name)});
        }
        const image_endian: Endian = switch (fixed.image_byte_order) {
            .lsb_first => .Little,
            .msb_first => .Big,
            else => |order| {
                std.log.err("unknown image-byte-order {}", .{order});
                return 0xff;
            },
        };
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
        break :blk .{
            .screen = screen,
            .image_format = getImageFormat(
                image_endian,
                formats,
                screen.root_depth,
            ) catch |err| {
                std.log.err("can't resolve root depth {} format: {s}", .{screen.root_depth, @errorName(err)});
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
            .x = 0, .y = 0,
            .width = window_width, .height = window_height,
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
            .event_mask =
                  x.event.key_press
                | x.event.key_release
                | x.event.button_press
                | x.event.button_release
                | x.event.enter_window
                | x.event.leave_window
                | x.event.pointer_motion
//                | x.event.pointer_motion_hint WHAT THIS DO?
//                | x.event.button1_motion  WHAT THIS DO?
//                | x.event.button2_motion  WHAT THIS DO?
//                | x.event.button3_motion  WHAT THIS DO?
//                | x.event.button4_motion  WHAT THIS DO?
//                | x.event.button5_motion  WHAT THIS DO?
//                | x.event.button_motion  WHAT THIS DO?
                | x.event.keymap_state
                | x.event.exposure
                ,
//            .dont_propagate = 1,
        });
        try conn.send(msg_buf[0..len]);
    }

    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.bg_gc(),
            .drawable_id = screen.root,
        }, .{
            .foreground = screen.black_pixel,
        });
        try conn.send(msg_buf[0..len]);
    }
    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.fg_gc(),
            .drawable_id = screen.root,
        }, .{
            .background = screen.black_pixel,
            .foreground = x.rgb24To(0xffaadd, screen.root_depth),
        });
        try conn.send(msg_buf[0..len]);
    }

    // get some font information
    {
        const text_literal = [_]u16 { 'm' };
        const text = x.Slice(u16, [*]const u16) { .ptr = &text_literal, .len = text_literal.len };
        var msg: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&msg, ids.fg_gc(), text);
        try conn.send(&msg);
    }

    const double_buf = try x.DoubleBuffer.init(
        std.mem.alignForward(1000, std.mem.page_size),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    defer double_buf.deinit(); // not necessary but good to test
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    const font_dims: FontDims = blk: {
        _ = try x.readOneMsg(conn.reader(), @alignCast(4, buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(4, buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg = @ptrCast(*x.ServerMsg.QueryTextExtents, msg_reply);
                break :blk .{
                    .width = @intCast(u8, msg.overall_width),
                    .height = @intCast(u8, msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(i16, msg.overall_left),
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
        const ext_name = comptime x.Slice(u16, [*]const u8).initComptime("RENDER");
        var msg: [x.query_extension.getLen(ext_name.len)]u8 = undefined;
        x.query_extension.serialize(&msg, ext_name);
        try conn.send(&msg);
    }
    _ = try x.readOneMsg(conn.reader(), @alignCast(4, buf.nextReadBuffer()));
    const opt_render_ext: ?struct { opcode: u8 } = blk: {
        switch (x.serverMsgTaggedUnion(@alignCast(4, buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg = @ptrCast(*x.ServerMsg.QueryExtension, msg_reply);
                if (msg.present == 0) {
                    std.log.info("RENDER extension: not present", .{});
                    break :blk null;
                }
                std.debug.assert(msg.present == 1);
                std.log.info("RENDER extension: opcode={}", .{msg.major_opcode});
                break :blk .{ .opcode = msg.major_opcode };
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return 1;
            },

        }
    };
    if (opt_render_ext) |render_ext| {
        {
            var msg: [x.render.query_version.len]u8 = undefined;
            x.render.query_version.serialize(&msg, render_ext.opcode, .{
                .major_version = 0,
                .minor_version = 11,
            });
            try conn.send(&msg);
        }
        _ = try x.readOneMsg(conn.reader(), @alignCast(4, buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(4, buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg = @ptrCast(*x.render.query_version.Reply, msg_reply);
                std.log.info("RENDER extension: version {}.{}", .{msg.major_version, msg.minor_version});
                if (msg.major_version != 0) {
                    std.log.err("xrender extension major version {} too new", .{msg.major_version});
                    return 1;
                }
                if (msg.minor_version < 11) {
                    std.log.err("xrender extension minor version {} too old", .{msg.minor_version});
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
            const msg_len = x.parseMsgLen(@alignCast(4, data));
            if (msg_len == 0)
                break;
            buf.release(msg_len);
            //buf.resetIfEmpty();
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
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
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
    sock: std.os.socket_t,
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
        }, &[_]x.Rectangle {
            .{ .x = 100, .y = 100, .width = 200, .height = 200 },
        });
        try common.send(sock, &msg);
    }
    {
        var msg: [x.clear_area.len]u8 = undefined;
        x.clear_area.serialize(&msg, false, ids.window(), .{
            .x = 150, .y = 150, .width = 100, .height = 100,
        });
        try common.send(sock, &msg);
    }

    try changeGcColor(sock, ids.fg_gc(), x.rgb24To(0xffaadd, depth));
    {
        const text_literal: []const u8 = "Hello X!";
        const text = x.Slice(u8, [*]const u8) { .ptr = text_literal.ptr, .len = text_literal.len };
        var msg: [x.image_text8.getLen(text.len)]u8 = undefined;

        const text_width = font_dims.width * text_literal.len;

        x.image_text8.serialize(&msg, text, .{
            .drawable_id = ids.window(),
            .gc_id = ids.fg_gc(),
            .x = @divTrunc((window_width - @intCast(i16, text_width)),  2) + font_dims.font_left,
            .y = @divTrunc((window_height - @intCast(i16, font_dims.height)), 2) + font_dims.font_ascent,
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

    // send a 15x15 test image
    {
        const width = 15;
        const height = 15;

        const max_bytes_per_pixel = 4;
        const max_scanline_len_unaligned = max_bytes_per_pixel * width;
        const max_scanline_len = comptime std.mem.alignForward(
            max_scanline_len_unaligned,
            32 / 8, // max scanline pad
        );
        const max_data_len = height * max_scanline_len;
        var msg: [x.put_image.getLen(max_data_len)]u8 = undefined;

        // ZFormat
        // depth:
        //     bits-per-pixel: 1, 4, 8, 16, 24, 32
        //         bpp can be larger than depth, when it is, the
        //         least significant bits hold the pixmap data
        //         when bpp is 4, order of nibbles in the bytes is the
        //         same as the image "byte-order"
        //     scanline-pad: 8, 16, 32
        const bytes_per_pixel = image_format.bits_per_pixel / 8;
        std.debug.assert(bytes_per_pixel <= max_bytes_per_pixel);
        const scanline_len_unaligned = bytes_per_pixel * width;
        const scanline_len = std.mem.alignForward(
            scanline_len_unaligned,
            image_format.scanline_pad / 8,
        );
        std.log.info("format={} bytes_per_pixel={} width={} scanline_len={} (unaligned={}) height={}", .{
            image_format,
            bytes_per_pixel,
            width,
            scanline_len,
            scanline_len_unaligned,
            height,
        });
        const data_len = @intCast(u18, height * scanline_len);
        std.debug.assert(data_len <= max_data_len);
        {
            var row: usize = 0;
            while (row < height) : (row += 1) {
                var data_off: usize = x.put_image.data_offset + row * @intCast(usize, scanline_len);

                var color: u24 = 0;
                if (row < 5) { color |= 0xff0000; }
                else if (row < 10) { color |= 0xff00; }
                else { color |= 0xff; }

                var col: usize = 0;
                while (col < width) : (col += 1) {
                    switch (image_format.depth) {
                        16 => std.mem.writeInt(
                            u16,
                            msg[data_off..][0 .. 2],
                            x.rgb24To16(color),
                            image_format.endian,
                        ),
                        24 => std.mem.writeInt(
                            u24,
                            msg[data_off..][0 .. 3],
                            color,
                            image_format.endian,
                        ),
                        32 => std.mem.writeInt(
                            u32,
                            msg[data_off..][0 .. 4],
                            color,
                            image_format.endian,
                        ),
                        else => std.debug.panic("TODO: implement image depth {}", .{image_format.depth}),
                    }
                    data_off += bytes_per_pixel;
                }
            }
        }
        x.put_image.serializeNoDataCopy(&msg, data_len, .{
            .format = .z_pixmap,
            .drawable_id = ids.window(),
            .gc_id = ids.fg_gc(),
            .width = width,
            .height = height,
            .x = 100,
            .y = 20,
            .left_pad = 0,
            .depth = image_format.depth,
        });
        try common.send(sock, msg[0 .. x.put_image.getLen(data_len)]);
    }
}

fn changeGcColor(sock: std.os.socket_t, gc_id: u32, color: u32) !void {
    var msg_buf: [x.change_gc.max_len]u8 = undefined;
    const len = x.change_gc.serialize(&msg_buf, gc_id, .{
        .foreground = color,
    });
    try common.send(sock, msg_buf[0..len]);
}
