const GlyphIndexSet = @This();
comptime {
    std.debug.assert(@sizeOf(GlyphIndexSet) == 8192);
}

bit_set: std.StaticBitSet(std.math.maxInt(GlyphIndexInt) + 1),

pub fn initEmpty() GlyphIndexSet {
    return .{ .bit_set = .initEmpty() };
}
pub fn isSet(self: *const GlyphIndexSet, glyph_index: TrueType.GlyphIndex) bool {
    return self.bit_set.isSet(@intFromEnum(glyph_index));
}
pub fn set(self: *GlyphIndexSet, glyph_index: TrueType.GlyphIndex) void {
    self.bit_set.set(@intFromEnum(glyph_index));
}
pub fn clear(self: *GlyphIndexSet) void {
    @memset(&self.bit_set.masks, 0);
}

const std = @import("std");
const TrueType = @import("TrueType");
const GlyphIndexInt = @typeInfo(TrueType.GlyphIndex).@"enum".tag_type;
