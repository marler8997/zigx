/// A writer that draws utf8 using X11 Render glyphs.
const Writer = @This();

glyph_set: *xtt.GlyphSet,
src_picture: x11.render.Picture,
gpa: Allocator,
sink: *x11.RequestSink,
dst_picture: x11.render.Picture,
cursor: XY(f32),
kerning: bool = true,
left_margin: f32,
/// The last glyph drawn. Used for kerning. Cleared automatically by `setCursor`, if you set the
/// cursor position manually you should clear this value.
last_glyph: ?TrueType.GlyphIndex = null,
interface: std.Io.Writer,
err: ?Error = null,
alignment: Alignment = .left,
needs_flush: bool = false,

pub const Error = error{
    WriteFailed,
    /// Writer's buffer is too small. In some cases (i.e. alignment), Writer
    /// needs to measure the width of a full string before it can render any of it. In these
    /// cases, buffer needs to be large enough to accomodate.
    NoSpaceLeft,
} || TrueType.GlyphBitmapError;

pub const Alignment = enum {
    left,
    right,
    center,
};

pub const Options = struct {
    glyph_set: *xtt.GlyphSet,
    src_picture: x11.render.Picture,
    gpa: Allocator,
    sink: *x11.RequestSink,
    dst_picture: x11.render.Picture,
    cursor: XY(f32),
    kerning: bool = true,
    left_margin: f32,
    buffer: []u8,
};

pub fn init(options: Options) Writer {
    return .{
        .glyph_set = options.glyph_set,
        .src_picture = options.src_picture,
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
pub fn newline(self: *Writer) Error!void {
    try self.setCursor(.{
        .x = self.left_margin,
        .y = self.cursor.y + self.glyph_set.lineAdvance(),
    });
}

/// Flushes and then sets a new cursor position.
pub fn setCursor(self: *Writer, cursor: XY(f32)) Error!void {
    try self.interface.flush();
    self.cursor = cursor;
    self.last_glyph = null;
}

/// Flushes then sets the alignment for upcoming text. Keep in mind that different alignments
/// have different minimum buffer sizes.
///
/// Left alignment puts no requirements on the buffer size.
///
/// Right and center alignment require an explicit flush to free up the buffer. This is because
/// when center or right aligning text, the full string needs to be known before any of it can
/// be drawn. As a result, the buffer must be large enough to avoid calls to drain in between
/// flushes. You can still make arbitrarily large writes with a small buffer (see `writeVec`),
/// they must be followed by an explicit flush.
pub fn setAlignment(self: *Writer, alignment: Alignment) Error!void {
    try self.interface.flush();
    self.alignment = alignment;
}

fn flush(writer: *std.Io.Writer) error{WriteFailed}!void {
    const tw: *Writer = @fieldParentPtr("interface", writer);
    try writer.defaultFlush();
    tw.needs_flush = false;
}

fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
    const tw: *Writer = @fieldParentPtr("interface", writer);
    if (tw.err != null) return error.WriteFailed;
    if (tw.needs_flush) return tw.fail(error.NoSpaceLeft);

    const buffered = writer.buffered();
    _ = writer.consumeAll();
    const slice = data[0 .. data.len - 1];
    const pattern = data[data.len - 1];

    // Measure the text to be written and offset the cursor if necessary
    switch (tw.alignment) {
        .left => {},
        .right, .center => {
            var advance: f32 = 0;
            var last_glyph: ?TrueType.GlyphIndex = null;
            const options: xtt.MeasureOptions = .{
                .kerning = tw.kerning,
                .last_glyph = &last_glyph,
            };
            advance += tw.glyph_set.measureX(buffered, options);
            for (slice) |bytes| advance += tw.glyph_set.measureX(bytes, options);
            for (0..splat) |_| advance += tw.glyph_set.measureX(pattern, options);

            switch (tw.alignment) {
                .left => unreachable,
                .right => tw.cursor.x -= advance,
                .center => tw.cursor.x -= advance / 2,
            }
            tw.last_glyph = null;
            tw.needs_flush = true;
        },
    }

    // Write the text
    try tw.mapErr(tw.writeAll(buffered));
    for (slice) |bytes| try tw.mapErr(tw.writeAll(bytes));
    for (0..splat) |_| try tw.mapErr(tw.writeAll(pattern));

    return std.Io.Writer.countSplat(data, splat);
}

fn writeAll(self: *Writer, utf8: []const u8) Error!void {
    self.cursor.x = try xtt.draw(
        self.gpa,
        self.glyph_set,
        self.sink,
        .{
            .kerning = self.kerning,
            .last_glyph = &self.last_glyph,
            .src_picture = self.src_picture,
            .dst_picture = self.dst_picture,
        },
        utf8,
        self.cursor.x,
        @intFromFloat(@round(self.cursor.y)),
    );
}

fn mapErr(
    self: *Writer,
    res: anytype,
) error{WriteFailed}!@typeInfo(@TypeOf(res)).error_union.payload {
    return res catch |err| return self.fail(err);
}

fn fail(self: *Writer, err: Error) error{WriteFailed} {
    self.err = err;
    return error.WriteFailed;
}

const std = @import("std");
const x11 = @import("x11");
const XY = x11.XY;
const TrueType = @import("TrueType");
const Allocator = std.mem.Allocator;
const xtt = @import("xtt.zig");
