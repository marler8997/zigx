//! An example of using the "Rendering" (RENDER)
const std = @import("std");
const x11 = @import("x11");
const common = @import("common.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 800;
const window_height = 600;

const Ids = struct {
    base: x11.ResourceBase,
    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn picture(self: Ids) x11.render.Picture {
        return self.base.add(1).picture();
    }
    pub fn glyphset(self: Ids) x11.render.GlyphSet {
        return self.base.add(2).glyph_set();
    }
    pub fn solid_picture(self: Ids) x11.render.Picture {
        return self.base.add(3).picture();
    }
};

fn createSimpleGlyphData(width: u16, height: u16) []u8 {
    const size = width * height;
    const data = allocator.alloc(u8, size) catch unreachable;

    // Create a simple filled rectangle glyph
    for (data) |*byte| {
        byte.* = 0xFF;
    }

    return data;
}

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
        break :blk screen;
    };

    var sequence: u16 = 0;
    const ids: Ids = .{ .base = conn.setup.fixed().resource_id_base };

    // Setup read buffer for receiving messages
    const double_buf = try x11.DoubleBuffer.init(
        std.mem.alignForward(usize, 4096, std.heap.pageSize()),
        .{ .memfd_name = "XRenderExample" },
    );
    var buf = double_buf.contiguousReadBuffer();

    // Query for XRender extension
    const maybe_render_ext = try common.getExtensionInfo(conn.sock, &sequence, &buf, x11.render.name.nativeSlice());
    if (maybe_render_ext == null) {
        std.log.err("RENDER extension not available", .{});
        return 1;
    }
    const render_ext_opcode = maybe_render_ext.?.opcode;
    std.log.info("RENDER opcode: {}", .{render_ext_opcode});

    // From the specification:
    //     > The client must negotiate the version of the extension before executing
    //     > extension requests.  Behavior of the server is undefined otherwise.
    {
        var msg_buf: [x11.render.query_version.len]u8 = undefined;
        x11.render.query_version.serialize(&msg_buf, render_ext_opcode, .{
            .major_version = 0,
            .minor_version = 11,
        });
        try conn.sendOne(&sequence, &msg_buf);
    }
    {
        const reader = common.SocketReader{ .context = conn.sock };
        _ = try x11.readOneMsg(reader, @alignCast(buf.nextReadBuffer()));
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const reply: *x11.render.query_version.Reply = @ptrCast(msg_reply);
                std.log.info("RENDER version: {}.{}", .{ reply.major_version, reply.minor_version });
                if (reply.major_version != 0) {
                    std.log.err("unsupported RENDER major version {}", .{reply.major_version});
                    return 1;
                }
                if (reply.minor_version < 11) {
                    std.log.err("unsupported RENDER minor version {}", .{reply.minor_version});
                    return 1;
                }
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return 1;
            },
        }
    }

    // Query picture formats to find a suitable format for glyphs
    {
        var msg_buf: [x11.render.query_pict_formats.len]u8 = undefined;
        x11.render.query_pict_formats.serialize(&msg_buf, render_ext_opcode);
        try conn.sendOne(&sequence, &msg_buf);
    }
    var glyph_format: x11.render.PictureFormat = undefined;
    var window_format: x11.render.PictureFormat = undefined;
    _ = &glyph_format;
    _ = &window_format;
    {
        const reader = common.SocketReader{ .context = conn.sock };
        const msg_len = try x11.readOneMsg(reader, @alignCast(buf.nextReadBuffer()));
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const reply: *x11.render.query_pict_formats.Reply = @ptrCast(msg_reply);
                std.log.info("reply (len={}) {}", .{ msg_len, reply });

                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                // TODO: verify the counts add up to the message length
                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

                // The data after the fixed reply header contains:
                // 1. PictFormInfo array (count = reply.num_formats)
                // 2. PictScreen array (count = reply.num_screens)
                // 3. Subpixel array (count = reply.num_subpixel)

                // Get pointer to the data after the fixed reply
                const data_ptr = @as([*]align(4) u8, @ptrCast(msg_reply)) + @sizeOf(x11.render.query_pict_formats.Reply);

                // Parse the PictFormInfo array
                const pict_format_infos = @as([*]align(4) x11.render.PictureFormatInfo, @ptrCast(data_ptr))[0..reply.num_formats];

                // Find suitable formats
                // Look for A8 format (8-bit alpha, typically used for glyphs)
                for (pict_format_infos, 0..) |format_info, index| {
                    std.log.info("PictFormat {}: id={} depth={} red(shift={},mask=0x{x}) green(shift={},mask=0x{x}) blue(shift={},mask=0x{x}) alpha(shift={},mask=0x{x})", .{
                        index,
                        @intFromEnum(format_info.id),
                        format_info.depth,
                        format_info.direct.red.shift,
                        format_info.direct.red.mask,
                        format_info.direct.green.shift,
                        format_info.direct.green.mask,
                        format_info.direct.blue.shift,
                        format_info.direct.blue.mask,
                        format_info.direct.alpha.shift,
                        format_info.direct.alpha.mask,
                    });
                    if (format_info.type == .direct and
                        format_info.depth == 8 and
                        format_info.direct.alpha.mask == 0xFF and
                        format_info.direct.red.mask == 0 and
                        format_info.direct.green.mask == 0 and
                        format_info.direct.blue.mask == 0)
                    {
                        glyph_format = format_info.id;
                        std.log.info("Found A8 glyph format: {}", .{glyph_format});
                        break;
                    }
                }

                // Find format matching window depth (typically 24 or 32 bit ARGB)
                for (pict_format_infos) |format_info| {
                    if (format_info.type == .direct and
                        format_info.depth == screen.root_depth)
                    {
                        window_format = format_info.id;
                        std.log.info("Found window format (depth {}): {}", .{ screen.root_depth, window_format });
                        break;
                    }
                }

                // Alternative: if you need a specific ARGB32 format
                for (pict_format_infos) |format_info| {
                    if (format_info.type == .direct and
                        format_info.depth == 32 and
                        format_info.direct.alpha.mask == 0xFF and
                        format_info.direct.alpha.shift == 24 and
                        format_info.direct.red.mask == 0xFF and
                        format_info.direct.red.shift == 16 and
                        format_info.direct.green.mask == 0xFF and
                        format_info.direct.green.shift == 8 and
                        format_info.direct.blue.mask == 0xFF and
                        format_info.direct.blue.shift == 0)
                    {
                        // This would be a standard ARGB32 format
                        // You might want to use this instead of window_format
                        std.log.info("Found ARGB32 format: {}", .{format_info.id});
                    }
                }
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return 1;
            },
        }

        // _ = @as(*x11.render.query_pict_formats.Reply, @ptrCast(@alignCast(buf.double_buffer_ptr)));

        // // For simplicity, we'll use hardcoded format IDs
        // // In a real application, you'd parse the format list
        // glyph_format = @enumFromInt(0x26); // Typically A8 format
        // window_format = @enumFromInt(0x24); // Typically ARGB32 format
    }

    if (true) @panic("todo");

    // Create window
    {
        var msg_buf: [x11.create_window.max_len]u8 = undefined;
        const len = x11.create_window.serialize(&msg_buf, .{
            .window_id = ids.window(),
            .parent_window_id = screen.root,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
            .border_width = 0,
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
            .bg_pixel = 0xFFFFFFFF,
            .event_mask = .{ .exposure = 1 },
        });
        try conn.sendOne(&sequence, msg_buf[0..len]);
    }

    {
        var msg_buf: [x11.map_window.len]u8 = undefined;
        x11.map_window.serialize(&msg_buf, ids.window());
        try conn.sendOne(&sequence, &msg_buf);
    }

    // Create picture for window
    {
        var msg_buf: [256]u8 = undefined;
        const len = x11.render.create_picture.serialize(&msg_buf, render_ext_opcode, .{
            .picture = ids.picture(),
            .drawable = ids.window().drawable(),
            .format = window_format,
        }, .{});
        try conn.sendOne(&sequence, msg_buf[0..len]);
    }

    // Create solid color picture for text
    {
        var msg_buf: [x11.render.create_solid_fill.len]u8 = undefined;
        x11.render.create_solid_fill.serialize(&msg_buf, render_ext_opcode, .{
            .picture = ids.solid_picture(),
            .color = .{
                .red = 0,
                .green = 0,
                .blue = 0,
                .alpha = 0xFFFF,
            },
        });
        try conn.sendOne(&sequence, &msg_buf);
    }

    // Create glyph set
    {
        var msg_buf: [x11.render.create_glyph_set.len]u8 = undefined;
        x11.render.create_glyph_set.serialize(&msg_buf, render_ext_opcode, .{
            .gsid = ids.glyphset(),
            .format = glyph_format,
        });
        try conn.sendOne(&sequence, &msg_buf);
    }

    // Add some glyphs to the glyph set
    {
        const glyph_width = 16;
        const glyph_height = 20;

        // Create glyphs for letters A-Z (simplified)
        var glyphs: [26]x11.render.Glyph = undefined;
        var glyph_infos: [26]x11.render.GlyphInfo = undefined;

        for (0..26) |i| {
            glyphs[i] = @intCast(65 + i); // ASCII A-Z
            glyph_infos[i] = .{
                .width = glyph_width,
                .height = glyph_height,
                .x = 0,
                .y = @intCast(glyph_height - 4),
                .x_off = @intCast(glyph_width + 2),
                .y_off = 0,
            };
        }

        // Create simple glyph data (all pixels on for demonstration)
        const data_per_glyph = glyph_width * glyph_height;
        const total_data_size = data_per_glyph * 26;
        var glyph_data = try allocator.alloc(u8, total_data_size);
        defer allocator.free(glyph_data);

        // Fill with simple pattern
        for (0..26) |i| {
            const offset = i * data_per_glyph;
            for (0..data_per_glyph) |j| {
                // Create different patterns for different letters
                if ((i + j) % 3 == 0) {
                    glyph_data[offset + j] = 0xFF;
                } else if ((i + j) % 3 == 1) {
                    glyph_data[offset + j] = 0xAA;
                } else {
                    glyph_data[offset + j] = 0x55;
                }
            }
        }

        const msg_len = x11.render.add_glyphs.getLen(26, total_data_size);
        const msg_buf = try allocator.alloc(u8, msg_len);
        defer allocator.free(msg_buf);

        x11.render.add_glyphs.serialize(msg_buf.ptr, render_ext_opcode, .{
            .gsid = ids.glyphset(),
            .glyphs = &glyphs,
            .glyph_infos = &glyph_infos,
            .data = glyph_data,
        });
        try conn.sendOne(&sequence, msg_buf);
    }

    // Clear the window background with a filled rectangle
    {
        const rect = [_]x11.Rectangle{
            .{ .x = 0, .y = 0, .width = window_width, .height = window_height },
        };

        const msg_len = x11.render.fill_rectangles.getLen(1);
        var msg_buf: [256]u8 = undefined;
        x11.render.fill_rectangles.serialize(&msg_buf, render_ext_opcode, .{
            .op = .src,
            .dst = ids.picture(),
            .color = .{
                .red = 0xFFFF,
                .green = 0xFFFF,
                .blue = 0xFFFF,
                .alpha = 0xFFFF,
            },
        }, &rect);
        try conn.sendOne(&sequence, msg_buf[0..msg_len]);
    }

    // Render text "HELLO WORLD" using composite_glyphs8
    {
        const text = "HELLO WORLD";
        var glyphelt_data: [256]u8 = undefined;
        var offset: usize = 0;

        // Number of glyphs
        glyphelt_data[offset] = @intCast(text.len);
        offset += 1;

        // Padding
        glyphelt_data[offset] = 0;
        offset += 1;
        glyphelt_data[offset] = 0;
        offset += 1;
        glyphelt_data[offset] = 0;
        offset += 1;

        // Delta x,y from origin
        x11.writeIntNative(i16, glyphelt_data[offset..].ptr, 50);
        offset += 2;
        x11.writeIntNative(i16, glyphelt_data[offset..].ptr, 100);
        offset += 2;

        // Glyph indices
        for (text) |char| {
            glyphelt_data[offset] = char;
            offset += 1;
        }

        const msg_len = x11.render.composite_glyphs8.getLen(@intCast(offset));
        var msg_buf: [256]u8 = undefined;
        x11.render.composite_glyphs8.serialize(&msg_buf, render_ext_opcode, .{
            .op = .over,
            .src = ids.solid_picture(),
            .dst = ids.picture(),
            .mask_format = .none,
            .gsid = ids.glyphset(),
            .src_x = 0,
            .src_y = 0,
        }, glyphelt_data[0..offset]);
        try conn.sendOne(&sequence, msg_buf[0..msg_len]);
    }

    while (true) {
        var event_buf: [1024]u8 = undefined;
        const recv_len = x11.readSock(conn.sock, &event_buf, 0) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => |e| return e,
        };

        if (recv_len == 0) continue;
        const event_type = event_buf[0] & 0x7f;

        switch (event_type) {
            @intFromEnum(x11.EventCode.key_press) => {
                std.log.info("Key pressed, exiting...", .{});
                break;
            },
            @intFromEnum(x11.EventCode.expose) => {
                // Re-render on expose
                const rect = [_]x11.Rectangle{
                    .{ .x = 0, .y = 0, .width = window_width, .height = window_height },
                };

                // Clear background
                const msg_len = x11.render.fill_rectangles.getLen(1);
                var msg_buf: [256]u8 = undefined;
                x11.render.fill_rectangles.serialize(&msg_buf, render_ext_opcode, .{
                    .op = .src,
                    .dst = ids.picture(),
                    .color = .{
                        .red = 0xFFFF,
                        .green = 0xFFFF,
                        .blue = 0xFFFF,
                        .alpha = 0xFFFF,
                    },
                }, &rect);
                try conn.sendOne(&sequence, msg_buf[0..msg_len]);

                // Render text again
                const text = "HELLO WORLD";
                var glyphelt_data: [256]u8 = undefined;
                var offset: usize = 0;

                glyphelt_data[offset] = @intCast(text.len);
                offset += 1;
                glyphelt_data[offset] = 0;
                offset += 1;
                glyphelt_data[offset] = 0;
                offset += 1;
                glyphelt_data[offset] = 0;
                offset += 1;

                x11.writeIntNative(i16, glyphelt_data[offset..].ptr, 50);
                offset += 2;
                x11.writeIntNative(i16, glyphelt_data[offset..].ptr, 100);
                offset += 2;

                for (text) |char| {
                    glyphelt_data[offset] = char;
                    offset += 1;
                }

                const render_msg_len = x11.render.composite_glyphs8.getLen(@intCast(offset));
                var render_msg_buf: [256]u8 = undefined;
                x11.render.composite_glyphs8.serialize(&render_msg_buf, render_ext_opcode, .{
                    .op = .over,
                    .src = ids.solid_picture(),
                    .dst = ids.picture(),
                    .mask_format = .none,
                    .gsid = ids.glyphset(),
                    .src_x = 0,
                    .src_y = 0,
                }, glyphelt_data[0..offset]);
                try conn.sendOne(&sequence, render_msg_buf[0..render_msg_len]);
            },
            else => {},
        }
    }

    // Cleanup
    {
        var msg_buf: [x11.render.free_glyph_set.len]u8 = undefined;
        x11.render.free_glyph_set.serialize(&msg_buf, render_ext_opcode, .{
            .gsid = ids.glyphset(),
        });
        try conn.sendOne(&sequence, &msg_buf);
    }

    {
        var msg_buf: [x11.render.free_picture.len]u8 = undefined;
        x11.render.free_picture.serialize(&msg_buf, render_ext_opcode, .{
            .picture = ids.picture(),
        });
        try conn.sendOne(&sequence, &msg_buf);
    }

    {
        var msg_buf: [x11.render.free_picture.len]u8 = undefined;
        x11.render.free_picture.serialize(&msg_buf, render_ext_opcode, .{
            .picture = ids.solid_picture(),
        });
        try conn.sendOne(&sequence, &msg_buf);
    }

    return 0;
}
