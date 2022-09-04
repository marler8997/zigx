const Combined = @import("combined.zig").Combined;
pub const Latin4 = enum(u8) {
    small_greenlandic_letter_kra = 162,
    R_with_cedilla = 163,
    I_with_tilde = 165,
    L_with_cedilla = 166,
    E_with_macron = 170,
    G_with_cedilla = 171,
    T_with_oblique_stroke = 172,
    r_with_cedilla = 179,
    i_with_tilde = 181,
    l_with_cedilla = 182,
    e_with_macron = 186,
    g_with_cedilla_above = 187,
    t_with_oblique_stroke = 188,
    lappish_Eng = 189,
    lappish_eng = 191,
    A_with_macron = 192,
    I_with_ogonek = 199,
    E_with_dot_above = 204,
    I_with_macron = 207,
    N_with_cedilla = 209,
    O_with_macron = 210,
    K_with_cedilla = 211,
    U_with_ogonek = 217,
    U_with_tilde = 221,
    U_with_macron = 222,
    a_with_macron = 224,
    i_with_ogonek = 231,
    e_with_dot_above = 236,
    i_with_macron = 239,
    n_with_cedilla = 241,
    o_with_macron = 242,
    k_with_cedilla = 243,
    u_with_ogonek = 249,
    u_with_tilde = 253,
    u_with_macron = 254,

    pub fn toCombined(self: Latin4) Combined {
        return @intToEnum(Combined, (@as(u16, 3) << 8) | @enumToInt(self));
    }
    pub fn next(self: Latin4) Latin4 {
        return @intToEnum(Latin4, @enumToInt(self) + 1);
    }
};
