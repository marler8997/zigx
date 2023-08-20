const Combined = @import("combined.zig").Combined;
pub const Kana = enum(u8) {
    overline = 126,
    period = 161,
    opening_bracket = 162,
    closing_bracket = 163,
    comma = 164,
    conjunctive = 165,
    letter_wo = 166,
    letter_small_a = 167,
    letter_small_i = 168,
    letter_small_u = 169,
    letter_small_e = 170,
    letter_small_o = 171,
    letter_small_ya = 172,
    letter_small_yu = 173,
    letter_small_yo = 174,
    letter_small_tsu = 175,
    prolonged_sound_symbol = 176,
    letter_a = 177,
    letter_i = 178,
    letter_u = 179,
    letter_e = 180,
    letter_o = 181,
    letter_ka = 182,
    letter_ki = 183,
    letter_ku = 184,
    letter_ke = 185,
    letter_ko = 186,
    letter_sa = 187,
    letter_shi = 188,
    letter_su = 189,
    letter_se = 190,
    letter_so = 191,
    letter_ta = 192,
    letter_chi = 193,
    letter_tsu = 194,
    letter_te = 195,
    letter_to = 196,
    letter_na = 197,
    letter_ni = 198,
    letter_nu = 199,
    letter_ne = 200,
    letter_no = 201,
    letter_ha = 202,
    letter_hi = 203,
    letter_fu = 204,
    letter_he = 205,
    letter_ho = 206,
    letter_ma = 207,
    letter_mi = 208,
    letter_mu = 209,
    letter_me = 210,
    letter_mo = 211,
    letter_ya = 212,
    letter_yu = 213,
    letter_yo = 214,
    letter_ra = 215,
    letter_ri = 216,
    letter_ru = 217,
    letter_re = 218,
    letter_ro = 219,
    letter_wa = 220,
    letter_n = 221,
    voiced_sound_symbol = 222,
    semivoiced_sound_symbol = 223,

    pub fn toCombined(self: Kana) Combined {
        return @enumFromInt((@as(u16, 4) << 8) | @intFromEnum(self));
    }
    pub fn next(self: Kana) Kana {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};
