const Combined = @import("combined.zig").Combined;
pub const Keyboard_xkb = enum(u8) {

    pub fn toCombined(self: Keyboard_xkb) Combined {
        return @enumFromInt((@as(u16, 254) << 8) | @intFromEnum(self));
    }
    pub fn next(self: Keyboard_xkb) Keyboard_xkb {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};
