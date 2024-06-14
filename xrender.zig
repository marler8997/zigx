/// https://www.x.org/releases/current/doc/renderproto/renderproto.txt
const std = @import("std");

const x = @import("x.zig");

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
        x.writeIntNative(u16, buf + 2, len >> 2);
        x.writeIntNative(u32, buf + 4, args.major_version);
        x.writeIntNative(u32, buf + 8, args.minor_version);
    }
    pub const Reply = extern struct {
        response_type: x.ReplyKind,
        unused_pad: u8,
        sequence: u16,
        word_len: u32,
        major_version: u32,
        minor_version: u32,
        reserved: [15]u8,
    };
    comptime { std.debug.assert(@sizeOf(Reply) == 32); }
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
    picture_format_id: u32,
    type: PictureType,
    depth: u8,
    _: [2]u8,
    direct: DirectFormat,
    colormap: u32,
};
comptime { if (@sizeOf(PictureFormatInfo) != 28) @compileError("PictureFormatInfo size is wrong"); }

pub const query_pict_formats = struct {
    pub const len =
              2 // extension and command opcodes
            + 2 // request length
    ;
    pub fn serialize(buf: [*]u8, ext_opcode: u8) void {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.query_pict_formats);
        x.writeIntNative(u16, buf + 2, len >> 2);
    }

    pub const Reply = extern struct {
        response_type: x.ReplyKind,
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
    comptime { std.debug.assert(@sizeOf(Reply) == 32); }
};

pub const create_picture = struct {
    pub const Repeat = enum(u32) {
        none,
        normal,
        pad,
        reflect,
    };

    pub const PolyEdge = enum(u32) {
        sharp,
        smooth
    };

    pub const PolyMode = enum(u32) {
        precise,
        imprecise
    };

    pub const create_picture_option_count = 13;
    pub const create_picture_option_flag = struct {
        pub const repeat            : u32 = (1 <<  0);
        pub const alpha_map         : u32 = (1 <<  1);
        pub const alpha_x_origin    : u32 = (1 <<  2);
        pub const alpha_y_origin    : u32 = (1 <<  3);
        pub const clip_x_origin     : u32 = (1 <<  4);
        pub const clip_y_origin     : u32 = (1 <<  5);
        pub const clip_mask         : u32 = (1 <<  6);
        pub const graphics_exposures: u32 = (1 <<  7);
        pub const subwindow_mode    : u32 = (1 <<  8);
        pub const poly_edge         : u32 = (1 <<  9);
        pub const poly_mode         : u32 = (1 <<  10);
        pub const dither            : u32 = (1 <<  11);
        pub const component_alpha   : u32 = (1 <<  12);
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
        subwindow_mode: x.SubWindowMode = .clip_by_children,
        poly_edge: PolyEdge = .sharp,
        poly_mode: PolyMode = .precise,
        dither: x.Atom = @enumFromInt(0), // optional
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
        picture_id: u32,
        drawable_id: u32,
        format_id: u32,
        options: CreatePictureOptions
    };
    pub fn serialize(buf: [*]u8, ext_opcode: u8, args: Args) u16 {
        buf[0] = ext_opcode;
        buf[1] = @intFromEnum(ExtOpcode.create_picture);
        // buf[2-3] is the len, set at the end of the function
        x.writeIntNative(u32, buf + 4, args.picture_id);
        x.writeIntNative(u32, buf + 8, args.drawable_id);
        x.writeIntNative(u32, buf + 12, args.format_id);

        var option_mask: u32 = 0;
        var request_len: u16 = non_option_len;

        inline for (std.meta.fields(CreatePictureOptions)) |field| {
            if (!x.isDefaultValue(args.options, field)) {
                x.writeIntNative(u32, buf + request_len, x.optionToU32(@field(args.options, field.name)));
                option_mask |= @field(create_picture_option_flag, field.name);
                request_len += 4;
            }
        }
        x.writeIntNative(u32, buf + non_option_len - 4, option_mask);
        x.writeIntNative(u16, buf + 2, request_len >> 2);
        return request_len;
    }
};

/// Combine the src and destination pictures with the specified operation.
/// 
/// For example, if you want to copy the src picture to the destination picture, you
/// would use `PictureOperation.over`.
pub const composite = struct {
    pub const len =
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
    pub const Args = struct {
        picture_operation: PictureOperation,
        src_picture_id: u32,
        mask_picture_id: u32,
        dst_picture_id: u32,
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
        x.writeIntNative(u16, buf + 2, len >> 2);
        buf[4] = @intFromEnum(args.picture_operation);
        // 3 bytes of padding
        x.writeIntNative(u32, buf + 8, args.src_picture_id);
        x.writeIntNative(u32, buf + 12, args.mask_picture_id);
        x.writeIntNative(u32, buf + 16, args.dst_picture_id);
        x.writeIntNative(i16, buf + 20, args.src_x);
        x.writeIntNative(i16, buf + 22, args.src_y);
        x.writeIntNative(i16, buf + 24, args.mask_x);
        x.writeIntNative(i16, buf + 26, args.mask_y);
        x.writeIntNative(i16, buf + 28, args.dst_x);
        x.writeIntNative(i16, buf + 30, args.dst_y);
        x.writeIntNative(u16, buf + 32, args.width);
        x.writeIntNative(u16, buf + 34, args.height);
    }
};
