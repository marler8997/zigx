const Combined = @import("combined.zig").Combined;
pub const Apl = enum(u8) {
    left_caret = 163,
    right_caret = 166,
    down_caret = 168,
    up_caret = 169,
    overbar = 192,
    down_tack = 194,
    up_shoe_cap = 195,
    down_stile = 196,
    underbar = 198,
    jot = 202,
    quad = 204,
    up_tack = 206,
    circle = 207,
    up_stile = 211,
    down_shoe_cup = 214,
    right_shoe = 216,
    left_shoe = 218,
    left_tack = 220,
    right_tack = 252,

    pub fn toCombined(self: Apl) Combined {
        return @enumFromInt((@as(u16, 11) << 8) | @intFromEnum(self));
    }
    pub fn next(self: Apl) Apl {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};
