/// https://www.x.org/releases/current/doc/renderproto/renderproto.txt
const std = @import("std");

const x11 = @import("x.zig");

pub const name = x11.Slice(u16, [*]const u8).initComptime("RENDER");

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

pub const GlyphSet = enum(u32) {
    none = 0,
    _,
};

pub const ExtOpcode = enum(u8) {
    query_version = 0,
    query_pict_formats = 1,
    query_pict_index_values = 2,
    create_picture = 4,
    change_picture = 5,
    set_picture_clip_rectangles = 6,
    free_picture = 7,
    composite = 8,
    trapezoids = 10,
    triangles = 11,
    tri_strip = 12,
    tri_fan = 13,
    create_glyph_set = 17,
    reference_glyph_set = 18,
    free_glyph_set = 19,
    add_glyphs = 20,
    add_glyphs_from_picture = 21,
    free_glyphs = 22,
    composite_glyphs8 = 23,
    composite_glyphs16 = 24,
    composite_glyphs32 = 25,
    fill_rectangles = 26,
    create_cursor = 27,
    set_picture_transform = 28,
    query_filters = 29,
    set_picture_filter = 30,
    create_solid_fill = 33,
    create_linear_gradient = 34,
    create_radial_gradient = 35,
    create_conical_gradient = 36,
};

pub const ErrorCode = enum(u8) {
    PictFormat = 0,
    Picture = 1,
    PictOp = 2,
    GlyphSet = 3,
    Glyph = 4,
    _, // allow unknown errors
};

pub const Glyph = u32;

pub const Fixed = i32;

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
    _,
};

pub const SubPixel = enum(u8) {
    unknown = 0,
    horizontal_rgb = 1,
    horizontal_bgr = 2,
    vertical_rgb = 3,
    vertical_bgr = 4,
    none = 5,
    _,
};

pub const Color = extern struct {
    red: u16,
    green: u16,
    blue: u16,
    alpha: u16,
};

pub const ChannelInfo = extern struct {
    shift: u16,
    mask: u16,
};

pub const GlyphInfo = extern struct {
    width: u16,
    height: u16,
    x: i16,
    y: i16,
    x_off: i16,
    y_off: i16,
};

pub const GlyphElt8 = struct {
    dx: i16,
    dy: i16,
    glyphs: []const u8,
};

pub const GlyphElt16 = struct {
    dx: i16,
    dy: i16,
    glyphs: []const u16,
};

pub const GlyphElt32 = struct {
    dx: i16,
    dy: i16,
    glyphs: []const u32,
};

pub const query_version = struct {
    pub const len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // client major version
        + 4 // client minor version
    ;
    pub const Args = struct {
        major_version: u32,
        minor_version: u32,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.query_version);
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, len >> 2);
        x11.writeIntNative(u32, buf + 4, args.major_version);
        x11.writeIntNative(u32, buf + 8, args.minor_version);
    }
    pub const Reply = extern struct {
        response_type: x11.ReplyKind,
        unused_pad: u8,
        sequence: u16,
        word_len: u32,
        major_version: u32,
        minor_version: u32,
        reserved: [16]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(Reply) == 32);
    }
};

pub const PictureType = enum(u8) {
    indexed = 0,
    direct = 1,
    _,
};

pub const DirectFormat = extern struct {
    red: ChannelInfo,
    green: ChannelInfo,
    blue: ChannelInfo,
    alpha: ChannelInfo,
};

pub const PictureFormatInfo = extern struct {
    id: PictureFormat,
    type: PictureType,
    depth: u8,
    _: [2]u8,
    direct: DirectFormat,
    colormap: x11.ColorMap,
};
comptime {
    if (@sizeOf(PictureFormatInfo) != 28) @compileError("PictureFormatInfo size is wrong");
}

pub const query_pict_formats = struct {
    pub const len =
        2 // extension and command opcodes
        + 2 // request length
    ;
    pub fn serialize(buf: [*]u8, ext_opcode: u8) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.query_pict_formats);
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, len >> 2);
    }
    pub const Reply = extern struct {
        response_type: x11.ReplyKind,
        unused_pad: u8,
        sequence: u16,
        word_len: u32,
        num_formats: u32,
        num_screens: u32,
        num_depths: u32,
        num_visuals: u32,
        num_subpixel: u32, // new in version 0.6
        unused: u32,
        _picture_formats_array_start: [0]PictureFormatInfo,

        pub fn getPictureFormats(self: *@This()) []align(4) const PictureFormatInfo {
            const picture_format_ptr_list: [*]align(4) PictureFormatInfo = @ptrFromInt(@intFromPtr(&self._picture_formats_array_start));
            return picture_format_ptr_list[0..self.num_formats];
        }

        // TODO: Get lists of screens, depths, visuals, subpixels
    };
    comptime {
        std.debug.assert(@sizeOf(Reply) == 32);
    }
};

pub const create_picture = struct {
    pub const Repeat = enum(u32) {
        none,
        normal,
        pad,
        reflect,
    };

    pub const PolyEdge = enum(u32) { sharp, smooth };

    pub const PolyMode = enum(u32) { precise, imprecise };

    pub const create_picture_option_count = 13;
    pub const create_picture_option_flag = struct {
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

    const CreatePictureOptions = struct {
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

    pub const non_option_len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // picture ID
        + 4 // drawable ID
        + 4 // format ID
        + 4 // option mask
    ;
    pub const max_len = non_option_len + (create_picture_option_count * 4);
    pub const Args = struct {
        picture_id: Picture,
        drawable_id: x11.Drawable,
        format_id: PictureFormat,
        options: CreatePictureOptions,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) u16 {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.create_picture);
        // buf[2-3] is the len, set at the end of the function
        x11.writeIntNative(u32, buf + 4, @intFromEnum(args.picture_id));
        x11.writeIntNative(u32, buf + 8, @intFromEnum(args.drawable_id));
        x11.writeIntNative(u32, buf + 12, @intFromEnum(args.format_id));

        var option_mask: u32 = 0;
        var request_len: u16 = non_option_len;

        inline for (std.meta.fields(CreatePictureOptions)) |field| {
            if (!x11.isDefaultValue(args.options, field)) {
                x11.writeIntNative(u32, buf + request_len, x11.optionToU32(@field(args.options, field.name)));
                option_mask |= @field(create_picture_option_flag, field.name);
                request_len += 4;
            }
        }
        x11.writeIntNative(u32, buf + non_option_len - 4, option_mask);
        x11.writeIntNative(u16, buf + 2, request_len >> 2);
        std.debug.assert(request_len & 0x3 == 0);
        return request_len;
    }
};

pub const free_picture = struct {
    pub const len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // picture
    ;
    pub const Args = struct {
        picture: Picture,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.free_picture);
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, len >> 2);
        x11.writeIntNative(u32, buf + 4, @intFromEnum(args.picture));
    }
};

pub const composite = struct {
    pub const len =
        2 // extension and command opcodes
        + 2 // request length
        + 1 // op
        + 3 // pad
        + 4 // src
        + 4 // mask
        + 4 // dst
        + 2 // src_x
        + 2 // src_y
        + 2 // mask_x
        + 2 // mask_y
        + 2 // dst_x
        + 2 // dst_y
        + 2 // width
        + 2 // height
    ;
    pub const Args = struct {
        op: PictureOperation,
        src: Picture,
        mask: Picture,
        dst: Picture,
        src_x: i16,
        src_y: i16,
        mask_x: i16,
        mask_y: i16,
        dst_x: i16,
        dst_y: i16,
        width: u16,
        height: u16,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.composite);
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, len >> 2);
        buf[4] = @intFromEnum(args.op);
        buf[5] = 0;
        buf[6] = 0;
        buf[7] = 0;
        x11.writeIntNative(u32, buf + 8, args.src.toId());
        x11.writeIntNative(u32, buf + 12, args.mask.toId());
        x11.writeIntNative(u32, buf + 16, args.dst.toId());
        x11.writeIntNative(i16, buf + 20, args.src_x);
        x11.writeIntNative(i16, buf + 22, args.src_y);
        x11.writeIntNative(i16, buf + 24, args.mask_x);
        x11.writeIntNative(i16, buf + 26, args.mask_y);
        x11.writeIntNative(i16, buf + 28, args.dst_x);
        x11.writeIntNative(i16, buf + 30, args.dst_y);
        x11.writeIntNative(u16, buf + 32, args.width);
        x11.writeIntNative(u16, buf + 34, args.height);
    }
};

pub const create_glyph_set = struct {
    pub const len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // gsid
        + 4 // format
    ;
    pub const Args = struct {
        gsid: GlyphSet,
        format: PictureFormat,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.create_glyph_set);
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, len >> 2);
        x11.writeIntNative(u32, buf + 4, @intFromEnum(args.gsid));
        x11.writeIntNative(u32, buf + 8, @intFromEnum(args.format));
    }
};

pub const free_glyph_set = struct {
    pub const len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // gsid
    ;
    pub const Args = struct {
        gsid: GlyphSet,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.free_glyph_set);
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, len >> 2);
        x11.writeIntNative(u32, buf + 4, @intFromEnum(args.gsid));
    }
};

pub const add_glyphs = struct {
    pub const non_list_len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // gsid
        + 4 // num_glyphs
    ;
    pub fn getLen(num_glyphs: u32, data_len: u32) u32 {
        const glyph_ids_len = num_glyphs * 4;
        const glyph_info_len = num_glyphs * @sizeOf(GlyphInfo);
        const padded_data_len = (data_len + 3) & ~@as(u32, 3);
        return non_list_len + glyph_ids_len + glyph_info_len + padded_data_len;
    }
    pub const Args = struct {
        gsid: GlyphSet,
        glyphs: []const Glyph,
        glyph_infos: []const GlyphInfo,
        data: []const u8,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) void {
        const num_glyphs: u32 = @intCast(args.glyphs.len);
        std.debug.assert(args.glyph_infos.len == num_glyphs);

        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.add_glyphs);
        x11.writeIntNative(u32, buf + 4, @intFromEnum(args.gsid));
        x11.writeIntNative(u32, buf + 8, num_glyphs);

        var offset: usize = non_list_len;

        for (args.glyphs) |glyph| {
            x11.writeIntNative(u32, buf + offset, glyph);
            offset += 4;
        }

        for (args.glyph_infos) |info| {
            x11.writeIntNative(u16, buf + offset, info.width);
            x11.writeIntNative(u16, buf + offset + 2, info.height);
            x11.writeIntNative(i16, buf + offset + 4, info.x);
            x11.writeIntNative(i16, buf + offset + 6, info.y);
            x11.writeIntNative(i16, buf + offset + 8, info.x_off);
            x11.writeIntNative(i16, buf + offset + 10, info.y_off);
            offset += @sizeOf(GlyphInfo);
        }

        @memcpy(buf[offset .. offset + args.data.len], args.data);
        offset += args.data.len;

        while (offset & 3 != 0) : (offset += 1) {
            buf[offset] = 0;
        }

        const len = offset;
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, @intCast(len >> 2));
    }
};

pub const free_glyphs = struct {
    pub const non_list_len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // gsid
    ;
    pub fn getLen(num_glyphs: u32) u32 {
        return non_list_len + (num_glyphs * 4);
    }
    pub const Args = struct {
        gsid: GlyphSet,
        glyphs: []const Glyph,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.free_glyphs);
        x11.writeIntNative(u32, buf + 4, args.gsid.toId());

        var offset: usize = non_list_len;
        for (args.glyphs) |glyph| {
            x11.writeIntNative(u32, buf + offset, glyph);
            offset += 4;
        }

        const len = offset;
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, @intCast(len >> 2));
    }
};

pub const composite_glyphs8 = struct {
    pub const non_list_len =
        2 // extension and command opcodes
        + 2 // request length
        + 1 // op
        + 3 // pad
        + 4 // src
        + 4 // dst
        + 4 // mask_format
        + 4 // gsid
        + 2 // src_x
        + 2 // src_y
    ;
    pub fn getLen(glyphelt_bytes: u32) u32 {
        const padded_len = (glyphelt_bytes + 3) & ~@as(u32, 3);
        return non_list_len + padded_len;
    }
    pub const Args = struct {
        op: PictureOperation,
        src: Picture,
        dst: Picture,
        mask_format: PictureFormat,
        gsid: GlyphSet,
        src_x: i16,
        src_y: i16,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args, glyphelts: []const u8) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.composite_glyphs8);
        buf[4] = @intFromEnum(args.op);
        buf[5] = 0;
        buf[6] = 0;
        buf[7] = 0;
        x11.writeIntNative(u32, buf + 8, @intFromEnum(args.src));
        x11.writeIntNative(u32, buf + 12, @intFromEnum(args.dst));
        x11.writeIntNative(u32, buf + 16, @intFromEnum(args.mask_format));
        x11.writeIntNative(u32, buf + 20, @intFromEnum(args.gsid));
        x11.writeIntNative(i16, buf + 24, args.src_x);
        x11.writeIntNative(i16, buf + 26, args.src_y);

        var offset: usize = non_list_len;
        @memcpy(buf[offset .. offset + glyphelts.len], glyphelts);
        offset += glyphelts.len;

        while (offset & 3 != 0) : (offset += 1) {
            buf[offset] = 0;
        }

        const len = offset;
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, @intCast(len >> 2));
    }
};

pub const composite_glyphs16 = struct {
    pub const non_list_len =
        2 // extension and command opcodes
        + 2 // request length
        + 1 // op
        + 3 // pad
        + 4 // src
        + 4 // dst
        + 4 // mask_format
        + 4 // gsid
        + 2 // src_x
        + 2 // src_y
    ;
    pub fn getLen(glyphelt_bytes: u32) u32 {
        const padded_len = (glyphelt_bytes + 3) & ~@as(u32, 3);
        return non_list_len + padded_len;
    }
    pub const Args = struct {
        op: PictureOperation,
        src: Picture,
        dst: Picture,
        mask_format: PictureFormat,
        gsid: GlyphSet,
        src_x: i16,
        src_y: i16,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args, glyphelts: []const u8) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.composite_glyphs16);
        buf[4] = @intFromEnum(args.op);
        buf[5] = 0;
        buf[6] = 0;
        buf[7] = 0;
        x11.writeIntNative(u32, buf + 8, args.src.toId());
        x11.writeIntNative(u32, buf + 12, args.dst.toId());
        x11.writeIntNative(u32, buf + 16, args.mask_format.toId());
        x11.writeIntNative(u32, buf + 20, args.gsid.toId());
        x11.writeIntNative(i16, buf + 24, args.src_x);
        x11.writeIntNative(i16, buf + 26, args.src_y);

        var offset: usize = non_list_len;
        @memcpy(buf[offset .. offset + glyphelts.len], glyphelts);
        offset += glyphelts.len;

        while (offset & 3 != 0) : (offset += 1) {
            buf[offset] = 0;
        }

        const len = offset;
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, @intCast(len >> 2));
    }
};

pub const composite_glyphs32 = struct {
    pub const non_list_len =
        2 // extension and command opcodes
        + 2 // request length
        + 1 // op
        + 3 // pad
        + 4 // src
        + 4 // dst
        + 4 // mask_format
        + 4 // gsid
        + 2 // src_x
        + 2 // src_y
    ;
    pub fn getLen(glyphelt_bytes: u32) u32 {
        const padded_len = (glyphelt_bytes + 3) & ~@as(u32, 3);
        return non_list_len + padded_len;
    }
    pub const Args = struct {
        op: PictureOperation,
        src: Picture,
        dst: Picture,
        mask_format: PictureFormat,
        gsid: GlyphSet,
        src_x: i16,
        src_y: i16,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args, glyphelts: []const u8) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.composite_glyphs32);
        buf[4] = @intFromEnum(args.op);
        buf[5] = 0;
        buf[6] = 0;
        buf[7] = 0;
        x11.writeIntNative(u32, buf + 8, args.src.toId());
        x11.writeIntNative(u32, buf + 12, args.dst.toId());
        x11.writeIntNative(u32, buf + 16, args.mask_format.toId());
        x11.writeIntNative(u32, buf + 20, args.gsid.toId());
        x11.writeIntNative(i16, buf + 24, args.src_x);
        x11.writeIntNative(i16, buf + 26, args.src_y);

        var offset: usize = non_list_len;
        @memcpy(buf[offset .. offset + glyphelts.len], glyphelts);
        offset += glyphelts.len;

        while (offset & 3 != 0) : (offset += 1) {
            buf[offset] = 0;
        }

        const len = offset;
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, @intCast(len >> 2));
    }
};

pub const fill_rectangles = struct {
    pub const non_list_len =
        2 // extension and command opcodes
        + 2 // request length
        + 1 // op
        + 3 // pad
        + 4 // dst
        + 8 // color
    ;
    pub fn getLen(num_rects: u32) u32 {
        return non_list_len + (num_rects * 8);
    }
    pub const Args = struct {
        op: PictureOperation,
        dst: Picture,
        color: Color,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args, rects: []const x11.Rectangle) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.fill_rectangles);
        buf[4] = @intFromEnum(args.op);
        buf[5] = 0;
        buf[6] = 0;
        buf[7] = 0;
        x11.writeIntNative(u32, buf + 8, @intFromEnum(args.dst));
        x11.writeIntNative(u16, buf + 12, args.color.red);
        x11.writeIntNative(u16, buf + 14, args.color.green);
        x11.writeIntNative(u16, buf + 16, args.color.blue);
        x11.writeIntNative(u16, buf + 18, args.color.alpha);

        var offset: usize = non_list_len;
        for (rects) |rect| {
            x11.writeIntNative(i16, buf + offset, rect.x);
            x11.writeIntNative(i16, buf + offset + 2, rect.y);
            x11.writeIntNative(u16, buf + offset + 4, rect.width);
            x11.writeIntNative(u16, buf + offset + 6, rect.height);
            offset += 8;
        }

        const len = offset;
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, @intCast(len >> 2));
    }
};

pub const create_solid_fill = struct {
    pub const len =
        2 // extension and command opcodes
        + 2 // request length
        + 4 // picture
        + 8 // color
    ;
    pub const Args = struct {
        picture: Picture,
        color: Color,
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.create_solid_fill);
        std.debug.assert(len & 0x3 == 0);
        x11.writeIntNative(u16, buf + 2, len >> 2);
        x11.writeIntNative(u32, buf + 4, @intFromEnum(args.picture));
        x11.writeIntNative(u16, buf + 8, args.color.red);
        x11.writeIntNative(u16, buf + 10, args.color.green);
        x11.writeIntNative(u16, buf + 12, args.color.blue);
        x11.writeIntNative(u16, buf + 14, args.color.alpha);
    }
};
