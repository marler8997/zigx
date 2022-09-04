const Combined = @import("combined.zig").Combined;
pub const Latin3 = enum(u8) {
    H_with_stroke = 161,
    H_with_circumflex_accent = 166,
    I_with_dot_above = 169,
    G_with_breve = 171,
    J_with_circumflex_accent = 172,
    h_with_stroke = 177,
    h_with_circumflex_accent = 182,
    small_dotless_letter_i = 185,
    g_with_breve = 187,
    j_with_circumflex_accent = 188,
    C_with_dot_above = 197,
    C_with_circumflex_accent = 198,
    G_with_dot_above = 213,
    G_with_circumflex_accent = 216,
    U_with_breve = 221,
    S_with_circumflex_accent = 222,
    c_with_dot_above = 229,
    c_with_circumflex_accent = 230,
    g_with_dot_above = 245,
    g_with_circumflex_accent = 248,
    u_with_breve = 253,
    s_with_circumflex_accent = 254,

    pub fn toCombined(self: Latin3) Combined {
        return @intToEnum(Combined, (@as(u16, 2) << 8) | @enumToInt(self));
    }
    pub fn next(self: Latin3) Latin3 {
        return @intToEnum(Latin3, @enumToInt(self) + 1);
    }
};
