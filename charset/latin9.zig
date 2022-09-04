const Combined = @import("combined.zig").Combined;
pub const Latin9 = enum(u8) {
    capital_diphthong_oe = 188,
    small_diphthong_oe = 189,
    Y_with_diaeresis = 190,

    pub fn toCombined(self: Latin9) Combined {
        return @intToEnum(Combined, (@as(u16, 19) << 8) | @enumToInt(self));
    }
    pub fn next(self: Latin9) Latin9 {
        return @intToEnum(Latin9, @enumToInt(self) + 1);
    }
};
