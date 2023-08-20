const Combined = @import("combined.zig").Combined;
pub const Currency = enum(u8) {
    ecu_sign = 160,
    colon_sign = 161,
    cruzeiro_sign = 162,
    french_franc_sign = 163,
    lira_sign = 164,
    mill_sign = 165,
    naira_sign = 166,
    peseta_sign = 167,
    rupee_sign = 168,
    won_sign = 169,
    new_sheqel_sign = 170,
    dong_sign = 171,
    euro_sign = 172,

    pub fn toCombined(self: Currency) Combined {
        return @enumFromInt((@as(u16, 32) << 8) | @intFromEnum(self));
    }
    pub fn next(self: Currency) Currency {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};
