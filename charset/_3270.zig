const Combined = @import("combined.zig").Combined;
pub const _3270 = enum(u8) {
    _3270_duplicate = 1,
    _3270_fieldmark = 2,
    _3270_right2 = 3,
    _3270_left2 = 4,
    _3270_backtab = 5,
    _3270_eraseeof = 6,
    _3270_eraseinput = 7,
    _3270_reset = 8,
    _3270_quit = 9,
    _3270_pa1 = 10,
    _3270_pa2 = 11,
    _3270_pa3 = 12,
    _3270_test = 13,
    _3270_attn = 14,
    _3270_cursorblink = 15,
    _3270_altcursor = 16,
    _3270_keyclick = 17,
    _3270_jump = 18,
    _3270_ident = 19,
    _3270_rule = 20,
    _3270_copy = 21,
    _3270_play = 22,
    _3270_setup = 23,
    _3270_record = 24,
    _3270_changescreen = 25,
    _3270_deleteword = 26,
    _3270_exselect = 27,
    _3270_cursorselect = 28,
    _3270_printscreen = 29,
    _3270_enter = 30,

    pub fn toCombined(self: _3270) Combined {
        return @intToEnum(Combined, (@as(u16, 253) << 8) | @enumToInt(self));
    }
    pub fn next(self: _3270) _3270 {
        return @intToEnum(_3270, @enumToInt(self) + 1);
    }
};
