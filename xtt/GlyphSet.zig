const GlyphSet = @This();

ttf: *const TrueType,
render_ext_opcode: u8,
glyphset: x11.render.GlyphSet,
a8_format: x11.render.PictureFormat,
scale: f32,
uploaded: *xtt.GlyphIndexSet,

pub fn init(
    ttf: *const TrueType,
    render_ext_opcode: u8,
    /// The x11 GlyphSet id (XID). This type will send CreateGlyphSet but also frees/recreates on invalidate.
    glyphset: x11.render.GlyphSet,
    /// The A8 PictureFormat. Obtained from x11.render.QueryPictFormats.
    a8_format: x11.render.PictureFormat,
    scale: f32,
    /// Reference to a GlyphIndexSet to track which indices have been uploaded.
    /// Must outlive this GlyphSet, this function initializes it to empty.
    uploaded_ref: *xtt.GlyphIndexSet,
    sink: *x11.RequestSink,
) error{WriteFailed}!GlyphSet {
    std.debug.assert(
        if (xtt.check(ttf)) true else |e| std.debug.panic("check was not called, failed with {t}", .{e}),
    );
    uploaded_ref.* = .initEmpty();
    try x11.render.CreateGlyphSet(sink, render_ext_opcode, glyphset, a8_format);
    return .{
        .ttf = ttf,
        .render_ext_opcode = render_ext_opcode,
        .glyphset = glyphset,
        .a8_format = a8_format,
        .scale = scale,
        .uploaded = uploaded_ref,
    };
}

pub fn deinit(self: *GlyphSet, sink: *x11.RequestSink) error{WriteFailed}!void {
    try x11.render.FreeGlyphSet(sink, self.render_ext_opcode, self.glyphset);
    self.* = undefined;
}

pub fn invalidateCache(self: *GlyphSet, sink: *x11.RequestSink) error{WriteFailed}!void {
    try x11.render.FreeGlyphSet(sink, self.render_ext_opcode, self.glyphset);
    try x11.render.CreateGlyphSet(sink, self.render_ext_opcode, self.glyphset, self.a8_format);
    self.uploaded.clear();
}

pub fn scaled(self: *const GlyphSet, value: anytype) f32 {
    return @as(f32, @floatFromInt(value)) * self.scale;
}

pub fn lineAdvance(self: *const GlyphSet) f32 {
    return xtt.lineAdvance(self.ttf, self.scale);
}

pub fn measureX(self: *const GlyphSet, utf8: []const u8, options: xtt.MeasureOptions) f32 {
    return xtt.measureX(self.ttf, self.scale, utf8, options);
}

pub const ChangeOptions = struct {
    ttf: ?*const TrueType = null,
    size: ?f32 = null,
};

/// Change the font. Properties left null are unchanged. If any properties are
/// changed, the cache will be invalidated.
pub fn change(self: *GlyphSet, sink: *x11.RequestSink, options: ChangeOptions) !void {
    const ttf = options.ttf orelse self.ttf;
    const scale = if (options.size) |size| ttf.scaleForPixelHeight(size) else self.scale;

    if (ttf == self.ttf and scale == self.scale) return;

    self.ttf = ttf;
    self.scale = scale;

    try self.invalidateCache(sink);
}

pub const UploadError = error{
    WriteFailed,
} || TrueType.GlyphBitmapError;

/// Uploads a glyph to the server-side GlyphSet if it hasn't been uploaded yet.
pub fn uploadIfNeeded(
    self: *GlyphSet,
    lazy: *xtt.Lazy,
    /// scratch allocator to rasterize the glyph into before sending to the X server
    scratch: std.mem.Allocator,
    sink: *x11.RequestSink,
    glyph_index: TrueType.GlyphIndex,
) UploadError!void {
    if (self.uploaded.isSet(glyph_index)) return;

    var r8: std.ArrayListUnmanaged(u8) = .empty;
    defer r8.deinit(scratch);
    const dims = self.ttf.glyphBitmap(
        scratch,
        &r8,
        glyph_index,
        self.scale,
        self.scale,
    ) catch |err| switch (err) {
        error.GlyphNotFound => return self.uploadEmpty(lazy, sink, glyph_index),
        else => |e| return e,
    };

    const w: u32 = dims.width;
    const h: u32 = dims.height;
    const stride: u32 = std.mem.alignForward(u32, w, 4);
    const alpha_size: u32 = stride * h;
    const advance: i16 = @intFromFloat(@round(self.scaled(lazy.hMetrics(self.ttf, glyph_index).advance_width)));

    const info: x11.render.GlyphInfo = .{
        .width = dims.width,
        .height = dims.height,
        .x = -dims.off_x,
        .y = -dims.off_y,
        .x_off = advance,
        .y_off = 0,
    };

    const pad_len = try x11.render.AddGlyphsStart(
        sink,
        self.render_ext_opcode,
        self.glyphset,
        @intFromEnum(glyph_index),
        info,
        alpha_size,
    );
    for (0..h) |y| {
        const row_start = y * @as(usize, dims.width);
        try sink.writer.writeAll(r8.items[row_start..][0..dims.width]);
        try sink.writer.splatByteAll(0, @intCast(stride - w));
    }
    try x11.render.AddGlyphsFinish(sink, pad_len);
    self.uploaded.set(glyph_index);
}

/// Upload a zero-size glyph so the server knows the ID exists.
fn uploadEmpty(
    self: *GlyphSet,
    lazy: *xtt.Lazy,
    sink: *x11.RequestSink,
    glyph_index: TrueType.GlyphIndex,
) error{WriteFailed}!void {
    const advance: i16 = @intFromFloat(@round(self.scaled(lazy.hMetrics(self.ttf, glyph_index).advance_width)));
    const info: x11.render.GlyphInfo = .{
        .width = 0,
        .height = 0,
        .x = 0,
        .y = 0,
        .x_off = advance,
        .y_off = 0,
    };
    const pad_len = try x11.render.AddGlyphsStart(
        sink,
        self.render_ext_opcode,
        self.glyphset,
        @intFromEnum(glyph_index),
        info,
        0,
    );
    try x11.render.AddGlyphsFinish(sink, pad_len);
    self.uploaded.set(glyph_index);
}

const std = @import("std");
const x11 = @import("x11");
const TrueType = @import("TrueType");
const xtt = @import("xtt.zig");
