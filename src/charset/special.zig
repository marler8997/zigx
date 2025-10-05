const Combined = @import("combined.zig").Combined;
pub const Special = enum(u8) {
    blank = 223,
    solid_diamond = 224,
    checkerboard = 225,
    ht = 226,
    ff = 227,
    cr = 228,
    lf = 229,
    nl = 232,
    vt = 233,
    lower_right_corner = 234,
    upper_right_corner = 235,
    upper_left_corner = 236,
    lower_left_corner = 237,
    crossing_lines = 238,
    horizontal_line_scan_1 = 239,
    horizontal_line_scan_3 = 240,
    horizontal_line_scan_5 = 241,
    horizontal_line_scan_7 = 242,
    horizontal_line_scan_9 = 243,
    left_t = 244,
    right_t = 245,
    bottom_t = 246,
    top_t = 247,
    vertical_bar = 248,

    pub fn toCombined(self: Special) Combined {
        return @enumFromInt((@as(u16, 9) << 8) | @intFromEnum(self));
    }
    pub fn next(self: Special) Special {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};
