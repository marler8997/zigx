const Combined = @import("combined.zig").Combined;
pub const Hebrew = enum(u8) {
    double_low_line = 223,
    hebrew_letter_aleph = 224,
    hebrew_letter_bet = 225,
    hebrew_letter_gimel = 226,
    hebrew_letter_dalet = 227,
    hebrew_letter_he = 228,
    hebrew_letter_waw = 229,
    hebrew_letter_zain = 230,
    hebrew_letter_chet = 231,
    hebrew_letter_tet = 232,
    hebrew_letter_yod = 233,
    hebrew_letter_final_kaph = 234,
    hebrew_letter_kaph = 235,
    hebrew_letter_lamed = 236,
    hebrew_letter_final_mem = 237,
    hebrew_letter_mem = 238,
    hebrew_letter_final_nun = 239,
    hebrew_letter_nun = 240,
    hebrew_letter_samech = 241,
    hebrew_letter_ayin = 242,
    hebrew_letter_final_pe = 243,
    hebrew_letter_pe = 244,
    hebrew_letter_final_zade = 245,
    hebrew_letter_zade = 246,
    hebrew_qoph = 247,
    hebrew_resh = 248,
    hebrew_shin = 249,
    hebrew_taw = 250,

    pub fn toCombined(self: Hebrew) Combined {
        return @enumFromInt((@as(u16, 12) << 8) | @intFromEnum(self));
    }
    pub fn next(self: Hebrew) Hebrew {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};
