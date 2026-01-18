const std = @import("std");
const x11 = @import("x11");
const assert = std.debug.assert;
const TrueType = @import("TrueType");
const DynamicBitSetUnmanaged = std.bit_set.DynamicBitSetUnmanaged;
const Allocator = std.mem.Allocator;
const GlyphIndex = TrueType.GlyphIndex;

const Font = @This();

ttf: *const TrueType,
cache: DynamicBitSetUnmanaged,
scale: f32,
color: u32,
ids: Ids,

/// X11 IDs necessary to render the font.
pub const Ids = struct {
    /// The window the font will eventually be rendered to.
    window: x11.Window,
    /// The ID reserved for use for temporary graphics contexts for glyph rasterization.
    glyph_gc: x11.GraphicsContext,
    /// The base ID for glyph pixmap.
    glyphs_base: x11.ResourceBase,
    /// The max number of glyphs supported.
    glyphs_len: u16,

    /// Returns the pixmap for a given glyph, or `null` if out of range.
    pub fn glyphPixmap(self: Ids, index: Font.GlyphIndex) ?x11.Pixmap {
        if (@intFromEnum(index) >= self.glyphs_len) return null;
        return self.glyphs_base.add(@intFromEnum(index)).pixmap();
    }
};

/// Information on a glyph.
const Glyph = struct {
    pub const Metrics = struct {
        /// The bounding box of the rasterized glyph.
        box: TrueType.BitmapBox,
        /// How much to advance the cursor horizontally after drawing this glyph.
        advance: i16,
    };

    /// The rasterized glyph, or null if empty (e.g. for spaces.)
    pixmap: ?x11.Pixmap,
    /// The measurements for this glyph.
    measurement: Glyph.Metrics,
};

pub const TextContext = struct {
    /// The font to render.
    font: *Font,
    /// Used for temporary allocations.
    gpa: Allocator,
    /// A sink for the X11 commands.
    sink: *x11.RequestSink,
    /// The graphics context to draw with.
    gc: x11.GraphicsContext,
    /// The drawable to draw to.
    drawable: x11.Drawable,
    /// The initial position to write text at.
    cursor: x11.XY(i16),
    /// Whether or not to enable kerning.
    kerning: bool = true,
    /// The left margin to reset to after a newline.
    left_margin: i16,
    /// The last glyph drawn. Used for kerning. Cleared automatically by `setCursor`, if you set the
    /// cursor position manually you should clear this value.
    last_glyph: ?GlyphIndex = null,

    /// Draws the given utf8 string at the current cursor position.
    pub fn draw(self: *TextContext, utf8: []const u8) !void {
        try self.font.draw(.{
            .gpa = self.gpa,
            .sink = self.sink,
            .gc = self.gc,
            .drawable = self.drawable,
            .utf8 = utf8,
            .cursor = &self.cursor,
            .kerning = self.kerning,
            .last_glyph = &self.last_glyph,
        });
    }

    /// Measures how much the cursor would advance if you were to pass the given string to `draw`
    /// without changing any other state.
    pub fn measure(self: *const TextContext, utf8: []const u8) !Metrics {
        var last_glyph = self.last_glyph;
        return self.font.measure(utf8, .{
            .kerning = self.kerning,
            .last_glyph = &last_glyph,
        });
    }

    /// Advances the cursor by a newline.
    pub fn newline(self: *TextContext) void {
        self.cursor.x = self.left_margin;
        self.cursor.y += self.font.getLineAdvance();
        self.setCursor(.{
            .x = self.left_margin,
            .y = self.cursor.y + self.font.getLineAdvance(),
        });
    }

    /// Sets a new cursor position.
    pub fn setCursor(self: *TextContext, cursor: x11.XY(i16)) void {
        self.cursor = cursor;
        self.last_glyph = null;
    }
};

pub const Options = struct {
    size: f32,
    color: u32,
};

pub fn init(
    gpa: Allocator,
    ttf: *const TrueType,
    ids: Ids,
    options: Options,
) !Font {
    // We later on will assume that there's at least space for the .notdef glyph at 0
    if (ttf.glyphs_len == 0) return error.OutOfMemory;
    _ = try std.math.add(u32, @intFromEnum(ids.glyphs_base), ids.glyphs_len);
    var cache: DynamicBitSetUnmanaged = try .initEmpty(
        gpa,
        std.math.maxInt(@typeInfo(GlyphIndex).@"enum".tag_type),
    );
    errdefer cache.deinit(gpa);
    const scale = ttf.scaleForPixelHeight(options.size);
    return .{
        .cache = cache,
        .ttf = ttf,
        .scale = scale,
        .color = options.color,
        .ids = ids,
    };
}

pub fn deinit(self: *Font, gpa: Allocator, sink: *x11.RequestSink) !void {
    var iter = self.cache.iterator(.{});
    while (iter.next()) |glyph_index| {
        const pixmap = self.ids.glyphPixmap(@enumFromInt(glyph_index)).?;
        try sink.FreePixmap(pixmap);
    }
    self.cache.deinit(gpa);
    self.* = undefined;
}

pub const DrawOptions = struct {
    gpa: Allocator,
    sink: *x11.RequestSink,
    gc: x11.GraphicsContext,
    drawable: x11.Drawable,
    utf8: []const u8,
    cursor: *x11.XY(i16),
    kerning: bool = true,
    last_glyph: *?GlyphIndex,
};

/// Low level text drawing. Prefer `TextContext.draw`.
pub fn draw(self: *Font, options: DrawOptions) !void {
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
            .gc = options.gc,
            .drawable = options.drawable,
        },
    );
}

pub const Metrics = struct {
    /// The distance the cursor would move while drawing this text.
    advance: x11.XY(i16),
};

pub const MeasureOptions = struct {
    kerning: bool = true,
    last_glyph: *?GlyphIndex,
};

/// Low level text measurement. Prefer `TextContent.measure`.
pub fn measure(self: *const Font, utf8: []const u8, options: MeasureOptions) !Metrics {
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
            gc: x11.GraphicsContext,
            drawable: x11.Drawable,
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
                const glyph = try self.getGlyph(options.gpa, options.sink, glyph_index);
                if (glyph.pixmap) |pixmap| {
                    try options.sink.CopyArea(.{
                        .src_drawable = pixmap.drawable(),
                        .dst_drawable = options.drawable,
                        .gc = options.gc,
                        .src_x = 0,
                        .src_y = 0,
                        .dst_x = @intCast(cursor.x + glyph.measurement.box.x0),
                        .dst_y = @intCast(cursor.y + glyph.measurement.box.y0),
                        .width = @intCast(glyph.measurement.box.x1 - glyph.measurement.box.x0),
                        .height = @intCast(glyph.measurement.box.y1 - glyph.measurement.box.y0),
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

/// Low level kerning. Prefer `TextContext.draw`/`TextContext.measure` with kerning enabled.
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

/// Gets a glyph, rasterizign it and adding it to the caceh if necessary.
pub fn getGlyph(
    self: *Font,
    gpa: Allocator,
    sink: *x11.RequestSink,
    glyph_index: GlyphIndex,
) !Glyph {
    // Get the glyph info
    const measurement = self.getGlyphMetrics(glyph_index);

    // Check if the glyph is already in the cache
    if (self.cache.isSet(@intFromEnum(glyph_index))) {
        return .{
            .pixmap = self.ids.glyphPixmap(glyph_index),
            .measurement = measurement,
        };
    }

    // If not, add it to the cache
    const pixmap = rasterize: {
        // Find the pixmap ID. If there's no pixmap reserved for this glyph,
        // return this notdef glyph instead.
        const pixmap = self.ids.glyphPixmap(glyph_index) orelse {
            assert(glyph_index != .notdef); // Unreachable
            return self.getGlyph(gpa, sink, .notdef);
        };

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
        assert(dims.width == measurement.box.x1 - measurement.box.x0 and
            dims.height == measurement.box.y1 - measurement.box.y0);

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

        const gc = self.ids.glyph_gc;
        try sink.CreatePixmap(pixmap, self.ids.window.drawable(), .{
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
        try sink.FreeGc(gc);

        // Add the glyph to the cache
        self.cache.set(@intFromEnum(glyph_index));

        break :rasterize pixmap;
    };

    // Return the glyph
    return .{
        .pixmap = pixmap,
        .measurement = measurement,
    };
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
