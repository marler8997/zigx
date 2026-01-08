const Ids = struct {
    base: x11.ResourceBase,
    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.base.add(1).graphicsContext();
    }
    pub fn backBuffer(self: Ids) x11.Drawable {
        return self.base.add(2).drawable();
    }
    pub fn glyphGc(self: Ids) x11.GraphicsContext {
        return self.base.add(3).graphicsContext();
    }
    pub fn glyphPixmap(self: Ids, index: GlyphIndex) x11.Pixmap {
        const offset = 4;
        comptime assert(offset + std.math.maxInt(@typeInfo(GlyphIndex).@"enum".tag_type) < std.math.maxInt(u32));
        return self.base.add(offset + @intFromEnum(index)).pixmap();
    }
};

pub fn main() !void {
    try x11.wsaStartup();

    const Screen = struct {
        window: x11.Window,
        visual: x11.Visual,
        depth: x11.Depth,
    };
    const stream: std.net.Stream, const ids: Ids, const screen: Screen = blk: {
        var read_buffer: [1000]u8 = undefined;
        var socket_reader, const used_auth = try x11.draft.connect(&read_buffer);
        errdefer x11.disconnect(socket_reader.getStream());
        _ = used_auth;
        const setup = try x11.readSetupSuccess(socket_reader.interface());
        std.log.info("setup reply {f}", .{setup});
        var source: x11.Source = .initFinishSetup(socket_reader.interface(), &setup);
        const screen = try x11.draft.readSetupDynamic(&source, &setup, .{}) orelse {
            std.log.err("no screen?", .{});
            std.process.exit(0xff);
        };
        break :blk .{
            socket_reader.getStream(), .{ .base = setup.resource_id_base }, .{
                .window = screen.root,
                .visual = screen.root_visual,
                .depth = x11.Depth.init(screen.root_depth) orelse std.debug.panic(
                    "unsupported depth {}",
                    .{screen.root_depth},
                ),
            },
        };
    };
    defer x11.disconnect(stream);

    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = x11.socketWriter(stream, &write_buffer);
    var socket_reader = x11.socketReader(stream, &read_buffer);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .initAfterSetup(socket_reader.interface());

    var window_size: XY(u16) = .{ .x = 400, .y = 400 };

    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = screen.window,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = window_size.x,
            .height = window_size.y,
            .border_width = 0,
            .class = .input_output,
            .visual_id = screen.visual,
        },
        .{
            .bg_pixel = screen.depth.rgbFrom24(0),
            .event_mask = .{
                .ButtonPress = 1,
                .ButtonRelease = 1,
                .PointerMotion = 1,
                .Exposure = 1,
                .StructureNotify = 1,
            },
        },
    );

    const dbe: Dbe = blk: {
        const ext = try x11.draft.synchronousQueryExtension(&source, &sink, x11.dbe.name) orelse break :blk .unsupported;
        try x11.dbe.Allocate(&sink, ext.opcode_base, ids.window(), ids.backBuffer(), .background);
        break :blk .{ .enabled = .{ .opcode_base = ext.opcode_base, .back_buffer = ids.backBuffer() } };
    };

    try sink.CreateGc(
        ids.gc(),
        ids.window().drawable(),
        .{
            .background = screen.depth.rgbFrom24(0),
            .foreground = screen.depth.rgbFrom24(0xffffff),
            .line_width = 4,
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
        },
    );

    try sink.MapWindow(ids.window());

    const ttf: TrueType = try .load(@embedFile("InterVariable.ttf"));
    var font: Font = try .init(std.heap.page_allocator, &ttf, .{
        .size = 80,
        .color = 0xffffff,
    });
    defer font.deinit(std.heap.page_allocator, &sink, ids) catch |err| @panic(@errorName(err));
    var glyph_arena: ArenaAllocator = .init(std.heap.page_allocator);

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

        var do_render = false;
        switch (msg_kind) {
            .Expose => {
                const expose = try source.read2(.Expose);
                std.log.info("X11 {}", .{expose});
                do_render = true;
            },
            .ConfigureNotify => {
                const msg = try source.read2(.ConfigureNotify);
                std.debug.assert(msg.event == ids.window());
                std.debug.assert(msg.window == ids.window());
                if (window_size.x != msg.width or window_size.y != msg.height) {
                    std.log.info("WindowSize {}x{}", .{ msg.width, msg.height });
                    window_size = .{ .x = msg.width, .y = msg.height };
                    do_render = true;
                }
            },
            .MotionNotify,
            .ButtonPress,
            .ButtonRelease,
            .MapNotify,
            .ReparentNotify,
            => try source.discardRemaining(),
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
        }
        if (do_render) {
            try render(
                &glyph_arena,
                &sink,
                ids,
                dbe,
                &font,
                window_size,
            );
        }
    }
}

fn render(
    glyph_arena: *ArenaAllocator,
    sink: *x11.RequestSink,
    ids: Ids,
    dbe: Dbe,
    font: *Font,
    window_size: XY(u16),
) !void {
    const window = ids.window();
    const gc = ids.gc();

    if (null == dbe.backBuffer()) {
        try sink.ClearArea(
            window,
            .{
                .x = 0,
                .y = 0,
                .width = window_size.x,
                .height = window_size.y,
            },
            .{ .exposures = false },
        );
    }
    const drawable = if (dbe.backBuffer()) |back_buffer| back_buffer else window.drawable();

    const left_margin = 50;
    var x: i16 = left_margin;
    var y: i16 = 80;
    try font.draw(
        glyph_arena.allocator(),
        sink,
        ids,
        gc,
        drawable,
        "Hello, World! These glyphs are missing: こんにちは",
        &x,
        &y,
        true,
    );

    font.advanceLine(&x, &y, .{ .left_margin = left_margin });

    try font.draw(
        glyph_arena.allocator(),
        sink,
        ids,
        gc,
        drawable,
        "This is a new line!",
        &x,
        &y,
        true,
    );

    switch (dbe) {
        .unsupported => {},
        .enabled => |enabled| try x11.dbe.Swap(sink, enabled.opcode_base, .initAssume(&.{
            .{ .window = window, .action = .background },
        })),
    }
}

pub const Font = struct {
    ttf: *const TrueType,
    cache: DynamicBitSetUnmanaged,
    scale: f32,
    color: u32,

    const Glyph = struct {
        /// The rasterized glyph, or null if empty (e.g. for spaces.)
        pixmap: ?x11.Pixmap,
        /// The bounding box of the rasterized glyph.
        box: TrueType.BitmapBox,
        /// How much to advance the cursor horizontally after drawing this glyph.
        advance: i16,
    };

    pub const Options = struct {
        size: f32,
        color: u32,
    };

    pub fn init(gpa: Allocator, ttf: *const TrueType, options: Options) !Font {
        var cache: DynamicBitSetUnmanaged = try .initEmpty(gpa, std.math.maxInt(u21));
        errdefer cache.deinit(gpa);
        const scale = ttf.scaleForPixelHeight(options.size);
        return .{
            .cache = cache,
            .ttf = ttf,
            .scale = scale,
            .color = options.color,
        };
    }

    pub fn deinit(self: *Font, gpa: Allocator, sink: *x11.RequestSink, ids: Ids) !void {
        var iter = self.cache.iterator(.{});
        while (iter.next()) |glyph_index| {
            try sink.FreePixmap(ids.glyphPixmap(@enumFromInt(glyph_index)));
        }
        self.cache.deinit(gpa);
        self.* = undefined;
    }

    // Fast but exact unorm to float.
    fn unormToFloat(u: u8) f32 {
        const max: f32 = @floatFromInt(255);
        const r: f32 = 1.0 / (3.0 * max);
        return @as(f32, @floatFromInt(u)) * 3.0 * r;
    }

    // Exact float to unorm.
    fn floatToUnorm(f: f32) u8 {
        return @intFromFloat(f * 255 + 0.5);
    }

    pub fn draw(
        self: *Font,
        gpa: Allocator,
        sink: *x11.RequestSink,
        ids: Ids,
        gc: x11.GraphicsContext,
        drawable: x11.Drawable,
        utf8: []const u8,
        x: *i16,
        y: *i16,
        kerning: bool,
    ) !void {
        var view: std.unicode.Utf8View = try .init(utf8);
        var codepoints = view.iterator();
        var prev_glyph_index: ?GlyphIndex = null;
        while (codepoints.nextCodepoint()) |codepoint| {
            // Draw the glyph
            const glyph_index = self.ttf.codepointGlyphIndex(codepoint);
            const glyph = try self.getGlyph(gpa, sink, ids, glyph_index);
            if (glyph.pixmap) |pixmap| {
                try sink.CopyArea(.{
                    .src_drawable = pixmap.drawable(),
                    .dst_drawable = drawable,
                    .gc = gc,
                    .src_x = 0,
                    .src_y = 0,
                    .dst_x = @intCast(x.* + glyph.box.x0),
                    .dst_y = @intCast(y.* + glyph.box.y0),
                    .width = @intCast(glyph.box.x1 - glyph.box.x0),
                    .height = @intCast(glyph.box.y1 - glyph.box.y0),
                });
            }
            x.* += glyph.advance;

            // Apply kerning
            if (kerning) {
                if (prev_glyph_index) |prev| {
                    const kern = self.ttf.glyphKernAdvance(prev, glyph_index);
                    const kern_f: f32 = @floatFromInt(kern);
                    x.* += @intFromFloat(kern_f * self.scale);
                }
                prev_glyph_index = glyph_index;
            }
        }
    }

    pub fn getLineAdvance(self: *const Font) i16 {
        const metrics = self.ttf.verticalMetrics();
        const unscaled_i = metrics.ascent - metrics.descent + metrics.line_gap;
        const unscaled: f32 = @floatFromInt(unscaled_i);
        return @intFromFloat(unscaled * self.scale);
    }

    pub const AdvanceLineOptions = struct {
        left_margin: i16,
    };

    pub fn advanceLine(self: *const Font, x: *i16, y: *i16, options: AdvanceLineOptions) void {
        x.* = options.left_margin;
        y.* += self.getLineAdvance();
    }

    pub fn getGlyph(
        self: *Font,
        gpa: Allocator,
        sink: *x11.RequestSink,
        ids: Ids,
        glyph_index: GlyphIndex,
    ) !Glyph {
        // Get the glyph info
        const box = self.ttf.glyphBitmapBox(glyph_index, self.scale, self.scale);
        const h_metrics = self.ttf.glyphHMetrics(glyph_index);
        const advance_unscaled: f32 = @floatFromInt(h_metrics.advance_width);
        const advance: i16 = @intFromFloat(self.scale * advance_unscaled);

        // Check if the glyph is already in the cache
        if (self.cache.isSet(@intFromEnum(glyph_index))) {
            return .{
                .pixmap = ids.glyphPixmap(glyph_index),
                .box = box,
                .advance = advance,
            };
        }

        // If not, add it to the cache
        const pixmap = rasterize: {
            // Rasterize the glyph
            var r8: std.ArrayListUnmanaged(u8) = .empty;
            defer r8.deinit(gpa);
            const dims = self.ttf.glyphBitmap(
                gpa,
                &r8,
                glyph_index,
                self.scale,
                self.scale,
            ) catch |err| switch (err) {
                error.GlyphNotFound => break :rasterize null,
                else => |e| return e,
            };

            // Check the dimensions, they should match the box
            assert(dims.width == box.x1 - box.x0 and dims.height == box.y1 - box.y0);

            // Transcode and color the rasterized glyph
            const z_pixmap_24 = try gpa.alloc(
                u8,
                @as(usize, @intCast(dims.width)) * @as(usize, @intCast(dims.height)) * 4,
            );
            defer gpa.free(z_pixmap_24);
            const color_unorm = std.mem.asBytes(&self.color);
            const color_float: [3]f32 = .{
                unormToFloat(color_unorm[0]),
                unormToFloat(color_unorm[1]),
                unormToFloat(color_unorm[2]),
            };
            for (0..dims.height) |y| {
                for (0..dims.width) |x| {
                    const a_unorm = r8.items[x + y * @as(usize, @intCast(dims.width))];
                    const a_float = unormToFloat(a_unorm);
                    z_pixmap_24[(y * dims.width + x) * 4 ..][0..4].* = .{
                        floatToUnorm(color_float[0] * a_float),
                        floatToUnorm(color_float[1] * a_float),
                        floatToUnorm(color_float[2] * a_float),
                        255,
                    };
                }
            }

            // Create the pixmap
            const pixmap = ids.glyphPixmap(glyph_index);

            const gc = ids.glyphGc();
            try sink.CreatePixmap(pixmap, ids.window().drawable(), .{
                .depth = .@"24",
                .width = dims.width,
                .height = dims.height,
            });
            try sink.CreateGc(gc, pixmap.drawable(), .{});
            try sink.PutImage(.{
                .format = .z_pixmap,
                .drawable = pixmap.drawable(),
                .gc_id = gc,
                .width = dims.width,
                .height = dims.height,
                .x = 0,
                .y = 0,
                .depth = .@"24",
            }, .init(z_pixmap_24.ptr, @intCast(z_pixmap_24.len)));
            try sink.FreeGc(ids.glyphGc());

            // Add the glyph to the cache
            self.cache.set(@intFromEnum(glyph_index));

            break :rasterize pixmap;
        };

        // Return the glyph
        return .{
            .pixmap = pixmap,
            .box = box,
            .advance = advance,
        };
    }
};

const Dbe = union(enum) {
    unsupported,
    enabled: struct {
        opcode_base: u8,
        back_buffer: x11.Drawable,
    },
    pub fn backBuffer(self: Dbe) ?x11.Drawable {
        return switch (self) {
            .unsupported => null,
            .enabled => |enabled| enabled.back_buffer,
        };
    }
};

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const std = @import("std");
const x11 = @import("x11");
const XY = x11.XY;
const assert = std.debug.assert;
const DynamicBitSetUnmanaged = std.bit_set.DynamicBitSetUnmanaged;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const TrueType = @import("TrueType");
const GlyphIndex = TrueType.GlyphIndex;
