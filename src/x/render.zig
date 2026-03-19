/// https://www.x.org/releases/current/doc/renderproto/renderproto.txt
const std = @import("std");

const x11 = @import("../x.zig");

pub const name: x11.Slice(u16, [*]const u8) = .initComptime("RENDER");

pub const Picture = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Picture {
        return @enumFromInt(i);
    }

    pub fn format(v: Picture, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .none => try writer.writeAll(".none"),
            _ => |d| try writer.print("{d}", .{d}),
        }
    }
};

pub const GlyphSet = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) GlyphSet {
        return @enumFromInt(i);
    }

    pub fn format(v: GlyphSet, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .none => try writer.writeAll(".none"),
            _ => |d| try writer.print("{d}", .{d}),
        }
    }
};

pub const PictureFormat = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) PictureFormat {
        return @enumFromInt(i);
    }

    pub fn format(v: PictureFormat, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .none => try writer.writeAll(".none"),
            _ => |d| try writer.print("{d}", .{d}),
        }
    }
};

pub const Color = struct {
    red: u16,
    green: u16,
    blue: u16,
    alpha: u16,

    pub fn fromRgb24(rgb: u24) Color {
        return .{
            .red = @as(u16, @as(u8, @truncate(rgb >> 16))) * 0x101,
            .green = @as(u16, @as(u8, @truncate(rgb >> 8))) * 0x101,
            .blue = @as(u16, @as(u8, @truncate(rgb))) * 0x101,
            .alpha = 0xffff,
        };
    }
};

pub const Opcode = enum(u8) {
    query_version = 0,
    query_pict_formats = 1,
    // opcode 3 reserved for QueryDithers
    create_picture = 4,
    // change_picture = 5,
    // set_picture_clip_rectangles = 6,
    free_picture = 7,
    composite = 8,
    // opcode 9 reserved for Scale
    // trapezoids = 10,
    // triangles = 11,
    // tri_strip = 12,
    // tri_fan = 13,
    // opcode 14 reserved for ColorTrapezoids
    // opcode 15 reserved for ColorTriangles
    // opcode 16 reserved for Transform
    create_glyph_set = 17,
    // reference_glyph_set = 18,
    free_glyph_set = 19,
    add_glyphs = 20,
    // opcode 21 reserved for AddGlyphsFromPicture
    // free_glyphs = 22,
    // composite_glyphs_8 = 23,
    composite_glyphs_16 = 24,
    // composite_glyphs_32 = 25,
    // new in version 0.1
    fill_rectangles = 26,
    // new in version 0.5
    // create_cursor = 27,
    // new in version 0.6
    // set_picture_transform = 28,
    // query_filters = 29,
    // set_picture_filter = 30,
    // new in version 0.8
    // create_anim_cursor = 31,
    // new in version 0.9
    // add_traps = 32,
    // new in version 0.10
    create_solid_fill = 33,
    // create_linear_gradient = 34,
    // create_radial_gradient = 35,
    // create_conical_gradient = 36,
};

pub const ErrorCode = enum(u8) {
    PictFormat = 0,
    Picture = 1,
    PictOp = 2,
    GlyphSet = 3,
    Glyph = 4,
    _, // allow unknown errors
};

// Disjoint* and Conjoint* are new in version 0.2
// PDF blend modes are new in version 0.11
pub const PictureOperation = enum(u8) {
    clear = 0,
    src = 1,
    dst = 2,
    over = 3,
    over_reverse = 4,
    in = 5,
    in_reverse = 6,
    out = 7,
    out_reverse = 8,
    atop = 9,
    atop_reverse = 10,
    xor = 11,
    add = 12,
    saturate = 13,

    disjoint_clear = 16,
    disjoint_src = 17,
    disjoint_dst = 18,
    disjoint_over = 19,
    disjoint_over_reverse = 20,
    disjoint_in = 21,
    disjoint_in_reverse = 22,
    disjoint_out = 23,
    disjoint_out_reverse = 24,
    disjoint_atop = 25,
    disjoint_atop_reverse = 26,
    disjoint_xor = 27,

    conjoint_clear = 32,
    conjoint_src = 33,
    conjoint_dst = 34,
    conjoint_over = 35,
    conjoint_over_reverse = 36,
    conjoint_in = 37,
    conjoint_in_reverse = 38,
    conjoint_out = 39,
    conjoint_out_reverse = 40,
    conjoint_atop = 41,
    conjoint_atop_reverse = 42,
    conjoint_xor = 43,

    // PDF blend modes are new in version 0.11
    multiply = 48,
    screen = 49,
    overlay = 50,
    darken = 51,
    lighten = 52,
    colorDodge = 53,
    colorBurn = 54,
    hardLight = 55,
    softLight = 56,
    difference = 57,
    exclusion = 58,
    hsl_hue = 59,
    hsl_saturation = 60,
    hsl_color = 61,
    hsl_luminosity = 62,
};

pub const request = struct {
    pub fn QueryVersion(
        sink: *x11.RequestSink,
        ext_opcode: u8,
        major_version: u32,
        minor_version: u32,
    ) error{WriteFailed}!void {
        const msg_len = 12;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @intFromEnum(Opcode.query_version),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, major_version);
        try x11.writeInt(sink.writer, &offset, u32, minor_version);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }
};

pub const PictureType = enum(u8) {
    indexed = 0,
    direct = 1,
};

pub const DirectFormat = extern struct {
    red_shift: u16,
    red_mask: u16,
    green_shift: u16,
    green_mask: u16,
    blue_shift: u16,
    blue_mask: u16,
    alpha_shift: u16,
    alpha_mask: u16,
};

pub const PictureFormatInfo = extern struct {
    id: PictureFormat,
    type: x11.NonExhaustive(PictureType),
    depth: u8,
    _: [2]u8,
    direct: DirectFormat,
    colormap: u32,

    pub fn format(self: PictureFormatInfo, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.print(
            "id={} type={f} depth={} colormap={} direct={any}",
            .{
                @intFromEnum(self.id),
                x11.fmtEnum(self.type),
                self.depth,
                self.colormap,
                self.direct,
            },
        );
    }
};
comptime {
    if (@sizeOf(PictureFormatInfo) != 28) @compileError("PictureFormatInfo size is wrong");
}

pub fn CreatePicture(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    picture_id: Picture,
    drawable_id: x11.Drawable,
    format_id: PictureFormat,
    options: create_picture.Options,
) error{WriteFailed}!void {
    const msg = inspectCreatePicture(&options);
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(Opcode.create_picture),
    });
    try x11.writeInt(sink.writer, &offset, u16, @intCast(msg.len >> 2));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(picture_id));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(drawable_id));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(format_id));
    try x11.writeInt(sink.writer, &offset, u32, msg.option_mask);
    inline for (std.meta.fields(create_picture.Options)) |field| {
        if (!x11.isDefaultValue(&options, field)) {
            try x11.writeInt(sink.writer, &offset, u32, x11.optionToU32(@field(options, field.name)));
        }
    }
    std.debug.assert(msg.len == offset);
    sink.sequence +%= 1;
}

fn inspectCreatePicture(options: *const create_picture.Options) struct {
    len: u18,
    option_mask: u32,
} {
    const non_option_len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // picture ID
        + 4 // drawable ID
        + 4 // format ID
        + 4 // option mask
    ;
    var len: u18 = non_option_len;
    var option_mask: u32 = 0;
    inline for (std.meta.fields(create_picture.Options)) |field| {
        if (!x11.isDefaultValue(options, field)) {
            option_mask |= @field(create_picture.option_flag, field.name);
            len += 4;
        }
    }
    return .{ .len = len, .option_mask = option_mask };
}

pub const create_picture = struct {
    pub const Repeat = enum(u32) {
        none,
        normal,
        pad,
        reflect,
    };

    pub const PolyEdge = enum(u32) { sharp, smooth };

    pub const PolyMode = enum(u32) { precise, imprecise };

    pub const option_count = 13;
    pub const option_flag = struct {
        pub const repeat: u32 = (1 << 0);
        pub const alpha_map: u32 = (1 << 1);
        pub const alpha_x_origin: u32 = (1 << 2);
        pub const alpha_y_origin: u32 = (1 << 3);
        pub const clip_x_origin: u32 = (1 << 4);
        pub const clip_y_origin: u32 = (1 << 5);
        pub const clip_mask: u32 = (1 << 6);
        pub const graphics_exposures: u32 = (1 << 7);
        pub const subwindow_mode: u32 = (1 << 8);
        pub const poly_edge: u32 = (1 << 9);
        pub const poly_mode: u32 = (1 << 10);
        pub const dither: u32 = (1 << 11);
        pub const component_alpha: u32 = (1 << 12);
    };

    const Options = struct {
        repeat: Repeat = .none,
        alpha_map: u32 = 0, // optional
        alpha_x_origin: i16 = 0,
        alpha_y_origin: i16 = 0,
        clip_x_origin: i16 = 0,
        clip_y_origin: i16 = 0,
        clip_mask: u32 = 0, // optional
        graphics_exposures: bool = false,
        subwindow_mode: x11.SubWindowMode = .clip_by_children,
        poly_edge: PolyEdge = .sharp,
        poly_mode: PolyMode = .precise,
        dither: x11.Atom = @enumFromInt(0), // optional
        component_alpha: bool = false,
    };
};

/// Combine the src and destination pictures with the specified operation.
///
/// For example, if you want to copy the src picture to the destination picture, you
/// would use `PictureOperation.over`.
pub fn Composite(sink: *x11.RequestSink, ext_opcode: u8, named: struct {
    picture_operation: PictureOperation,
    src_picture: Picture,
    mask_picture: Picture,
    dst_picture: Picture,
    src_x: i16,
    src_y: i16,
    mask_x: i16,
    mask_y: i16,
    dst_x: i16,
    dst_y: i16,
    width: u16,
    height: u16,
}) error{WriteFailed}!void {
    const msg_len =
        2 // extension and command opcodes
        + 2 // request length
        + 1 // picture operation
        + 3 // padding
        + 4 // src_picture_id
        + 4 // mask_picture_id
        + 4 // dst_picture_id
        + 2 // src_x
        + 2 // src_y
        + 2 // mask_x
        + 2 // mask_y
        + 2 // dst_x
        + 2 // dst_y
        + 2 // width
        + 2 // height
    ;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(Opcode.composite),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        @intFromEnum(named.picture_operation),
        0, // padding
        0, // padding
        0, // padding
    });
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(named.src_picture));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(named.mask_picture));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(named.dst_picture));
    try x11.writeInt(sink.writer, &offset, i16, named.src_x);
    try x11.writeInt(sink.writer, &offset, i16, named.src_y);
    try x11.writeInt(sink.writer, &offset, i16, named.mask_x);
    try x11.writeInt(sink.writer, &offset, i16, named.mask_y);
    try x11.writeInt(sink.writer, &offset, i16, named.dst_x);
    try x11.writeInt(sink.writer, &offset, i16, named.dst_y);
    try x11.writeInt(sink.writer, &offset, u16, named.width);
    try x11.writeInt(sink.writer, &offset, u16, named.height);
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

pub fn FreePicture(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    picture_id: Picture,
) error{WriteFailed}!void {
    const msg_len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // picture ID
    ;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(Opcode.free_picture),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(picture_id));
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

/// FillRectangles (opcode 26, version 0.1)
/// Fills rectangles in a Picture with a solid color using the specified operation.
pub fn FillRectangles(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    named: struct {
        picture_operation: PictureOperation,
        dst_picture: Picture,
        color: Color,
        rects: x11.Slice(u16, [*]const x11.Rectangle),
    },
) error{WriteFailed}!void {
    const header_len = 20;
    const rects_len: u32 = @as(u32, named.rects.len) * 8;
    const msg_len: u32 = header_len + rects_len;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(Opcode.fill_rectangles),
    });
    try x11.writeInt(sink.writer, &offset, u16, @intCast(msg_len >> 2));
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        @intFromEnum(named.picture_operation),
        0, 0, 0, // padding
    });
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(named.dst_picture));
    try x11.writeInt(sink.writer, &offset, u16, named.color.red);
    try x11.writeInt(sink.writer, &offset, u16, named.color.green);
    try x11.writeInt(sink.writer, &offset, u16, named.color.blue);
    try x11.writeInt(sink.writer, &offset, u16, named.color.alpha);
    std.debug.assert(offset == header_len);
    for (0..named.rects.len) |i| {
        const rect = named.rects.ptr[i];
        try x11.writeInt(sink.writer, &offset, i16, rect.x);
        try x11.writeInt(sink.writer, &offset, i16, rect.y);
        try x11.writeInt(sink.writer, &offset, u16, rect.width);
        try x11.writeInt(sink.writer, &offset, u16, rect.height);
    }
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

/// CreateSolidFill (opcode 33, version 0.10)
/// Creates a Picture filled with a solid color that can be used as a repeating source.
pub fn CreateSolidFill(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    picture_id: Picture,
    color: Color,
) error{WriteFailed}!void {
    const msg_len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // picture ID
        + 8 // color (4 x u16)
    ;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(Opcode.create_solid_fill),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(picture_id));
    try x11.writeInt(sink.writer, &offset, u16, color.red);
    try x11.writeInt(sink.writer, &offset, u16, color.green);
    try x11.writeInt(sink.writer, &offset, u16, color.blue);
    try x11.writeInt(sink.writer, &offset, u16, color.alpha);
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

pub const GlyphInfo = extern struct {
    width: u16,
    height: u16,
    x: i16,
    y: i16,
    x_off: i16,
    y_off: i16,
};
comptime {
    if (@sizeOf(GlyphInfo) != 12) @compileError("GlyphInfo size is wrong");
}

pub fn CreateGlyphSet(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    gsid: GlyphSet,
    format: PictureFormat,
) error{WriteFailed}!void {
    const msg_len = 12;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(Opcode.create_glyph_set),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(gsid));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(format));
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

pub fn FreeGlyphSet(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    gsid: GlyphSet,
) error{WriteFailed}!void {
    const msg_len = 8;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(Opcode.free_glyph_set),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(gsid));
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

/// Begin adding a single glyph to a GlyphSet. Writes the request header;
/// the caller then streams `alpha_size` bytes of alpha data directly to `sink.writer`,
/// and finishes with `AddGlyphsFinish`.
pub fn AddGlyphsStart(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    gsid: GlyphSet,
    glyph_id: u32,
    info: GlyphInfo,
    alpha_size: u32,
) error{WriteFailed}!u2 {
    const header_len = 28; // 12 header + 4 glyph_id + 12 glyph_info
    const pad_len: u2 = @truncate((4 -% alpha_size) & 3);
    const msg_len: u32 = header_len + alpha_size + pad_len;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(Opcode.add_glyphs),
    });
    try x11.writeInt(sink.writer, &offset, u16, @intCast(msg_len >> 2));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(gsid));
    try x11.writeInt(sink.writer, &offset, u32, 1); // num glyphs
    try x11.writeInt(sink.writer, &offset, u32, glyph_id); // glyph id
    // GlyphInfo
    try x11.writeInt(sink.writer, &offset, u16, info.width);
    try x11.writeInt(sink.writer, &offset, u16, info.height);
    try x11.writeInt(sink.writer, &offset, i16, info.x);
    try x11.writeInt(sink.writer, &offset, i16, info.y);
    try x11.writeInt(sink.writer, &offset, i16, info.x_off);
    try x11.writeInt(sink.writer, &offset, i16, info.y_off);
    std.debug.assert(offset == header_len);
    return pad_len;
}

/// Finish an AddGlyphs request after streaming alpha data.
pub fn AddGlyphsFinish(sink: *x11.RequestSink, pad_len: u2) error{WriteFailed}!void {
    try sink.writer.splatByteAll(0, pad_len);
    sink.sequence +%= 1;
}

/// Render glyphs from a GlyphSet onto a destination Picture.
/// Sends a single GLYPHELT16 with one glyph.
pub fn CompositeGlyphs16(
    sink: *x11.RequestSink,
    ext_opcode: u8,
    named: struct {
        picture_operation: PictureOperation,
        src_picture: Picture,
        dst_picture: Picture,
        mask_format: PictureFormat,
        glyphset: GlyphSet,
        src_x: i16,
        src_y: i16,
        delta_x: i16,
        delta_y: i16,
        glyph_id: u16,
    },
) error{WriteFailed}!void {
    const msg_len = 28 // header
        + 8 // GLYPHELT16 header (len u8 + pad[3] + delta_x i16 + delta_y i16)
        + 2 // one u16 glyph id
        + 2 // padding to 4-byte boundary
    ;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(Opcode.composite_glyphs_16),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        @intFromEnum(named.picture_operation),
        0, 0, 0, // padding
    });
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(named.src_picture));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(named.dst_picture));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(named.mask_format));
    try x11.writeInt(sink.writer, &offset, u32, @intFromEnum(named.glyphset));
    try x11.writeInt(sink.writer, &offset, i16, named.src_x);
    try x11.writeInt(sink.writer, &offset, i16, named.src_y);
    // GLYPHELT16: len=1, pad, delta_x, delta_y, glyph_id
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        1, // len: 1 glyph
        0, 0, 0, // padding
    });
    try x11.writeInt(sink.writer, &offset, i16, named.delta_x);
    try x11.writeInt(sink.writer, &offset, i16, named.delta_y);
    try x11.writeInt(sink.writer, &offset, u16, named.glyph_id);
    try x11.writeInt(sink.writer, &offset, u16, 0); // pad to 4-byte boundary
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

pub fn QueryPictFormats(
    sink: *x11.RequestSink,
    ext_opcode: u8,
) error{WriteFailed}!void {
    const msg_len =
        2 // extension and command opcodes
        + 2 // request length
    ;
    var offset: usize = 0;
    try x11.writeAll(sink.writer, &offset, &[_]u8{
        ext_opcode,
        @intFromEnum(Opcode.query_pict_formats),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}

const PictScreenHeader = extern struct {
    num_depths: u32,
    fallback: PictureFormat,
};
comptime {
    std.debug.assert(@sizeOf(PictScreenHeader) == 8);
}

const PictDepthHeader = extern struct {
    depth: u8,
    _pad1: u8,
    num_visuals: u16,
    _pad2: u32,
};
comptime {
    std.debug.assert(@sizeOf(PictDepthHeader) == 8);
}

const PictVisualEntry = extern struct {
    visual: x11.Visual,
    format: PictureFormat,
};
comptime {
    std.debug.assert(@sizeOf(PictVisualEntry) == 8);
}

/// Reader for the QueryPictFormats reply. Enforces reading order: formats first, then visuals.
/// Use `discardRemaining` (or defer it) to skip any trailing data (subpixel entries, etc.).
pub const PictFormatsReader = struct {
    formats_remaining: u32,
    screens_remaining: u32,
    depths_remaining: u32,
    visuals_remaining: u32,

    pub fn init(header: x11.stage3.render_QueryPictFormats) PictFormatsReader {
        return .{
            .formats_remaining = header.num_formats,
            .screens_remaining = header.num_screens,
            .depths_remaining = header.num_depths,
            .visuals_remaining = header.num_visuals,
        };
    }

    pub fn formatReader(self: *PictFormatsReader) FormatReader {
        return .{ .pict_reader = self };
    }

    pub fn visualReader(self: *PictFormatsReader) VisualReader {
        std.debug.assert(self.formats_remaining == 0);
        return .{
            .pict_reader = self,
            .depths_remaining = 0,
            .visuals_remaining = 0,
        };
    }

    pub fn discardRemaining(self: *PictFormatsReader, source: *x11.Source) error{ ReadFailed, EndOfStream }!void {
        var fr = self.formatReader();
        try fr.discardRemaining(source);
        var vr = self.visualReader();
        try vr.discardRemaining(source);
        // Discard any remaining data (subpixel entries, etc.)
        try source.replyDiscard(source.replyRemainingSize());
    }
};

/// Iterator over PictureFormatInfo entries in a QueryPictFormats reply.
pub const FormatReader = struct {
    pict_reader: *PictFormatsReader,

    pub fn next(self: *FormatReader, source: *x11.Source) error{ ReadFailed, EndOfStream }!?PictureFormatInfo {
        if (self.pict_reader.formats_remaining == 0) return null;
        var format: PictureFormatInfo = undefined;
        try source.readReply(std.mem.asBytes(&format));
        self.pict_reader.formats_remaining -= 1;
        return format;
    }

    pub fn discardRemaining(self: *FormatReader, source: *x11.Source) error{ ReadFailed, EndOfStream }!void {
        if (self.pict_reader.formats_remaining > 0) {
            try source.replyDiscard(@as(usize, self.pict_reader.formats_remaining) * @sizeOf(PictureFormatInfo));
            self.pict_reader.formats_remaining = 0;
        }
    }
};

/// Iterator over visual-to-PictureFormat mappings in a QueryPictFormats reply. Flattens the
/// nested screen/depth/visual structure into a stream of entries.
pub const VisualReader = struct {
    pict_reader: *PictFormatsReader,
    depths_remaining: u32,
    visuals_remaining: u32,

    pub fn next(self: *VisualReader, source: *x11.Source) error{ ReadFailed, EndOfStream }!?PictVisualEntry {
        while (self.visuals_remaining == 0) {
            while (self.depths_remaining == 0) {
                if (self.pict_reader.screens_remaining == 0) return null;
                var hdr: PictScreenHeader = undefined;
                try source.readReply(std.mem.asBytes(&hdr));
                self.pict_reader.screens_remaining -= 1;
                self.depths_remaining = hdr.num_depths;
            }
            var hdr: PictDepthHeader = undefined;
            try source.readReply(std.mem.asBytes(&hdr));
            self.depths_remaining -= 1;
            self.pict_reader.depths_remaining -= 1;
            self.visuals_remaining = hdr.num_visuals;
        }
        var entry: PictVisualEntry = undefined;
        try source.readReply(std.mem.asBytes(&entry));
        self.visuals_remaining -= 1;
        self.pict_reader.visuals_remaining -= 1;
        return entry;
    }

    pub fn discardRemaining(self: *VisualReader, source: *x11.Source) error{ ReadFailed, EndOfStream }!void {
        if (self.visuals_remaining > 0) {
            try source.replyDiscard(@as(usize, self.visuals_remaining) * @sizeOf(PictVisualEntry));
            self.pict_reader.visuals_remaining -= self.visuals_remaining;
            self.visuals_remaining = 0;
        }
        while (self.depths_remaining > 0) {
            var hdr: PictDepthHeader = undefined;
            try source.readReply(std.mem.asBytes(&hdr));
            self.depths_remaining -= 1;
            self.pict_reader.depths_remaining -= 1;
            if (hdr.num_visuals > 0) {
                try source.replyDiscard(@as(usize, hdr.num_visuals) * @sizeOf(PictVisualEntry));
                self.pict_reader.visuals_remaining -= hdr.num_visuals;
            }
        }
        while (self.pict_reader.screens_remaining > 0) {
            var screen_hdr: PictScreenHeader = undefined;
            try source.readReply(std.mem.asBytes(&screen_hdr));
            self.pict_reader.screens_remaining -= 1;
            var depths = screen_hdr.num_depths;
            while (depths > 0) {
                var depth_hdr: PictDepthHeader = undefined;
                try source.readReply(std.mem.asBytes(&depth_hdr));
                depths -= 1;
                self.pict_reader.depths_remaining -= 1;
                if (depth_hdr.num_visuals > 0) {
                    try source.replyDiscard(@as(usize, depth_hdr.num_visuals) * @sizeOf(PictVisualEntry));
                    self.pict_reader.visuals_remaining -= depth_hdr.num_visuals;
                }
            }
        }
    }
};

pub fn createPixmapPicture(
    sink: *x11.RequestSink,
    render_opcode: u8,
    pixmap: x11.Pixmap,
    picture: x11.render.Picture,
    drawable: x11.Drawable,
    visual_format: x11.render.PictureFormat,
    depth: x11.Depth,
    width: u16,
    height: u16,
) error{WriteFailed}!void {
    try sink.CreatePixmap(pixmap, drawable, .{ .depth = depth, .width = width, .height = height });
    try x11.render.CreatePicture(sink, render_opcode, picture, pixmap.drawable(), visual_format, .{});
}

pub fn recreatePixmapPicture(
    sink: *x11.RequestSink,
    render_opcode: u8,
    pixmap: x11.Pixmap,
    picture: x11.render.Picture,
    drawable: x11.Drawable,
    visual_format: x11.render.PictureFormat,
    depth: x11.Depth,
    width: u16,
    height: u16,
) error{WriteFailed}!void {
    try x11.render.FreePicture(sink, render_opcode, picture);
    try sink.FreePixmap(pixmap);
    try createPixmapPicture(
        sink,
        render_opcode,
        pixmap,
        picture,
        drawable,
        visual_format,
        depth,
        width,
        height,
    );
}
