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
    formats: []const x11.Format,
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

pub fn main() !u8 {
    try x11.wsaStartup();
    const display = x11.getDisplay();
    std.log.info("DISPLAY '{s}'", .{display});
    const parsed_display = x11.parseDisplay(display) catch |err| {
        std.log.err("invalid display '{s}': {s}", .{ display, @errorName(err) });
        std.process.exit(0xff);
    };

    const stream = x11.connect(display, parsed_display) catch |err| {
        std.log.err("failed to connect to display '{s}': {s}", .{ display, @errorName(err) });
        std.process.exit(0xff);
    };
    defer std.posix.shutdown(stream.handle, .both) catch {};

    var write_buf: [1000]u8 = undefined;
    var read_buf: [1000]u8 = undefined;
    var socket_writer = x11.socketWriter(stream, &write_buf);
    var socket_reader = x11.socketReader(stream, &read_buf);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .{ .reader = socket_reader.interface() };

    const setup = switch (try x11.ext.authenticate(sink.writer, &source, .{
        .display_num = parsed_display.display_num,
        .socket = stream.handle,
    })) {
        .failed => |reason| {
            x11.log.err("auth failed: {f}", .{reason});
            std.process.exit(0xff);
        },
        .success => |reply_len| reply_len,
    };
    std.log.info("setup reply {}", .{setup});
    try source.requireReplyAtLeast(setup.required());
    if (x11.zig_atleast_15) {
        var used = false;
        const fmt = source.fmtReplyData(setup.vendor_len, &used);
        x11.log.info("vendor '{f}'", .{fmt});
        std.debug.assert(used == true);
    } else {
        try source.replyDiscard(setup.vendor_len);
    }
    try source.replyDiscard(x11.pad4Len(@truncate(setup.vendor_len)));

    const screen, const image_format = blk: {
        const image_endian: Endian = switch (setup.image_byte_order) {
            .lsb_first => .little,
            .msb_first => .big,
            else => |order| {
                std.log.err("unknown image-byte-order {}", .{order});
                return 0xff;
            },
        };

        var formats_buf: [std.math.maxInt(u8)]x11.Format = undefined;
        const formats = formats_buf[0..setup.format_count];
        for (formats, 0..) |*format, i| {
            try source.readReply(std.mem.asBytes(format));
            std.log.info(
                "format[{}] depth={} bpp={} scanlinepad={}",
                .{ i, format.depth, format.bits_per_pixel, format.scanline_pad },
            );
        }

        var first_screen: ?x11.ScreenHeader = null;

        for (0..setup.root_screen_count) |screen_index| {
            try source.requireReplyAtLeast(@sizeOf(x11.ScreenHeader));
            var screen_header: x11.ScreenHeader = undefined;
            try source.readReply(std.mem.asBytes(&screen_header));
            std.log.info("screen {} | {}", .{ screen_index, screen_header });
            if (first_screen == null) {
                first_screen = screen_header;
            }
            try source.requireReplyAtLeast(@as(u35, screen_header.allowed_depth_count) * @sizeOf(x11.ScreenDepth));
            for (0..screen_header.allowed_depth_count) |depth_index| {
                var depth: x11.ScreenDepth = undefined;
                try source.readReply(std.mem.asBytes(&depth));
                try source.requireReplyAtLeast(@as(u35, depth.visual_type_count) * @sizeOf(x11.VisualType));
                std.log.info("screen {} | depth {} | {}", .{ screen_index, depth_index, depth });
                for (0..depth.visual_type_count) |visual_index| {
                    var visual: x11.VisualType = undefined;
                    try source.readReply(std.mem.asBytes(&visual));
                    if (false) std.log.info("screen {} | depth {} | visual {} | {}\n", .{ screen_index, depth_index, visual_index, visual });
                }
            }
        }

        const remaining = source.replyRemainingSize();
        if (remaining != 0) {
            x11.log.err("setup reply had an extra {} bytes", .{remaining});
            return error.X11Protocol;
        }

        const screen = first_screen orelse {
            std.log.err("no screen?", .{});
            std.process.exit(0xff);
        };

        break :blk .{
            screen,
            getImageFormat(
                image_endian,
                formats,
                screen.root_depth,
            ) catch |err| {
                std.log.err("can't resolve root depth {} format: {s}", .{ screen.root_depth, @errorName(err) });
                return 0xff;
            },
        };
    };

    const ids = Ids{ .base = setup.resource_id_base };

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
        .bg_pixel = x11.rgbFrom24(screen.root_depth, 0xbbccdd),
        .event_mask = .{
            .KeymapState = 1,
            .Exposure = 1,
            .StructureNotify = 1,
        },
    });

    // Set the window name
    const window_name = "ZigX Test Example";
    try sink.ChangeProperty(
        .replace,
        ids.window(),
        .WM_NAME,
        .STRING,
        u8,
        .initComptime(window_name),
    );

    // Test `get_property` by retrieving the property we just set
    try sink.GetProperty(ids.window(), .{
        .property = .WM_NAME,
        .type = .STRING,
        .offset = 0,
        .len = 64,
        .delete = false,
    });
    try sink.writer.flush();
    {
        const prop, const format = try source.readSynchronousReplyHeader(sink.sequence, .GetProperty);
        std.debug.assert(format == 8);
        const value_len = prop.value_size_in_format_units;
        const pad_len = x11.pad4Len(@truncate(value_len));
        try source.requireReplyExact(value_len + pad_len);
        std.debug.assert(prop.value_size_in_format_units == window_name.len);
        var buf: [window_name.len]u8 = undefined;
        try source.readReply(&buf);
        std.debug.assert(std.mem.eql(u8, &buf, window_name));
        try source.replyDiscard(pad_len);
    }

    // Test `query_tree` by finding our own window in the list of children of the root window
    try sink.QueryTree(screen.root);
    try sink.writer.flush();
    {
        const tree, _ = try source.readSynchronousReplyHeader(sink.sequence, .QueryTree);
        std.log.info("root window count={}", .{tree.window_count});
        try source.requireReplyExact(tree.window_count * 4);
        var found_window: bool = false;
        for (0..tree.window_count) |_| {
            const child: x11.Window = .fromInt(try source.takeReplyInt(u32));
            if (child == ids.window()) {
                found_window = true;
            }
        }
        if (!found_window) std.debug.panic(
            "our window {} was not in the tree",
            .{@intFromEnum(ids.window())},
        );
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
            .foreground = x11.rgbFrom24(screen.root_depth, 0xffaadd),
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
        },
    );

    const font_dims: FontDims = blk: {
        try sink.QueryTextExtents(ids.fg_gc().fontable(), .initComptime(&[_]u16{'m'}));
        try sink.writer.flush();
        const extents, _ = try source.readSynchronousReplyFull(sink.sequence, .QueryTextExtents);
        std.log.info("text extents: {}", .{extents});
        break :blk .{
            .width = @intCast(extents.overall_width),
            .height = @intCast(extents.font_ascent + extents.font_descent),
            .font_left = @intCast(extents.overall_left),
            .font_ascent = extents.font_ascent,
        };
    };

    var maybe_picture_format: ?x11.render.PictureFormatInfo = null;

    const opt_render_ext = try x11.ext.synchronousQueryExtension(&source, &sink, x11.render.name);
    if (opt_render_ext) |render_ext| {
        {
            const expected_version_major = 0;
            const expected_version_minor = 10;
            try x11.render.request.QueryVersion(&sink, .{
                .ext_opcode = render_ext.opcode,
                .major_version = expected_version_major,
                .minor_version = expected_version_minor,
            });
            try sink.writer.flush();
            const version, _ = try source.readSynchronousReplyFull(sink.sequence, .RENDER_QueryVersion);
            std.log.info("RENDER version {}.{}", .{ version.major, version.minor });
            if (version.major != expected_version_major) {
                std.log.err("RENDER major version is {} but we expect {}", .{
                    version.major,
                    expected_version_major,
                });
                return 1;
            }
            if (version.minor < expected_version_minor) {
                std.log.err("RENDER minor version is {}.{} but I've only tested >= {}.{})", .{
                    version.major,
                    version.minor,
                    expected_version_major,
                    expected_version_minor,
                });
                return 1;
            }
        }

        // Find some compatible picture formats for use with the X Render extension. We want
        // to find a 24-bit depth format for use with the root and our window.
        try x11.render.QueryPictFormats(&sink, render_ext.opcode);
        try sink.writer.flush();
        const result, _ = try source.readSynchronousReplyHeader(sink.sequence, .RENDER_QueryPictFormats);
        std.log.info(
            "RENDER extension: pict formats num_formats={} num_screens={} num_depths={} num_visuals={}",
            .{
                result.num_formats,
                result.num_screens,
                result.num_depths,
                result.num_visuals,
            },
        );

        for (0..result.num_formats) |format_index| {
            var format: x11.render.PictureFormatInfo = undefined;
            try source.readReply(std.mem.asBytes(&format));
            std.log.info("RENDER extension: PictFormat[{}] {f}", .{ format_index, format });
            // TODO: use more than just the depth to match a format
            if (format.depth == screen.root_depth) {
                if (maybe_picture_format == null) {
                    maybe_picture_format = format;
                }
            }
        }
        // NOTE: there is stil two more lists we could read
        try source.replyDiscard(source.replyRemainingSize());

        if (maybe_picture_format) |format| {
            std.log.info("using format {f}", .{format});
        } else {
            std.log.info("no format that matches depth {}", .{screen.root_depth});
        }
    }

    if (maybe_picture_format) |picture_format| {
        // We need to create a picture for every drawable that we want to use with the X
        // Render extension
        // =============================================================================
        //
        // Create a picture for the root window that we will copy from in this example
        try x11.render.CreatePicture(
            &sink,
            opt_render_ext.?.opcode,
            ids.picture_root(),
            screen.root.drawable(),
            picture_format.id,
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
            opt_render_ext.?.opcode,
            ids.picture_window(),
            ids.window().drawable(),
            picture_format.id,
            .{ .subwindow_mode = .include_inferiors },
        );
    }

    const opt_shape_ext = try x11.ext.synchronousQueryExtension(&source, &sink, x11.shape.name);
    if (opt_shape_ext) |shape_ext| {
        try x11.shape.QueryVersion(&sink, shape_ext.opcode);
        try sink.writer.flush();
        try sink.writer.flush();
        const version, _ = try source.readSynchronousReplyFull(sink.sequence, .SHAPE_QueryVersion);
        std.log.info("SHAPE version {}.{}", .{ version.major, version.minor });
        if (version.major != 1) std.debug.panic("unsupported SHAPE version {}", .{version.major});
    }

    const opt_test_ext = try x11.ext.synchronousQueryExtension(&source, &sink, x11.testext.name);
    if (opt_test_ext) |test_ext| {
        const expected_version_major = 2;
        const expected_version_minor = 2;
        try x11.testext.GetVersion(&sink, .{
            .ext_opcode = test_ext.opcode,
            .wanted_major_version = expected_version_major,
            .wanted_minor_version = expected_version_minor,
        });
        try sink.writer.flush();
        const version, const version_major = try source.readSynchronousReplyFull(sink.sequence, .XTEST_GetVersion);
        std.log.info("XTEST version {}.{}", .{ version_major, version.minor });
        if (version_major != expected_version_major) std.debug.panic("unsupported XTEST version {}", .{version_major});
    }

    try sink.MapWindow(ids.window());

    // Send a fake mouse left-click event
    if (opt_test_ext) |test_ext| {
        std.log.info("sending fake button press/release...", .{});
        try x11.testext.FakeInput(&sink, test_ext.opcode, .{
            .button_press = .{
                .event_type = x11.testext.FakeEventType.button_press,
                .detail = 1,
                .delay_ms = 0,
                .device_id = null,
            },
        });
        try x11.testext.FakeInput(&sink, test_ext.opcode, .{
            .button_press = .{
                .event_type = x11.testext.FakeEventType.button_release,
                .detail = 1,
                .delay_ms = 0,
                .device_id = null,
            },
        });
        try sink.writer.flush();
    }

    // This will probably happen by default when you `map_window` (I'm guessing it
    // depends on your window manager) but we can be extra annoying and always bring
    // the window to the front (just testing this request out).
    try sink.ConfigureWindow(ids.window(), .{
        .stack_mode = .above,
    });

    var maybe_get_img_sequence: ?u16 = null;

    while (true) {
        try sink.writer.flush();
        const msg_kind = source.readKind() catch |err| return switch (err) {
            error.EndOfStream => {
                std.log.info("X11 connection closed (EndOfStream)", .{});
                std.process.exit(0);
            },
            else => |e| switch (socket_reader.getError() orelse e) {
                error.ConnectionResetByPeer => {
                    std.log.info("X11 connection closed (ConnectionReset)", .{});
                    return std.process.exit(0);
                },
                else => |e2| e2,
            },
        };
        switch (msg_kind) {
            .Reply => {
                const reply = try source.read2(.Reply);
                if (maybe_get_img_sequence) |s| {
                    if (s == reply.sequence) {
                        try checkTestImageIsDrawnToWindow(&source, reply, image_format);
                        maybe_get_img_sequence = null;
                    }
                }
                const remaining = source.replyRemainingSize();
                if (remaining != 0) {
                    std.debug.panic("unhandled Reply {f}", .{source.readFmt()});
                }
            },
            .KeymapNotify => {
                const notify = try source.read2(.KeymapNotify);
                std.log.info("{}", .{notify});
            },
            .Expose => {
                const expose = try source.read2(.Expose);
                std.log.info("{}", .{expose});
                try render(
                    &sink,
                    screen.root_depth,
                    image_format,
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
            .MappingNotify,
            .DestroyNotify,
            .UnmapNotify,
            .MapNotify,
            .ReparentNotify,
            .ConfigureNotify,
            => {
                std.log.info("X11 {f}", .{source.readFmt()});
                // ensures we still discard the rest of the message if logging is disabled
                try source.discardRemaining();
            },
            .ExtensionEvent => {
                std.log.info("TODO: handle a generic extension event {}", .{msg_kind});
                return error.TodoHandleGenericExtensionEvent;
            },
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
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
    opt_render_ext: ?x11.Extension,
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
        .foreground = x11.rgbFrom24(depth, 0xffaadd),
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
        .foreground = x11.rgbFrom24(depth, 0x00ff00),
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
        .foreground = x11.rgbFrom24(depth, 0x0000ff),
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
                    x11.rgb16From24(color),
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
                    x11.rgbFrom24(32, color),
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
    source: *x11.Source,
    reply: x11.servermsg.Reply,
    image_format: ImageFormat,
) !void {
    std.debug.assert(reply.flexible == image_format.depth);

    const image = try source.read3Header(.GetImage);
    _ = image;
    const image_size = source.replyRemainingSize();
    std.debug.assert(image_size % 3 == 0);

    const expected_image_size = test_image.width * test_image.height * 4;
    if (expected_image_size != image_size) std.debug.panic("expected image size {} but got {}", .{ expected_image_size, image_size });

    var width_index: u16 = 0;
    var height_index: u16 = 0;

    const log_image = false;

    for (0..image_size / 4) |_| {
        if (width_index >= test_image.width) {
            // For Debugging: Print a newline after each row
            if (log_image) std.debug.print("\n", .{});
            width_index = 0;
            height_index += 1;
        }

        //  The image data might have padding on the end so make sure to stop when we expect the image to end
        std.debug.assert(height_index < test_image.height);
        // if (height_index >= test_image.height) {
        //     break;
        // }
        const pixel_value_raw = try source.takeReplyInt(u32);
        const pixel_value = if (image_format.endian == x11.native_endian) pixel_value_raw else @byteSwap(pixel_value_raw);

        if (log_image) std.debug.print("pixel[{}][{}]=0x{x}\n", .{ height_index, width_index, pixel_value });

        const actual_pixel = 0xffffff & pixel_value;
        const expected_pixel = getTestImagePixel(height_index);
        if (actual_pixel != expected_pixel) std.debug.panic(
            "expected pixel at row {} to be 0x{x} but got 0x{x}",
            .{ height_index, expected_pixel, actual_pixel },
        );
        width_index += 1;
    }
    std.debug.assert(source.replyRemainingSize() == 0);
}
