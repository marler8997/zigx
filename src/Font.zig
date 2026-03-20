const std = @import("std");
const x11 = @import("x11");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const GlyphIndex = TrueType.GlyphIndex;

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub const TrueType = @import("TrueType");

const Font = @This();

ttf: *const TrueType,
scale: f32,
ids: Ids,
cached_glyphs: *GlyphSet,

pub const max_glyphs = std.math.maxInt(u16);

pub const Error = error{WriteFailed} || TrueType.GlyphBitmapError || error{InvalidUtf8};

/// X11 IDs and configuration for rendering glyphs using the X Render extension.
pub const Ids = struct {
    render_ext_opcode: u8,
    glyphset: x11.render.GlyphSet,
    src_picture: x11.render.Picture,
    glyph_format: x11.render.PictureFormat,
};

/// Information on a glyph.
const Glyph = struct {
    pub const Metrics = struct {
        /// The bounding box of the rasterized glyph.
        box: TrueType.BitmapBox,
        /// How much to advance the cursor horizontally after drawing this glyph.
        advance: i16,
    };

    /// Whether this glyph has pixel data (false for e.g. spaces or missing glyphs).
    has_pixels: bool,
    /// The measurements for this glyph.
    measurement: Glyph.Metrics,
};

/// A writer that draws utf8 using X11. All substrings passed to the writer must individually be
/// valid UTF8.
pub const TextWriter = struct {
    font: *Font,
    gpa: Allocator,
    sink: *x11.RequestSink,
    dst_picture: x11.render.Picture,
    cursor: x11.XY(i16),
    kerning: bool = true,
    left_margin: i16,
    /// The last glyph drawn. Used for kerning. Cleared automatically by `setCursor`, if you set the
    /// cursor position manually you should clear this value.
    last_glyph: ?GlyphIndex = null,
    interface: Writer,
    err: ?Error = null,
    alignment: Alignment = .left,
    needs_flush: bool = false,

    pub const Alignment = enum {
        left,
        right,
        center,
    };

    pub const Options = struct {
        /// The font to render.
        font: *Font,
        /// Used for temporary allocations.
        gpa: Allocator,
        /// A sink for the X11 commands.
        sink: *x11.RequestSink,
        /// The destination picture to composite glyphs onto.
        dst_picture: x11.render.Picture,
        /// The initial position to write text at.
        cursor: x11.XY(i16),
        /// Whether or not to enable kerning.
        kerning: bool = true,
        /// The left margin to reset to after a newline.
        left_margin: i16,
        /// The buffer to format text to.
        buffer: []u8,
    };

    pub fn init(options: TextWriter.Options) TextWriter {
        return .{
            .font = options.font,
            .gpa = options.gpa,
            .sink = options.sink,
            .dst_picture = options.dst_picture,
            .cursor = options.cursor,
            .kerning = options.kerning,
            .left_margin = options.left_margin,
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                },
                .buffer = options.buffer,
            },
        };
    }

    /// Flushes and then advances the cursor by a newline.
    pub fn newline(self: *TextWriter) Error!void {
        try self.interface.flush();
        self.cursor.x = self.left_margin;
        self.cursor.y += self.font.getLineAdvance();
        try self.setCursor(.{
            .x = self.left_margin,
            .y = self.cursor.y + self.font.getLineAdvance(),
        });
    }

    /// Flushes and then sets a new cursor position.
    pub fn setCursor(self: *TextWriter, cursor: x11.XY(i16)) Error!void {
        try self.interface.flush();
        self.cursor = cursor;
        self.last_glyph = null;
    }

    /// Flushes then sets the alignment for upcoming text. Keep in mind that different alignments
    /// have different minimum buffer sizes.
    ///
    /// Left alignment puts not requirements on the buffer size.
    ///
    /// Right and center alignment require an explicit flush to free up the buffer. This is because
    /// when center or right aligning text, the full string needs to be known before any of it can
    /// be drawn. As a result, the buffer must be large enough to avoid calls to drain in between
    /// flushes. You can still make arbitrarily large writes with a small buffer (see `writeVec`),
    /// they must be followeod by an explicit flush.
    pub fn setAlignment(self: *TextWriter, alignment: Alignment) Error!void {
        try self.interface.flush();
        self.alignment = alignment;
    }

    fn flush(writer: *Writer) error{WriteFailed}!void {
        const tw: *TextWriter = @fieldParentPtr("interface", writer);
        try writer.defaultFlush();
        tw.needs_flush = false;
    }

    fn drain(writer: *Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
        // Gather information for the write
        const tw: *TextWriter = @fieldParentPtr("interface", writer);
        if (tw.err != null) return error.WriteFailed;
        if (tw.needs_flush) return tw.fail(error.OutOfMemory);

        const buffered = writer.buffered();
        _ = writer.consumeAll();
        const slice = data[0 .. data.len - 1];
        const pattern = data[data.len - 1];

        // Measure the text to be written and offset the cursor if necessary
        switch (tw.alignment) {
            .left => {},
            .right, .center => {
                var advance: i16 = 0;
                var last_glyph: ?GlyphIndex = null;
                const font = tw.font;
                const options: MeasureOptions = .{
                    .kerning = tw.kerning,
                    .last_glyph = &last_glyph,
                };
                advance += (try tw.mapErr(font.measure(buffered, options))).advance.x;
                for (slice) |bytes| advance += (try tw.mapErr(font.measure(bytes, options))).advance.x;
                for (0..splat) |_| advance += (try tw.mapErr(font.measure(pattern, options))).advance.x;

                switch (tw.alignment) {
                    .left => unreachable,
                    .right => tw.cursor.x -= advance,
                    .center => tw.cursor.x -= @divTrunc(advance, 2),
                }
                tw.last_glyph = null;
                tw.needs_flush = true;
            },
        }

        // Write the text
        try tw.mapErr(tw.writeAll(buffered));
        for (slice) |bytes| try tw.mapErr(tw.writeAll(bytes));
        for (0..splat) |_| try tw.mapErr(tw.writeAll(pattern));

        // Indicate to the caller that we wrote everything we had
        return Writer.countSplat(data, splat);
    }

    fn writeAll(self: *TextWriter, utf8: []const u8) Error!void {
        try self.font.draw(.{
            .gpa = self.gpa,
            .sink = self.sink,
            .dst_picture = self.dst_picture,
            .utf8 = utf8,
            .cursor = &self.cursor,
            .kerning = self.kerning,
            .last_glyph = &self.last_glyph,
        });
    }

    fn mapErr(
        self: *TextWriter,
        res: anytype,
    ) error{WriteFailed}!@typeInfo(@TypeOf(res)).error_union.payload {
        return res catch |err| return self.fail(err);
    }

    fn fail(self: *TextWriter, err: Error) error{WriteFailed} {
        self.err = err;
        return error.WriteFailed;
    }
};

pub const Options = struct {
    size: f32,
};

comptime {
    std.debug.assert(@sizeOf(GlyphSet) == 8192);
}
pub const GlyphSet = struct {
    const GlyphIndexInt = @typeInfo(GlyphIndex).@"enum".tag_type;

    bit_set: std.StaticBitSet(std.math.maxInt(GlyphIndexInt) + 1),

    pub fn initEmpty() GlyphSet {
        return .{ .bit_set = .initEmpty() };
    }
    pub fn isSet(self: *const GlyphSet, glyph_index: GlyphIndex) bool {
        return self.bit_set.isSet(@intFromEnum(glyph_index));
    }
    pub fn set(self: *GlyphSet, glyph_index: GlyphIndex) void {
        self.bit_set.set(@intFromEnum(glyph_index));
    }
};

pub fn init(
    ttf: *const TrueType,
    ids: Ids,
    options: Options,
    cached_glyphs_store: *GlyphSet,
    sink: *x11.RequestSink,
) !Font {
    // We later on will assume that there's at least space for the .notdef glyph at 0
    if (ttf.glyphs_len == 0) return error.OutOfMemory;
    const scale = ttf.scaleForPixelHeight(options.size);
    cached_glyphs_store.* = .initEmpty();
    try x11.render.CreateGlyphSet(sink, ids.render_ext_opcode, ids.glyphset, ids.glyph_format);
    return .{
        .ttf = ttf,
        .scale = scale,
        .ids = ids,
        .cached_glyphs = cached_glyphs_store,
    };
}

pub fn deinit(self: *Font, sink: *x11.RequestSink) !void {
    try x11.render.FreeGlyphSet(sink, self.ids.render_ext_opcode, self.ids.glyphset);
    self.* = undefined;
}

/// Invalidates the cached glyphs by freeing and recreating the server-side GlyphSet.
pub fn invalidateCache(self: *Font, sink: *x11.RequestSink) error{WriteFailed}!void {
    try x11.render.FreeGlyphSet(sink, self.ids.render_ext_opcode, self.ids.glyphset);
    try x11.render.CreateGlyphSet(sink, self.ids.render_ext_opcode, self.ids.glyphset, self.ids.glyph_format);
    @memset(&self.cached_glyphs.bit_set.masks, 0);
}

pub const ChangeOptions = struct {
    ttf: ?*const TrueType = null,
    size: ?f32 = null,
};

/// Change the font. Properties left null are unchanged. If any properties are changed, the cache
/// will be invalidated. This has performance implications.
pub fn change(self: *Font, sink: *x11.RequestSink, options: ChangeOptions) !void {
    // Get the new values, early out if they haven't changed
    const ttf = options.ttf orelse self.ttf;
    const scale = if (options.size) |size| self.ttf.scaleForPixelHeight(size) else self.scale;

    if (ttf == self.ttf and scale == self.scale) return;

    // Update the cached options and invalidate the cache
    self.ttf = ttf;
    self.scale = scale;

    try self.invalidateCache(sink);
}

pub const DrawOptions = struct {
    gpa: Allocator,
    sink: *x11.RequestSink,
    dst_picture: x11.render.Picture,
    utf8: []const u8,
    cursor: *x11.XY(i16),
    kerning: bool = true,
    last_glyph: *?GlyphIndex,
};

/// Low level text drawing. See also `TextWriter`.
pub fn draw(self: *Font, options: DrawOptions) Error!void {
    try drawOrMeasure(
        .draw,
        self,
        options.utf8,
        options.cursor,
        options.kerning,
        options.last_glyph,
        .{
            .gpa = options.gpa,
            .sink = options.sink,
            .dst_picture = options.dst_picture,
        },
    );
}

pub const Metrics = struct {
    /// The distance the cursor would move while drawing this text.
    advance: x11.XY(i16),
};

pub const MeasureOptions = struct {
    kerning: bool = true,
    /// The last glyph drawn, used for kerning.
    last_glyph: *?GlyphIndex,
};

/// Measures the given text.
pub fn measure(
    self: *const Font,
    utf8: []const u8,
    options: MeasureOptions,
) error{InvalidUtf8}!Metrics {
    var cursor: x11.XY(i16) = .zero;
    try drawOrMeasure(
        .measure,
        self,
        utf8,
        &cursor,
        options.kerning,
        options.last_glyph,
        .{},
    );
    return .{ .advance = cursor };
}

/// We've combined this functionality into a single call so that we don't forget to keep measure in
/// sync with draw.
fn drawOrMeasure(
    comptime mode: enum { draw, measure },
    self: switch (mode) {
        .draw => *Font,
        .measure => *const Font,
    },
    utf8: []const u8,
    cursor: *x11.XY(i16),
    kerning: bool,
    last_glyph: *?GlyphIndex,
    options: switch (mode) {
        .draw => struct {
            gpa: Allocator,
            sink: *x11.RequestSink,
            dst_picture: x11.render.Picture,
        },
        .measure => struct {},
    },
) !void {
    var view: std.unicode.Utf8View = try .init(utf8);
    var codepoints = view.iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        // Get the glyph index
        const glyph_index = self.ttf.codepointGlyphIndex(codepoint);

        // Apply kerning if requested
        if (kerning) {
            self.kern(last_glyph.*, glyph_index, cursor);
            last_glyph.* = glyph_index;
        }

        // Measure the glyph, and optionally draw it
        const measurement = switch (mode) {
            .draw => b: {
                const glyph = try self.ensureGlyph(options.gpa, options.sink, glyph_index);
                if (glyph.has_pixels) {
                    try x11.render.CompositeGlyphs32(options.sink, self.ids.render_ext_opcode, .{
                        .picture_operation = .over,
                        .src_picture = self.ids.src_picture,
                        .dst_picture = options.dst_picture,
                        .mask_format = .none,
                        .glyphset = self.ids.glyphset,
                        .src_x = cursor.x,
                        .src_y = cursor.y,
                        .delta_x = cursor.x,
                        .delta_y = cursor.y,
                        .glyph_id = @intFromEnum(glyph_index),
                    });
                }
                break :b glyph.measurement;
            },
            .measure => self.getGlyphMetrics(glyph_index),
        };

        // Advance to the starting position of the next glyph
        cursor.x += measurement.advance;
    }
}

/// Low level kerning. Prefer `TextWriter.draw`/`TextWriter.measure` with kerning enabled.
pub fn kern(
    self: *const Font,
    maybe_prev: ?GlyphIndex,
    curr: GlyphIndex,
    cursor: *x11.XY(i16),
) void {
    if (maybe_prev) |prev| {
        const kerning = self.ttf.glyphKernAdvance(prev, curr);
        const kerning_f: f32 = @floatFromInt(kerning);
        cursor.x += @intFromFloat(kerning_f * self.scale);
    }
}

/// Returns the amount the cursor should be advanced vertically for a newline.
pub fn getLineAdvance(self: *const Font) i16 {
    const metrics = self.ttf.verticalMetrics();
    const unscaled_i = metrics.ascent - metrics.descent + metrics.line_gap;
    const unscaled: f32 = @floatFromInt(unscaled_i);
    return @intFromFloat(unscaled * self.scale);
}

/// Gets metrics for a glyph.
pub fn getGlyphMetrics(self: *const Font, glyph_index: GlyphIndex) Glyph.Metrics {
    const box = self.ttf.glyphBitmapBox(glyph_index, self.scale, self.scale);
    const h_metrics = self.ttf.glyphHMetrics(glyph_index);
    const advance_unscaled: f32 = @floatFromInt(h_metrics.advance_width);
    const advance: i16 = @intFromFloat(self.scale * advance_unscaled);
    return .{
        .box = box,
        .advance = advance,
    };
}

/// Ensures a glyph is in the server-side GlyphSet, uploading it if necessary.
fn ensureGlyph(
    self: *Font,
    gpa: Allocator,
    sink: *x11.RequestSink,
    glyph_index: GlyphIndex,
) Error!Glyph {
    // Get the glyph info
    const measurement = self.getGlyphMetrics(glyph_index);

    // Check if the glyph is already in the cache
    if (self.cached_glyphs.isSet(glyph_index)) {
        return .{
            .has_pixels = measurement.box.x1 > measurement.box.x0 and
                measurement.box.y1 > measurement.box.y0,
            .measurement = measurement,
        };
    }

    // If not, rasterize and upload it
    const has_pixels = rasterize: {
        // Rasterize the glyph to alpha (u8 per pixel)
        var r8: std.ArrayListUnmanaged(u8) = .empty;
        defer r8.deinit(gpa);
        const dims = self.ttf.glyphBitmap(
            gpa,
            &r8,
            glyph_index,
            self.scale,
            self.scale,
        ) catch |err| switch (err) {
            error.GlyphNotFound => break :rasterize false,
            else => |e| return e,
        };

        // Check the dimensions, they should match the box
        assert(dims.width == measurement.box.x1 - measurement.box.x0 and
            dims.height == measurement.box.y1 - measurement.box.y0);

        // Upload alpha data to the server-side GlyphSet
        const w: u32 = dims.width;
        const h: u32 = dims.height;
        const row_stride = (w + 3) & ~@as(u32, 3);
        const alpha_size = row_stride * h;

        const info: x11.render.GlyphInfo = .{
            .width = dims.width,
            .height = dims.height,
            .x = @intCast(-@as(i32, measurement.box.x0)),
            .y = @intCast(-@as(i32, measurement.box.y0)),
            .x_off = measurement.advance,
            .y_off = 0,
        };

        const pad_len = try x11.render.AddGlyphsStart(
            sink,
            self.ids.render_ext_opcode,
            self.ids.glyphset,
            @intFromEnum(glyph_index),
            info,
            alpha_size,
        );

        // Write alpha data row by row with 4-byte row padding
        for (0..h) |y| {
            const row_start = y * @as(usize, dims.width);
            try sink.writer.writeAll(r8.items[row_start..][0..dims.width]);
            const row_pad = row_stride - w;
            if (row_pad > 0) try sink.writer.splatByteAll(0, @intCast(row_pad));
        }

        try x11.render.AddGlyphsFinish(sink, pad_len);

        // Add the glyph to the cache
        self.cached_glyphs.set(glyph_index);

        break :rasterize true;
    };

    return .{
        .has_pixels = has_pixels,
        .measurement = measurement,
    };
}
