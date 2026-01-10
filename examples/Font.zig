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

pub const Ids = struct {
    /// The window the font will eventually be rendered to.
    window: x11.Window,
    /// The ID reserved for use for temporary graphics contexts for glyph rasterization.
    glyph_gc: x11.GraphicsContext,
    /// The base ID for glyph pixmap.
    glyphs_base: x11.ResourceBase,
    /// The max number of glyphs supported.
    glyphs_len: u16,

    pub fn glyphPixmap(self: Ids, index: Font.GlyphIndex) ?x11.Pixmap {
        if (@intFromEnum(index) >= self.glyphs_len) return null;
        return self.glyphs_base.add(@intFromEnum(index)).pixmap();
    }
};

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
        const glyph = try self.getGlyph(gpa, sink, glyph_index);
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
            .pixmap = self.ids.glyphPixmap(glyph_index),
            .box = box,
            .advance = advance,
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
        .box = box,
        .advance = advance,
    };
}
