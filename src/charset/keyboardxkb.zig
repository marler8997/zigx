const Combined = @import("combined.zig").Combined;
pub const Keyboardxkb = enum(u8) {

    pub fn toCombined(self: Keyboardxkb) Combined {
        return @enumFromInt((@as(u16, 254) << 8) | @intFromEnum(self));
    }
    pub fn next(self: Keyboardxkb) Keyboardxkb {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};
