//! xtt - X11 True Type
pub const TrueType = @import("TrueType");
pub const GlyphIndex = TrueType.GlyphIndex;

pub const GlyphIndexSet = @import("GlyphIndexSet.zig");
pub const GlyphSet = @import("GlyphSet.zig");
pub const Writer = @import("Writer.zig");

/// NOTE: call before GlyphSet.init, which may invoke undefined behavior and/or crash otherwise.
pub fn check(ttf: *const TrueType) !void {
    // call potential future function provided by TrueType library
    // try TrueType.validate(ttf);

    // We later on will assume that there's at least space for the .notdef glyph at 0
    if (ttf.glyphs_len == 0) return error.NoGlyphs;
}

/// Caches table lookups for a glyph to prevent duplicates.
pub const Lazy = struct {
    cached_h_metrics: ?TrueType.HMetrics = null,
    cached_box: ?TrueType.BitmapBox = null,

    pub fn hMetrics(lazy: *Lazy, ttf: *const TrueType, i: GlyphIndex) TrueType.HMetrics {
        if (lazy.cached_h_metrics == null) {
            lazy.cached_h_metrics = ttf.glyphHMetrics(i);
        }
        return lazy.cached_h_metrics.?;
    }

    pub fn box(lazy: *Lazy, ttf: *const TrueType, scale: f32, i: GlyphIndex) TrueType.BitmapBox {
        if (lazy.cached_box == null) {
            lazy.cached_box = ttf.glyphBitmapBox(i, scale, scale);
        }
        return lazy.cached_box.?;
    }
};

pub fn scaled(scale: f32, value: anytype) f32 {
    return @as(f32, @floatFromInt(value)) * scale;
}

pub fn round(comptime Int: type, float_val: f32) ?Int {
    const rounded = @round(float_val);
    return if (rounded >= std.math.minInt(Int) and rounded <= std.math.maxInt(Int)) @intFromFloat(rounded) else null;
}

pub fn roundClamp(comptime Int: type, float_val: f32) Int {
    const rounded = @round(float_val);
    if (rounded < std.math.minInt(Int)) return std.math.minInt(Int);
    if (rounded > std.math.maxInt(Int)) return std.math.maxInt(Int);
    return @intFromFloat(rounded);
}

pub fn lineAdvance(ttf: *const TrueType, scale: f32) f32 {
    const vm = ttf.verticalMetrics();
    return scaled(scale, @as(i32, vm.ascent) - vm.descent + vm.line_gap);
}

/// A UTF-8 iterator that can't fail. Bad encodings emit std.unicode.replacement_character
/// and continue on.
pub const Utf8Iterator = struct {
    bytes: []const u8,

    pub fn next(it: *Utf8Iterator) ?u21 {
        if (it.bytes.len == 0) return null;
        const len = std.unicode.utf8ByteSequenceLength(it.bytes[0]) catch {
            it.bytes = it.bytes[1..];
            return std.unicode.replacement_character;
        };
        if (len > it.bytes.len) {
            it.bytes = it.bytes[it.bytes.len..];
            return std.unicode.replacement_character;
        }
        const codepoint = std.unicode.utf8Decode(it.bytes[0..len]) catch {
            it.bytes = it.bytes[1..];
            return std.unicode.replacement_character;
        };
        it.bytes = it.bytes[len..];
        return codepoint;
    }
};

pub const MeasureOptions = struct {
    kerning: bool = true,
    last_glyph: *?GlyphIndex,
};

/// Measures the horizontal advance of the given text.
pub fn measureX(
    ttf: *const TrueType,
    scale: f32,
    utf8: []const u8,
    options: MeasureOptions,
) f32 {
    var advance: f32 = 0;
    var it: Utf8Iterator = .{ .bytes = utf8 };
    while (it.next()) |codepoint| {
        const glyph_index = ttf.codepointGlyphIndex(codepoint);
        if (options.kerning) {
            if (options.last_glyph.*) |prev| {
                advance += scaled(scale, ttf.glyphKernAdvance(prev, glyph_index));
            }
            options.last_glyph.* = glyph_index;
        }
        advance += scaled(scale, ttf.glyphHMetrics(glyph_index).advance_width);
    }
    return advance;
}

pub const DrawOptions = struct {
    kerning: bool = true,
    last_glyph: *?GlyphIndex,
    src_picture: x11.render.Picture,
    dst_picture: x11.render.Picture,
};

/// Draws text left-to-right. Returns final x position.
pub fn draw(
    scratch: std.mem.Allocator,
    glyph_set: *GlyphSet,
    sink: *x11.RequestSink,
    opt: DrawOptions,
    utf8: []const u8,
    left: f32,
    baseline: i16,
) GlyphSet.UploadError!f32 {
    var it: Utf8Iterator = .{ .bytes = utf8 };
    var cursor_x: f32 = left;
    var buf: [composite_max]CompositeEntry = undefined;
    while (true) {
        const count = try prepareComposite(scratch, glyph_set, sink, opt, &buf, &it, &cursor_x);
        if (count == 0) break;
        try writeComposite(glyph_set, sink, opt, &buf, baseline, count);
    }
    return cursor_x;
}

// Limits the size of our stack buffer.  If text exceeds this max, we'll just
// split it into multiple Composite messages, but result should be identical.
// Having a compile-time known max allows us to perform codepoint/glyph table lookups
// only once. Set this value to 1 to test boundaries when changing the implementation.
const composite_max = 300;

const CompositeEntry = struct {
    delta_x: i16,
    glyph_id: u16,
};

/// Prepare a chunk of glyph entries. Uploads glyphs and advances cursor_x.
/// Returns the number of entries written (0 means no more glyphs).
fn prepareComposite(
    scratch: std.mem.Allocator,
    glyph_set: *GlyphSet,
    sink: *x11.RequestSink,
    opt: DrawOptions,
    buf: *[composite_max]CompositeEntry,
    it: *Utf8Iterator,
    cursor_x: *f32,
) GlyphSet.UploadError!u16 {
    var count: u16 = 0;
    // Track where the server thinks its cursor is (after x_off accumulation).
    // Before the first glyph, the server cursor is at 0 (delta is absolute).
    var server_x: i16 = 0;
    while (count < composite_max) {
        const codepoint = it.next() orelse break;
        const glyph_index = glyph_set.ttf.codepointGlyphIndex(codepoint);
        if (opt.kerning) {
            if (opt.last_glyph.*) |prev| {
                cursor_x.* += glyph_set.scaled(glyph_set.ttf.glyphKernAdvance(prev, glyph_index));
            }
            opt.last_glyph.* = glyph_index;
        }

        var lazy: Lazy = .{};
        try glyph_set.uploadIfNeeded(&lazy, scratch, sink, glyph_index);

        const desired_x = roundClamp(i16, cursor_x.*);
        buf[count] = .{
            .delta_x = desired_x - server_x,
            .glyph_id = @intFromEnum(glyph_index),
        };
        count += 1;

        const advance = lazy.hMetrics(glyph_set.ttf, glyph_index).advance_width;
        cursor_x.* += glyph_set.scaled(advance);
        // Server advances by x_off which was set to @intFromFloat(@round(scaled advance)) during upload
        server_x = desired_x +% @as(i16, @intFromFloat(@round(glyph_set.scaled(advance))));
    }
    return count;
}

/// Write a CompositeGlyphs16 request with the given chunk of glyphs.
fn writeComposite(
    glyph_set: *GlyphSet,
    sink: *x11.RequestSink,
    opt: DrawOptions,
    buf: *const [composite_max]CompositeEntry,
    baseline: i16,
    count: u16,
) error{WriteFailed}!void {
    const header_len = 28;
    const per_glyph_len = 12; // GLYPHELT16: len(1) + pad(3) + delta_x(2) + delta_y(2) + glyph_id(2) + pad(2)
    const msg_len: u32 = header_len + @as(u32, count) * per_glyph_len;

    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        glyph_set.render_ext_opcode,
        @intFromEnum(x11.render.Opcode.composite_glyphs_16),
    });
    try x11.writeInt(sink.writer, &offset, u16, @intCast(msg_len >> 2));
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        @intFromEnum(x11.render.PictureOperation.over),
        0, 0, 0, // padding
    });
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(opt.src_picture));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(opt.dst_picture));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(x11.render.PictureFormat.none)); // mask_format
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(glyph_set.glyphset));
    try x11.writeInt(sink.writer, &offset, i16, 0); // src_x
    try x11.writeInt(sink.writer, &offset, i16, 0); // src_y
    std.debug.assert(offset == header_len);

    for (buf[0..count], 0..) |entry, i| {
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            1, // len: 1 glyph per GLYPHELT
            0, 0, 0, // padding
        });
        try x11.writeInt(sink.writer, &offset, i16, entry.delta_x);
        // delta_y is absolute for the first glyph, 0 for the rest (y_off=0 so server y stays put)
        try x11.writeInt(sink.writer, &offset, i16, if (i == 0) baseline else 0);
        try x11.writeInt(sink.writer, &offset, u16, entry.glyph_id);
        try x11.writeInt(sink.writer, &offset, u16, 0); // pad to 4 bytes
    }
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

const std = @import("std");
const x11 = @import("x11");
