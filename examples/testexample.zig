// A working example to test various parts of the API
const std = @import("std");
const x11 = @import("x11");

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
    // For the X Render extension part of this example
    pub fn picture_root(self: Ids) x11.render.Picture {
        return self.base.add(4).picture();
    }
    pub fn picture_window(self: Ids) x11.render.Picture {
        return self.base.add(5).picture();
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
        "expected reply sequence {} but got {f}",
        .{ expected_sequence, reply },
    );
}

/// Sanity check that we're not running into data integrity (corruption) issues caused
/// by overflowing and wrapping around to the front ofq the buffer.
fn checkMessageLengthFitsInBuffer(message_length: usize, buffer_limit: usize) !void {
    if (message_length > buffer_limit) {
        std.debug.panic("Reply is bigger than our buffer (data corruption will ensue) {} > {}. " ++
            "In order to fix, increase the buffer size.", .{
            message_length,
            buffer_limit,
        });
    }
}

/// Find a picture format that matches the desired attributes like depth.
/// In the future, we might want to match against more things like which screen it came from, etc.
pub fn findMatchingPictureFormat(
    formats: []const x11.render.PictureFormatInfo,
    desired_depth: u8,
) !x11.render.PictureFormatInfo {
    for (formats) |format| {
        if (format.depth != desired_depth) continue;
        return format;
    }
    return error.VisualTypeNotFound;
}

pub fn main() !u8 {
    try x11.wsaStartup();
    const conn = try x11.ext.connect(allocator);
    defer std.posix.shutdown(conn.sock, .both) catch {};

    var write_buf: [4096]u8 = undefined;
    var socket_writer = x11.socketWriter(conn.sock, &write_buf);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };

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

    try sink.CreateWindow(.{
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

    const double_buf = try x11.DoubleBuffer.init(
        // 8000 is arbitrary but this needs to be big enough to hold the biggest reply
        // we expect to receive. For example, the `query_pict_formats` reply is 4888
        // bytes on my system.
        std.mem.alignForward(usize, 8000, std.heap.pageSize()),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    defer double_buf.deinit(); // not necessary but good to test
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();
    const buffer_limit = buf.half_len;

    // Set the window name
    try sink.ChangeProperty(
        .replace,
        ids.window(),
        .WM_NAME,
        .STRING,
        u8,
        .initComptime("zigx Test Example"),
    );

    // Test `get_property` by retrieving the property we just set
    try sink.GetProperty(ids.window(), .{
        .property = .WM_NAME,
        .type = .STRING,
        .offset = 0,
        .len = 64,
        .delete = false,
    });
    const get_window_name_sequence = sink.sequence;
    try sink.writer.flush();

    var reader: x11.SocketReader = .init(conn.sock);

    _ = try x11.readOneMsg(reader.interface(), @alignCast(buf.nextReadBuffer()));
    switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
        .reply => |msg_reply| {
            expectSequence(get_window_name_sequence, msg_reply);
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
            std.log.err("expected a reply for GetProperty but got {f}", .{msg});
            return error.ExpectedReplyForGetProperty;
        },
    }

    // Test `query_tree` by finding our own window in the list of children of the root
    // window
    try sink.QueryTree(screen.root);
    const query_tree_sequence = sink.sequence;
    try sink.writer.flush();
    _ = try x11.readOneMsg(reader.interface(), @alignCast(buf.nextReadBuffer()));
    switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
        .reply => |msg_reply| {
            expectSequence(query_tree_sequence, msg_reply);
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
            std.log.err("expected a reply for `x11.query_tree` but got {f}", .{msg});
            return error.ExpectedReplyForQueryTree;
        },
    }

    // test creating/freeing GCs
    for (0..3) |_| {
        try sink.CreateGc(
            ids.bg_gc(),
            ids.window().drawable(),
            .{ .foreground = screen.black_pixel },
        );
        try sink.writer.flush();
        try sink.FreeGc(ids.bg_gc());
        try sink.writer.flush();
    }

    try sink.CreateGc(
        ids.bg_gc(),
        ids.window().drawable(),
        .{ .foreground = screen.black_pixel },
    );
    try sink.CreateGc(
        ids.fg_gc(),
        ids.window().drawable(),
        .{
            .background = screen.black_pixel,
            .foreground = x11.rgb24To(0xffaadd, screen.root_depth),
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
        },
    );

    // get some font information

    {
        const text_literal = [_]u16{'m'};
        const text = x11.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        try sink.QueryTextExtents(ids.fg_gc().fontable(), text);
    }
    const query_text_sequence = sink.sequence;

    const font_dims: FontDims = blk: {
        try sink.writer.flush();
        const message_length = try x11.readOneMsg(reader.interface(), @alignCast(buf.nextReadBuffer()));
        try checkMessageLengthFitsInBuffer(message_length, buffer_limit);
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                expectSequence(query_text_sequence, msg_reply);
                const msg: *x11.ServerMsg.QueryTextExtents = @ptrCast(msg_reply);
                break :blk .{
                    .width = @intCast(msg.overall_width),
                    .height = @intCast(msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(msg.overall_left),
                    .font_ascent = msg.font_ascent,
                };
            },
            else => |msg| {
                std.log.err("expected a reply but got {f}", .{msg});
                return 1;
            },
        }
    };

    const opt_render_ext = try x11.ext.getExtensionInfo(
        conn.sock,
        &sink,
        &buf,
        x11.render.name,
    );
    if (opt_render_ext) |render_ext| {
        const expected_version: x11.ext.ExtensionVersion = .{ .major_version = 0, .minor_version = 10 };
        try x11.render.QueryVersion(&sink, .{
            .ext_opcode = render_ext.opcode,
            .major_version = expected_version.major_version,
            .minor_version = expected_version.minor_version,
        });
        const sequence = sink.sequence;
        try sink.writer.flush();
        {
            const message_length = try x11.readOneMsg(reader.interface(), @alignCast(buf.nextReadBuffer()));
            try checkMessageLengthFitsInBuffer(message_length, buffer_limit);
        }
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                expectSequence(sequence, msg_reply);
                const msg: *x11.render.QueryVersionReply = @ptrCast(msg_reply);
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
                std.log.err("expected a reply but got {f}", .{msg});
                return 1;
            },
        }

        // Find some compatible picture formats for use with the X Render extension. We want
        // to find a 24-bit depth format for use with the root and our window.
        try x11.render.QueryPictFormats(&sink, render_ext.opcode);
        try sink.writer.flush();
        {
            const message_length = try x11.readOneMsg(reader.interface(), @alignCast(buf.nextReadBuffer()));
            try checkMessageLengthFitsInBuffer(message_length, buffer_limit);
        }
        const pict_formats_data: ?struct { matching_picture_format: x11.render.PictureFormatInfo } = blk: {
            switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
                .reply => |msg_reply| {
                    const msg: *x11.render.query_pict_formats.Reply = @ptrCast(msg_reply);
                    std.log.info("RENDER extension: pict formats num_formats={}, num_screens={}, num_depths={}, num_visuals={}", .{
                        msg.num_formats,
                        msg.num_screens,
                        msg.num_depths,
                        msg.num_visuals,
                    });
                    for (msg.getPictureFormats(), 0..) |format, i| {
                        std.log.info("RENDER extension: pict format ({}) {any}", .{
                            i,
                            format,
                        });
                    }
                    break :blk .{
                        .matching_picture_format = try findMatchingPictureFormat(
                            msg.getPictureFormats()[0..],
                            screen.root_depth,
                        ),
                    };
                },
                else => |msg| {
                    std.log.err("expected a reply but got {f}", .{msg});
                    return 1;
                },
            }
        };
        const matching_picture_format = pict_formats_data.?.matching_picture_format;

        // We need to create a picture for every drawable that we want to use with the X
        // Render extension
        // =============================================================================
        //
        // Create a picture for the root window that we will copy from in this example
        try x11.render.CreatePicture(
            &sink,
            render_ext.opcode,
            ids.picture_root(),
            screen.root.drawable(),
            matching_picture_format.picture_format_id,
            .{
                // We want to include (`.include_inferiors`) and sub-windows when we
                // copy from the root window. Otherwise, by default, the root window
                // would be clipped (`.clip_by_children`) by any sub-window on top.
                .subwindow_mode = .include_inferiors,
            },
        );

        // Create a picture for the our window that we can copy and composite things onto
        try x11.render.CreatePicture(
            &sink,
            render_ext.opcode,
            ids.picture_window(),
            ids.window().drawable(),
            matching_picture_format.picture_format_id,
            .{ .subwindow_mode = .include_inferiors },
        );
    }

    const opt_shape_ext = try x11.ext.getExtensionInfo(conn.sock, &sink, &buf, "SHAPE");
    if (opt_shape_ext) |shape_ext| {
        const expected_version: x11.ext.ExtensionVersion = .{ .major_version = 1, .minor_version = 1 };

        try x11.shape.QueryVersion(&sink, shape_ext.opcode);
        const sequence = sink.sequence;
        try sink.writer.flush();

        const message_length = try x11.readOneMsg(reader.interface(), @alignCast(buf.nextReadBuffer()));
        try checkMessageLengthFitsInBuffer(message_length, buffer_limit);
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                expectSequence(sequence, msg_reply);
                const msg: *x11.shape.QueryVersionReply = @ptrCast(msg_reply);
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
                std.log.err("expected a reply but got {f}", .{msg});
                return 1;
            },
        }
    }

    const opt_test_ext = try x11.ext.getExtensionInfo(conn.sock, &sink, &buf, "XTEST");
    if (opt_test_ext) |test_ext| {
        const expected_version: x11.ext.ExtensionVersion = .{ .major_version = 2, .minor_version = 2 };

        try x11.testext.GetVersion(&sink, .{
            .ext_opcode = test_ext.opcode,
            .wanted_major_version = expected_version.major_version,
            .wanted_minor_version = expected_version.minor_version,
        });
        const sequence = sink.sequence;
        try sink.writer.flush();

        _ = try x11.readOneMsg(reader.interface(), @alignCast(buf.nextReadBuffer()));
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                expectSequence(sequence, msg_reply);
                const msg: *x11.testext.GetVersionReply = @ptrCast(msg_reply);
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
                std.log.err("expected a reply but got {f}", .{msg});
                return 1;
            },
        }
    }

    try sink.MapWindow(ids.window());

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

    // This will probably happen by default when you `map_window` (I'm guessing it
    // depends on your window manager) but we can be extra annoying and always bring
    // the window to the front (just testing this request out).
    try sink.ConfigureWindow(ids.window(), .{
        .stack_mode = .above,
    });

    var maybe_get_img_sequence: ?u16 = null;

    while (true) {
        try sink.writer.flush();

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
                    std.log.err("Received X error: {f}", .{msg});
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
                        std.debug.panic("unexpected reply {f}", .{msg});
                    }
                },
                .generic_extension_event => |msg| {
                    std.log.info("TODO: handle a generic extension event {}", .{msg});
                    return error.TodoHandleGenericExtensionEvent;
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
                        &sink,
                        screen.root_depth,
                        conn_setup_result.image_format,
                        ids,
                        font_dims,

                        opt_render_ext,
                    );

                    if (maybe_get_img_sequence == null) {
                        try sink.GetImage(.{
                            .format = .z_pixmap,
                            .drawable = ids.window().drawable(),
                            // Coords match where we drew the test image
                            .x = 100,
                            .y = 20,
                            .width = test_image.width,
                            .height = test_image.height,
                            .plane_mask = 0xffffffff,
                        });
                        maybe_get_img_sequence = sink.sequence;
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
    sink: *x11.RequestSink,
    depth: u8,
    image_format: ImageFormat,
    ids: Ids,
    font_dims: FontDims,
    opt_render_ext: ?x11.ext.ExtensionInfo,
) !void {
    try sink.PolyFillRectangle(
        ids.window().drawable(),
        ids.bg_gc(),
        .initComptime(&[_]x11.Rectangle{
            .{ .x = 100, .y = 100, .width = 200, .height = 200 },
        }),
    );
    try sink.ClearArea(ids.window(), .{
        .x = 150,
        .y = 150,
        .width = 100,
        .height = 100,
    }, .{ .exposures = false });
    try sink.ChangeGc(ids.fg_gc(), .{
        .foreground = x11.rgb24To(0xffaadd, depth),
    });

    {
        const text = "ImageText8";
        const text_width = font_dims.width * text.len;
        try sink.ImageText8(
            ids.window().drawable(),
            ids.fg_gc(),
            .{
                .x = @divTrunc((window_width - @as(i16, @intCast(text_width))), 2) + font_dims.font_left,
                .y = @divTrunc((window_height - @as(i16, @intCast(font_dims.height))), 2) + font_dims.font_ascent,
            },
            .initComptime(text),
        );
    }

    {
        const text: []const u8 = "PolyText8";
        const text_width = font_dims.width * text.len;
        try sink.PolyText8(
            ids.window().drawable(),
            ids.fg_gc(),
            .{
                .x = @divTrunc((window_width - @as(i16, @intCast(text_width))), 2) + font_dims.font_left,
                .y = @divTrunc((window_height - @as(i16, @intCast(font_dims.height))), 2) + font_dims.font_ascent + font_dims.height + 1,
            },
            &[_]x11.TextItem8{
                .{ .text_element = .{ .delta = 0, .string = .initComptime(text) } },
            },
        );
    }
    try sink.ChangeGc(ids.fg_gc(), .{
        .foreground = x11.rgb24To(0x00ff00, depth),
    });
    try sink.PolyFillRectangle(
        ids.window().drawable(),
        ids.fg_gc(),
        .initComptime(&[_]x11.Rectangle{
            .{ .x = 20, .y = 20, .width = 15, .height = 15 },
            .{ .x = 40, .y = 20, .width = 15, .height = 15 },
        }),
    );
    try sink.ChangeGc(ids.fg_gc(), .{
        .foreground = x11.rgb24To(0x0000ff, depth),
    });
    try sink.PolyRectangle(
        ids.window().drawable(),
        ids.fg_gc(),
        .initComptime(&[_]x11.Rectangle{
            .{ .x = 60, .y = 20, .width = 15, .height = 15 },
            .{ .x = 80, .y = 20, .width = 15, .height = 15 },
        }),
    );
    try sink.writer.flush();
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
        var offset = try sink.PutImageStart(.{
            .format = .z_pixmap,
            .drawable = ids.window().drawable(),
            .gc_id = ids.fg_gc(),
            .width = test_image.width,
            .height = test_image.height,
            .x = 100,
            .y = 20,
            .left_pad = 0,
            .depth = image_format.depth,
        }, test_image_data_len);
        try writeTestImage(
            image_format,
            test_image.width,
            test_image.height,
            test_image_scanline_len,
            sink.writer,
        );
        offset += @as(usize, test_image.height) * @as(usize, test_image_scanline_len);
        try sink.PutImageFinish(test_image_data_len, offset);
    }

    // test a pixmap
    try sink.CreatePixmap(ids.pixmap(), ids.window().drawable(), .{
        .depth = image_format.depth,
        .width = test_image.width,
        .height = test_image.height,
    });

    {
        var offset = try sink.PutImageStart(.{
            .format = .z_pixmap,
            .drawable = ids.window().drawable(),
            .gc_id = ids.fg_gc(),
            .width = test_image.width,
            .height = test_image.height,
            .x = 0,
            .y = 0,
            .left_pad = 0,
            .depth = image_format.depth,
        }, test_image_data_len);
        try writeTestImage(
            image_format,
            test_image.width,
            test_image.height,
            test_image_scanline_len,
            sink.writer,
        );
        offset += @as(usize, test_image.height) * @as(usize, test_image_scanline_len);
        try sink.PutImageFinish(test_image_data_len, offset);
    }

    try sink.CopyArea(.{
        .src_drawable = ids.pixmap().drawable(),
        .dst_drawable = ids.window().drawable(),
        .gc = ids.fg_gc(),
        .src_x = 0,
        .src_y = 0,
        .dst_x = 120,
        .dst_y = 20,
        .width = test_image.width,
        .height = test_image.height,
    });

    try sink.FreePixmap(ids.pixmap());

    if (opt_render_ext) |render_ext| {
        // Capture a small 100x100 screenshot of the top-left of the root window and
        // composite it onto our window.
        try x11.render.Composite(sink, render_ext.opcode, .{
            .picture_operation = .over,
            .src_picture = ids.picture_root(),
            .mask_picture = x11.render.Picture.none,
            .dst_picture = ids.picture_window(),
            .src_x = 0,
            .src_y = 0,
            .mask_x = 0,
            .mask_y = 0,
            .dst_x = 50,
            .dst_y = 50,
            .width = 100,
            .height = 100,
        });
    }
}

fn getTestImagePixel(row: usize) u24 {
    if (row < 5) return 0xff0000;
    if (row < 10) return 0xff00;
    return 0xff;
}

fn writeTestImage(
    image_format: ImageFormat,
    width: u16,
    height: u16,
    stride: usize,
    writer: *x11.Writer,
) x11.Writer.Error!void {
    if ((image_format.bits_per_pixel % 8) != 0) @panic("todo");
    const row_pixel_size = @divExact(image_format.bits_per_pixel, 8) * width;
    std.debug.assert(stride >= row_pixel_size);
    const row_padding = stride - row_pixel_size;

    const pixel_padding_size = (image_format.bits_per_pixel - image_format.depth) / 8;

    var row: usize = 0;
    while (row < height) : (row += 1) {
        const color: u24 = getTestImagePixel(row);

        var col: usize = 0;
        while (col < width) : (col += 1) {
            switch (image_format.depth) {
                // currently assumes bpp is 16
                16 => try writer.writeInt(
                    u16,
                    x11.rgb24To16(color),
                    image_format.endian,
                ),
                // currently assumes bpp is 24
                24 => try writer.writeInt(
                    u24,
                    color,
                    image_format.endian,
                ),
                // currently assumes bpp is 32
                32 => try writer.writeInt(
                    u32,
                    x11.rgb24To(color, 32),
                    image_format.endian,
                ),
                else => std.debug.panic("TODO: implement image depth {}", .{image_format.depth}),
            }
            try writer.splatByteAll(0, pixel_padding_size);
        }
        try writer.splatByteAll(0, row_padding);
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
