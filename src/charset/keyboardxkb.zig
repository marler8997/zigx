const Combined = @import("combined.zig").Combined;
pub const Keyboardxkb = enum(u8) {
    pub fn toCombined(self: Keyboardxkb) Combined {
        return @fromBackingInt(@intCast((@as(u16, 254) << 8) | @backingInt(self)));
    }
    pub fn next(self: Keyboardxkb) Keyboardxkb {
        return @fromBackingInt(@intCast(@backingInt(self) + 1));
    }
};
