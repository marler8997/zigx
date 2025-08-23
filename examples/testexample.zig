// A working example to test various parts of the API
const std = @import("std");
const x11 = @import("x11");
const common = @import("common.zig");

const Endian = std.builtin.Endian;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 400;
const window_height = 400;

pub const Ids = struct {
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
    pub fn pixmap(self: Ids) x11.Pixmap {
        return self.base.add(3).pixmap();
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
    formats: []align(4) const x11.Format,
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

fn expectSequence(expected_sequence: u16, reply: *const x11.ServerMsg.Reply) void {
    if (expected_sequence != reply.sequence) std.debug.panic(
        "expected reply sequence {} but got {}",
        .{ expected_sequence, reply },
    );
}

pub fn main() !u8 {
    try x11.wsaStartup();
    const conn = try common.connect(allocator);
    defer std.posix.shutdown(conn.sock, .both) catch {};
    var sequence: u16 = 0;

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
            .bg_pixel = x11.rgb24To(0xbbccdd, screen.root_depth),
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
                .structure_notify = 1,
            },
            // .dont_propagate = 1,
        });
        try conn.sendOne(&sequence, msg_buf[0..len]);
    }

    const double_buf = try x11.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.heap.pageSize()),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    defer double_buf.deinit(); // not necessary but good to test
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    // Set the window name
    {
        const window_name = comptime x11.Slice(u16, [*]const u8).initComptime("zigx Test Example");
        const change_property = x11.change_property.withFormat(u8);
        var msg_buf: [change_property.getLen(window_name.len)]u8 = undefined;
        change_property.serialize(&msg_buf, .{
            .mode = .replace,
            .window_id = ids.window(),
            .property = x11.Atom.WM_NAME,
            .type = x11.Atom.STRING,
            .values = window_name,
        });
        try conn.sendOne(&sequence, msg_buf[0..]);
    }

    // Test `get_property` by retrieving the property we just set
    {
        var msg_buf: [x11.get_property.len]u8 = undefined;
        x11.get_property.serialize(&msg_buf, .{
            .window_id = ids.window(),
            .property = x11.Atom.WM_NAME,
            .type = x11.Atom.STRING,
            .offset = 0,
            .len = 64,
            .delete = false,
        });
        try conn.sendOne(&sequence, msg_buf[0..]);
    }
    _ = try x11.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
    switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
        .reply => |msg_reply| {
            expectSequence(sequence, msg_reply);
            const msg: *x11.get_property.Reply = @ptrCast(msg_reply);
            std.log.debug("get_property responded with: {}", .{msg});
            const opt_window_name = try msg.getValueBytes();
            if (opt_window_name) |window_name| {
                std.log.debug("Retrieved window name: {s}", .{window_name});
            } else {
                std.log.err("Unable to figure out the window name from get_property reply: {}", .{msg});
            }
        },
        else => |msg| {
            std.log.err("expected a reply for `x11.get_property` but got {}", .{msg});
            return error.ExpectedReplyForGetProperty;
        },
    }

    // Test `query_tree` by finding our own window in the list of children of the root
    // window
    {
        var msg_buf: [x11.query_tree.len]u8 = undefined;
        x11.query_tree.serialize(&msg_buf, screen.root);
        try conn.sendOne(&sequence, msg_buf[0..]);
    }
    _ = try x11.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
    switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
        .reply => |msg_reply| {
            expectSequence(sequence, msg_reply);
            const msg: *x11.query_tree.Reply = @ptrCast(msg_reply);
            std.log.debug("query_tree found {d} child windows", .{msg.num_windows});

            // Try to find our own window in the list just to sanity check that query_tree works
            var found_window: bool = false;
            for (msg.getWindowList()) |window_id| {
                if (window_id == ids.window()) {
                    found_window = true;
                    break;
                }
            }
            std.log.debug("Found our window in query_tree response? {}", .{found_window});
        },
        else => |msg| {
            std.log.err("expected a reply for `x11.query_tree` but got {}", .{msg});
            return error.ExpectedReplyForQueryTree;
        },
    }

    // test creating/freeing GCs
    for (0..3) |_| {
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
            var msg: [x11.free_gc.len]u8 = undefined;
            x11.free_gc.serialize(&msg, ids.bg_gc());
            try conn.sendOne(&sequence, &msg);
        }
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
            .foreground = x11.rgb24To(0xffaadd, screen.root_depth),
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
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

    const font_dims: FontDims = blk: {
        _ = try x11.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                expectSequence(sequence, msg_reply);
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

    const opt_render_ext = try common.getExtensionInfo(conn.sock, &sequence, &buf, "RENDER");
    if (opt_render_ext) |render_ext| {
        const expected_version: common.ExtensionVersion = .{ .major_version = 0, .minor_version = 10 };
        {
            var msg: [x11.render.query_version.len]u8 = undefined;
            x11.render.query_version.serialize(&msg, render_ext.opcode, .{
                .major_version = expected_version.major_version,
                .minor_version = expected_version.minor_version,
            });
            try conn.sendOne(&sequence, &msg);
        }
        _ = try x11.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                expectSequence(sequence, msg_reply);
                const msg: *x11.render.query_version.Reply = @ptrCast(msg_reply);
                std.log.info("X RENDER extension: version {}.{}", .{ msg.major_version, msg.minor_version });
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

    const opt_shape_ext = try common.getExtensionInfo(conn.sock, &sequence, &buf, "SHAPE");
    if (opt_shape_ext) |shape_ext| {
        const expected_version: common.ExtensionVersion = .{ .major_version = 1, .minor_version = 1 };

        {
            var msg: [x11.shape.query_version.len]u8 = undefined;
            x11.shape.query_version.serialize(&msg, shape_ext.opcode);
            try conn.sendOne(&sequence, &msg);
        }

        _ = try x11.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                expectSequence(sequence, msg_reply);
                const msg: *x11.shape.query_version.Reply = @ptrCast(msg_reply);
                std.log.info("X SHAPE extension: version {}.{}", .{ msg.major_version, msg.minor_version });
                if (msg.major_version != expected_version.major_version) {
                    std.log.err("X SHAPE extension major version is {} but we expect {}", .{
                        msg.major_version,
                        expected_version.major_version,
                    });
                    return 1;
                }
                if (msg.minor_version < expected_version.minor_version) {
                    std.log.err("X SHAPE extension minor version is {}.{} but I've only tested >= {}.{})", .{
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

    const opt_test_ext = try common.getExtensionInfo(conn.sock, &sequence, &buf, "XTEST");
    if (opt_test_ext) |test_ext| {
        const expected_version: common.ExtensionVersion = .{ .major_version = 2, .minor_version = 2 };
        {
            var msg: [x11.testext.get_version.len]u8 = undefined;
            x11.testext.get_version.serialize(&msg, .{
                .ext_opcode = test_ext.opcode,
                .wanted_major_version = expected_version.major_version,
                .wanted_minor_version = expected_version.minor_version,
            });
            try conn.sendOne(&sequence, &msg);
        }
        _ = try x11.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                expectSequence(sequence, msg_reply);
                const msg: *x11.testext.get_version.Reply = @ptrCast(msg_reply);
                std.log.info("XTEST extension: version {}.{}", .{ msg.major_version, msg.minor_version });
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
        var msg: [x11.map_window.len]u8 = undefined;
        x11.map_window.serialize(&msg, ids.window());
        try conn.sendOne(&sequence, &msg);
    }

    // Send a fake mouse left-click event
    // if (opt_test_ext) |test_ext| {
    //     {
    //         var msg: [x11.testext.fake_input.len]u8 = undefined;
    //         x11.testext.fake_input.serialize(&msg, test_ext.opcode, .{
    //             .button_press = .{
    //                 .event_type = x11.testext.FakeEventType.button_press,
    //                 .detail = 1,
    //                 .delay_ms = 0,
    //                 .device_id = null,
    //             },
    //         });
    //         try conn.sendOne(&sequence, &msg);
    //     }

    //     {
    //         var msg: [x11.testext.fake_input.len]u8 = undefined;
    //         x11.testext.fake_input.serialize(&msg, test_ext.opcode, .{
    //             .button_press = .{
    //                 .event_type = x11.testext.FakeEventType.button_release,
    //                 .detail = 1,
    //                 .delay_ms = 0,
    //                 .device_id = null,
    //             },
    //         });
    //         try conn.sendOne(&sequence, &msg);
    //     }
    // }

    {
        // This will probably happen by default when you `map_window` (I'm guessing it
        // depends on your window manager) but we can be extra annoying and always bring
        // the window to the front (just testing this request out).
        var msg: [x11.configure_window.max_len]u8 = undefined;
        const len = x11.configure_window.serialize(&msg, .{
            .window_id = ids.window(),
        }, .{
            .stack_mode = .above,
        });
        try conn.sendOne(&sequence, msg[0..len]);
    }

    var maybe_get_img_sequence: ?u16 = null;

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
                    var handled = false;
                    if (maybe_get_img_sequence) |s| {
                        if (s == msg.sequence) {
                            try checkTestImageIsDrawnToWindow(msg, conn_setup_result.image_format);
                            maybe_get_img_sequence = null;
                            handled = true;
                        }
                    }

                    if (!handled) {
                        std.debug.panic("unexpected reply {}", .{msg});
                    }
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
                        &sequence,
                        screen.root_depth,
                        conn_setup_result.image_format,
                        ids,
                        font_dims,
                    );

                    if (maybe_get_img_sequence == null) {
                        var get_image_msg: [x11.get_image.len]u8 = undefined;
                        x11.get_image.serialize(&get_image_msg, .{
                            .format = .z_pixmap,
                            .drawable_id = ids.window().drawable(),
                            // Coords match where we drew the test image
                            .x = 100,
                            .y = 20,
                            .width = test_image.width,
                            .height = test_image.height,
                            .plane_mask = 0xffffffff,
                        });
                        try conn.sendOne(&sequence, &get_image_msg);
                        maybe_get_img_sequence = sequence;
                    }
                },
                .mapping_notify => |msg| {
                    std.log.info("mapping_notify: {}", .{msg});
                },
                .no_exposure => |msg| std.debug.panic("unexpected no_exposure {}", .{msg}),
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
                .destroy_notify => |msg| std.log.info("destroy_notify: {}", .{msg}),
                .unmap_notify => |msg| std.log.info("unmap_notify: {}", .{msg}),
                .map_notify => |msg| std.log.info("map_notify: {}", .{msg}),
                .reparent_notify => |msg| std.log.info("reparent_notify: {}", .{msg}),
                .configure_notify => |msg| std.log.info("configure_notify: {}", .{msg}),
            }
        }
    }
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

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

fn render(
    sock: std.posix.socket_t,
    sequence: *u16,
    depth: u8,
    image_format: ImageFormat,
    ids: Ids,
    font_dims: FontDims,
) !void {
    {
        var msg: [x11.poly_fill_rectangle.getLen(1)]u8 = undefined;
        x11.poly_fill_rectangle.serialize(&msg, .{
            .drawable_id = ids.window().drawable(),
            .gc_id = ids.bg_gc(),
        }, &[_]x11.Rectangle{
            .{ .x = 100, .y = 100, .width = 200, .height = 200 },
        });
        try common.sendOne(sock, sequence, &msg);
    }
    {
        var msg: [x11.clear_area.len]u8 = undefined;
        x11.clear_area.serialize(&msg, false, ids.window(), .{
            .x = 150,
            .y = 150,
            .width = 100,
            .height = 100,
        });
        try common.sendOne(sock, sequence, &msg);
    }

    try changeGcColor(sock, sequence, ids.fg_gc(), x11.rgb24To(0xffaadd, depth));
    {
        const text_literal: []const u8 = "ImageText8";
        const text: x11.Slice(u8, [*]const u8) = comptime .initComptime(text_literal);
        var msg: [x11.image_text8.getLen(text.len)]u8 = undefined;

        const text_width = font_dims.width * text_literal.len;

        x11.image_text8.serialize(&msg, text, .{
            .drawable_id = ids.window().drawable(),
            .gc_id = ids.fg_gc(),
            .x = @divTrunc((window_width - @as(i16, @intCast(text_width))), 2) + font_dims.font_left,
            .y = @divTrunc((window_height - @as(i16, @intCast(font_dims.height))), 2) + font_dims.font_ascent,
        });
        try common.sendOne(sock, sequence, &msg);
    }
    {
        const text_literal: []const u8 = "PolyText8";
        const items = comptime [_]x11.TextItem8{
            .{ .text_element = .{ .delta = 0, .string = .initComptime(text_literal) } },
        };
        var msg: [x11.poly_text8.getLen(&items)]u8 = undefined;

        const text_width = font_dims.width * text_literal.len;

        x11.poly_text8.serialize(&msg, &items, .{
            .drawable_id = ids.window().drawable(),
            .gc_id = ids.fg_gc(),
            .x = @divTrunc((window_width - @as(i16, @intCast(text_width))), 2) + font_dims.font_left,
            .y = @divTrunc((window_height - @as(i16, @intCast(font_dims.height))), 2) + font_dims.font_ascent + font_dims.height + 1,
        });
        try common.sendOne(sock, sequence, &msg);
    }

    try changeGcColor(sock, sequence, ids.fg_gc(), x11.rgb24To(0x00ff00, depth));
    {
        const rectangles = [_]x11.Rectangle{
            .{ .x = 20, .y = 20, .width = 15, .height = 15 },
            .{ .x = 40, .y = 20, .width = 15, .height = 15 },
        };
        var msg: [x11.poly_fill_rectangle.getLen(rectangles.len)]u8 = undefined;
        x11.poly_fill_rectangle.serialize(&msg, .{
            .drawable_id = ids.window().drawable(),
            .gc_id = ids.fg_gc(),
        }, &rectangles);
        try common.sendOne(sock, sequence, &msg);
    }
    try changeGcColor(sock, sequence, ids.fg_gc(), x11.rgb24To(0x0000ff, depth));
    {
        const rectangles = [_]x11.Rectangle{
            .{ .x = 60, .y = 20, .width = 15, .height = 15 },
            .{ .x = 80, .y = 20, .width = 15, .height = 15 },
        };
        var msg: [x11.poly_rectangle.getLen(rectangles.len)]u8 = undefined;
        x11.poly_rectangle.serialize(&msg, .{
            .drawable_id = ids.window().drawable(),
            .gc_id = ids.fg_gc(),
        }, &rectangles);
        try common.sendOne(sock, sequence, &msg);
    }

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
        var put_image_msg: [x11.put_image.getLen(test_image.max_data_len)]u8 = undefined;
        populateTestImage(
            image_format,
            test_image.width,
            test_image.height,
            test_image_scanline_len,
            put_image_msg[x11.put_image.data_offset..],
        );
        x11.put_image.serializeNoDataCopy(&put_image_msg, test_image_data_len, .{
            .format = .z_pixmap,
            .drawable_id = ids.window().drawable(),
            .gc_id = ids.fg_gc(),
            .width = test_image.width,
            .height = test_image.height,
            .x = 100,
            .y = 20,
            .left_pad = 0,
            .depth = image_format.depth,
        });
        try common.sendOne(sock, sequence, put_image_msg[0..x11.put_image.getLen(test_image_data_len)]);

        // test a pixmap
        {
            var msg: [x11.create_pixmap.len]u8 = undefined;
            x11.create_pixmap.serialize(&msg, .{
                .id = ids.pixmap(),
                .drawable_id = ids.window().drawable(),
                .depth = image_format.depth,
                .width = test_image.width,
                .height = test_image.height,
            });
            try common.sendOne(sock, sequence, &msg);
        }
        x11.put_image.serializeNoDataCopy(&put_image_msg, test_image_data_len, .{
            .format = .z_pixmap,
            .drawable_id = ids.pixmap().drawable(),
            .gc_id = ids.fg_gc(),
            .width = test_image.width,
            .height = test_image.height,
            .x = 0,
            .y = 0,
            .left_pad = 0,
            .depth = image_format.depth,
        });
        try common.sendOne(sock, sequence, put_image_msg[0..x11.put_image.getLen(test_image_data_len)]);

        {
            var msg: [x11.copy_area.len]u8 = undefined;
            x11.copy_area.serialize(&msg, .{
                .src_drawable_id = ids.pixmap().drawable(),
                .dst_drawable_id = ids.window().drawable(),
                .gc_id = ids.fg_gc(),
                .src_x = 0,
                .src_y = 0,
                .dst_x = 120,
                .dst_y = 20,
                .width = test_image.width,
                .height = test_image.height,
            });
            try common.sendOne(sock, sequence, &msg);
        }

        {
            var msg: [x11.free_pixmap.len]u8 = undefined;
            x11.free_pixmap.serialize(&msg, ids.pixmap());
            try common.sendOne(sock, sequence, &msg);
        }
    }
}

fn changeGcColor(sock: std.posix.socket_t, sequence: *u16, gc_id: x11.GraphicsContext, color: u32) !void {
    var msg_buf: [x11.change_gc.max_len]u8 = undefined;
    const len = x11.change_gc.serialize(&msg_buf, gc_id, .{
        .foreground = color,
    });
    try common.sendOne(sock, sequence, msg_buf[0..len]);
}

fn getTestImagePixel(row: usize) u24 {
    if (row < 5) return 0xff0000;
    if (row < 10) return 0xff00;
    return 0xff;
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

        const color: u24 = getTestImagePixel(row);

        var col: usize = 0;
        while (col < width) : (col += 1) {
            switch (image_format.depth) {
                16 => std.mem.writeInt(
                    u16,
                    data[data_off..][0..2],
                    x11.rgb24To16(color),
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
                    x11.rgb24To(color, 32),
                    image_format.endian,
                ),
                else => std.debug.panic("TODO: implement image depth {}", .{image_format.depth}),
            }
            data_off += (image_format.bits_per_pixel / 8);
        }
    }
}

/// Grab the pixels from the window after we've rendered to it using `get_image` and
/// check that the test image pattern was *actually* drawn to the window.
fn checkTestImageIsDrawnToWindow(
    msg_reply: *x11.ServerMsg.Reply,
    image_format: ImageFormat,
) !void {
    const msg: *x11.get_image.Reply = @ptrCast(msg_reply);
    const image_data = msg.getData();

    // Given our request for an image with the width/height specified,
    // make sure we got at least the right amount of data back to
    // represent that size of image (there may also be padding at the
    // end).
    std.debug.assert(image_data.len >= (test_image.width * test_image.height * x11.get_image.Reply.scanline_pad_bytes));
    // Currently, we only support one image format that matches the root window depth
    std.debug.assert(msg.depth == image_format.depth);

    const bytes_per_pixel_in_data = x11.get_image.Reply.scanline_pad_bytes;

    var width_index: u16 = 0;
    var height_index: u16 = 0;
    var image_data_index: u32 = 0;
    while ((image_data_index + bytes_per_pixel_in_data) < image_data.len) : (image_data_index += bytes_per_pixel_in_data) {
        if (width_index >= test_image.width) {
            // For Debugging: Print a newline after each row
            // std.debug.print("\n", .{});
            width_index = 0;
            height_index += 1;
        }

        //  The image data might have padding on the end so make sure to stop when we expect the image to end
        if (height_index >= test_image.height) {
            break;
        }

        const padded_pixel_value = image_data[image_data_index..(image_data_index + bytes_per_pixel_in_data)];
        const pixel_value = std.mem.readVarInt(
            u32,
            padded_pixel_value,
            image_format.endian,
        );
        // For Debugging: Print out the pixels
        //std.debug.print("pixel_value=0x{x}\n", .{pixel_value});

        // Assert test image pattern
        const actual_pixel = 0xffffff & pixel_value;
        const expected_pixel = getTestImagePixel(height_index);
        if (actual_pixel != expected_pixel) {
            std.debug.panic(
                "expected pixel at row {} to be 0x{x} but got 0x{x}",
                .{ height_index, expected_pixel, actual_pixel },
            );
        }
        //std.debug.assert(pixel_value == expected_pixel);
        // if (height_index < 5) { std.debug.assert(pixel_value == 0xffff0000); }
        // else if (height_index < 10) { std.debug.assert(pixel_value == 0xff00ff00); }
        // else { std.debug.assert(pixel_value == 0xff0000ff); }

        width_index += 1;
    }
}
