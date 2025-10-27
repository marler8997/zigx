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

    pub fn format(v: Picture, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        if (v == .none) {
            try writer.writeAll("Picture(<none>)");
        } else {
            try writer.print("Picture({})", .{@intFromEnum(v)});
        }
    }
};

pub const PictureFormat = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) PictureFormat {
        return @enumFromInt(i);
    }

    pub fn format(v: PictureFormat, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        if (v == .none) {
            try writer.writeAll("PictureFormat(<none>)");
        } else {
            try writer.print("PictureFormat({})", .{@intFromEnum(v)});
        }
    }
};

pub const ExtOpcode = enum(u8) {
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
    // create_glyph_set = 17,
    // reference_glyph_set = 18,
    // free_glyph_set = 19,
    // add_glyphs = 20,
    // opcode 21 reserved for AddGlyphsFromPicture
    // free_glyphs = 22,
    // composite_glyphs_8 = 23,
    // composite_glyphs_16 = 24,
    // composite_glyphs_32 = 25,
    // new in version 0.1
    // fill_rectangles = 26,
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
    // create_solid_fill = 33,
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
        named: struct {
            ext_opcode: u8,
            major_version: u32,
            minor_version: u32,
        },
    ) error{WriteFailed}!void {
        const msg_len = 12;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            named.ext_opcode,
            @intFromEnum(ExtOpcode.query_version),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, named.major_version);
        try x11.writeInt(sink.writer, &offset, u32, named.minor_version);
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

    pub const format = if (x11.zig_atleast_15) formatNew else formatLegacy;
    fn formatNew(self: PictureFormatInfo, writer: *std.Io.Writer) error{WriteFailed}!void {
        try self.formatLegacy("", .{}, writer);
    }
    fn formatLegacy(
        self: PictureFormatInfo,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
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
        @intFromEnum(ExtOpcode.create_picture),
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
        @intFromEnum(ExtOpcode.composite),
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
        @intFromEnum(ExtOpcode.query_pict_formats),
    });
    try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
    std.debug.assert(offset == msg_len);
    sink.sequence +%= 1;
}
