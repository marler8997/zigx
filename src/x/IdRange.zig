/// Represents the range of valid X resource IDs (XIDs) for a client connection.
///
/// An X11 server assigns each client a resource-id-base and resource-id-mask in the
/// connection setup reply. The mask defines which bits the client may vary to create
/// unique IDs; the base provides the remaining bits that identify the client. Per the
/// X11 spec, the mask is always a contiguous run of at least 18 bits, and resource IDs
/// never have the top three bits set.
///
/// This type compresses the base, shift, and bit count into a 4-byte tagged union,
/// and provides methods to map sequential offsets to valid XIDs.
const IdRange = @This();

// Ensure our crazy tagged union actually fits within 32-bits, it shouldn't take more
// bits that that to represent the X11 base/mask semantics.
comptime {
    std.debug.assert(@sizeOf(IdRange) <= 4);
}

fn Payload(comptime bit_count: comptime_int) type {
    const remaining_bits = 29 - bit_count;
    const shift_bits = std.math.log2_int_ceil(u32, remaining_bits + 1);
    return packed struct {
        shift: std.meta.Int(.unsigned, shift_bits),
        base: std.meta.Int(.unsigned, remaining_bits),
    };
}

const Payloads = union(enum(u4)) {
    @"18": Payload(18),
    @"19": Payload(19),
    @"20": Payload(20),
    @"21": Payload(21),
    @"22": Payload(22),
    @"23": Payload(23),
    @"24": Payload(24),
    @"25": Payload(25),
    @"26": Payload(26),
    @"27": Payload(27),
    @"28": Payload(28),
};

payloads: Payloads,

const is_test = @import("builtin").is_test;

pub fn init(base: x11.ResourceBase, mask: x11.ResourceMask) error{Protocol}!IdRange {
    const mask_u32: u32 = @intFromEnum(mask);
    if (mask_u32 == 0) {
        if (!is_test) std.log.err("X11 server provided zero resource id mask", .{});
        return error.Protocol;
    }
    // u5 can represent all possible values since mask_u32 is not 0 so it cannot have more than 31 0's
    const shift: u5 = @intCast(@ctz(mask_u32));

    {
        // Mask must have contiguous bits: shifting out trailing zeros must yield a solid run of 1s.
        const shifted = mask_u32 >> shift;
        if (shifted & (shifted + 1) != 0) {
            if (!is_test) std.log.err("X11 server provided non-contiguous resource id mask: 0x{x}", .{mask_u32});
            return error.Protocol;
        }
    }

    const bit_count: u6 = @popCount(mask_u32);
    // Per the X11 spec, the mask must contain at least 18 contiguous bits.
    if (bit_count < 18) {
        if (!is_test) std.log.err("X11 server provided resource id mask with only {} bits (need at least 18): 0x{x}", .{ bit_count, mask_u32 });
        return error.Protocol;
    }
    const base_u32: u32 = @intFromEnum(base);
    // Resource IDs never have the top three bits set.
    if ((base_u32 | mask_u32) & 0xE0000000 != 0) {
        if (!is_test) std.log.err("X11 server provided resource ids with top 3 bits set (base=0x{x}, mask=0x{x})", .{ base_u32, mask_u32 });
        return error.Protocol;
    }
    // Base can't be 0 since 0 is a placeholder for null
    if (base_u32 == 0) {
        if (!is_test) std.log.err("X11 server provided zero resource id base", .{});
        return error.Protocol;
    }
    // Base must not overlap with mask bits.
    if (base_u32 & mask_u32 != 0) {
        if (!is_test) std.log.err("X11 server provided resource id base 0x{x} that overlaps with mask 0x{x}", .{ base_u32, mask_u32 });
        return error.Protocol;
    }
    // Compress base: pack the non-mask bits together.
    const bit_count_u5: u5 = @intCast(bit_count);
    const low = base_u32 & ((@as(u32, 1) << shift) - 1);
    const high = base_u32 >> (shift + bit_count_u5);
    const compressed = low | (high << shift);
    return .{ .payloads = switch (bit_count) {
        inline 18...28 => |bc| @unionInit(Payloads, std.fmt.comptimePrint("{}", .{bc}), .{
            .shift = @intCast(shift),
            .base = @intCast(compressed),
        }),
        else => unreachable,
    } };
}

pub fn capacity(r: IdRange) u29 {
    return r.generic().capacity();
}

pub fn add(r: IdRange, off: u29) ?x11.Resource {
    return r.generic().add(off);
}

pub fn addAssumeCapacity(r: IdRange, off: u29) x11.Resource {
    return r.generic().addAssumeCapacity(off);
}

/// Reverse of `add`: given a resource ID, return the offset that produced it.
/// Returns null if the resource doesn't belong to this range (wrong base bits
/// or offset out of capacity).
pub fn offset(r: IdRange, resource: x11.Resource) ?u29 {
    return r.generic().offset(resource);
}

// The "Generic" version of an ID range, defined to minimize code duplication.
pub const Generic = struct {
    base: u29,
    shift: u5,
    bit_count: u5,

    pub fn capacity(g: Generic) u29 {
        return @as(u29, 1) << g.bit_count;
    }

    pub fn add(g: Generic, off: u29) ?x11.Resource {
        if (off >= g.capacity()) return null;
        return @enumFromInt(@as(u32, g.base | (off << g.shift)));
    }

    pub fn addAssumeCapacity(g: Generic, off: u29) x11.Resource {
        return g.add(off) orelse unreachable;
    }

    /// Reverse of `add`: given a resource ID, return the offset that produced it.
    /// Returns null if the resource doesn't belong to this range (wrong base bits
    /// or offset out of capacity).
    pub fn offset(g: Generic, resource: x11.Resource) ?u29 {
        const id: u32 = @intFromEnum(resource);
        const mask: u32 = ((@as(u32, 1) << g.bit_count) - 1) << g.shift;
        if (id & ~mask != g.base) return null;
        const result: u29 = @intCast((id & mask) >> g.shift);
        if (result >= g.capacity()) return null;
        return result;
    }

    pub fn format(g: Generic, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.print("IdRange(base=0x{x}, shift={}, bit_count={})", .{ g.base, g.shift, g.bit_count });
    }
};

pub fn generic(r: IdRange) Generic {
    switch (r.payloads) {
        inline else => |payload, tag| {
            const bit_count: u5 = @as(u5, @intFromEnum(tag)) + 18;
            const shift: u5 = @intCast(payload.shift);
            // Decompress base: unpack the non-mask bits back to their original positions.
            const compressed: u29 = @intCast(payload.base);
            const low = compressed & ((@as(u29, 1) << shift) - 1);
            const high_shift = shift + bit_count;
            const base: u29 = if (high_shift >= 29) low else low | ((compressed >> shift) << high_shift);
            return .{ .base = base, .shift = shift, .bit_count = bit_count };
        },
    }
}

pub fn format(v: IdRange, writer: *std.Io.Writer) error{WriteFailed}!void {
    return v.generic().format(writer);
}

/// Test helper: verifies that add(add_offset) produces expected_id, and that
/// offset() roundtrips back to add_offset.
fn expectAdd(r: IdRange, expected_id: u32, add_offset: u29) !void {
    const resource = r.add(add_offset) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected_id, @intFromEnum(resource));
    try std.testing.expectEqual(@as(?u29, add_offset), r.offset(resource));
}

test "mask in low bits" {
    // 21-bit mask in low bits, base in upper bits
    const r = try IdRange.init(.fromInt(0x04000000), .fromInt(0x001FFFFF));
    try std.testing.expectEqual(@as(u29, 0x200000), r.capacity());
    try expectAdd(r, 0x04000000, 0);
    try expectAdd(r, 0x04000001, 1);
    try expectAdd(r, 0x04000002, 2);
    try expectAdd(r, 0x041FFFFF, 0x1FFFFF);
    try std.testing.expectEqual(@as(?x11.Resource, null), r.add(0x200000));
    // wrong base returns null
    try std.testing.expectEqual(@as(?u29, null), r.offset(@enumFromInt(0x08000000)));
}

test "mask in high bits" {
    // 18-bit mask starting at bit 11: bits 11-28, base in low bits
    const r = try IdRange.init(.fromInt(0x00000003), .fromInt(0x1FFFF800));
    try std.testing.expectEqual(@as(u29, 0x40000), r.capacity());
    try expectAdd(r, 0x00000003, 0);
    try expectAdd(r, 0x00000803, 1);
    try expectAdd(r, 0x00001003, 2);
    try expectAdd(r, 0x1FFFF803, 0x3FFFF);
    try std.testing.expectEqual(@as(?x11.Resource, null), r.add(0x40000));
    try std.testing.expectEqual(@as(?u29, null), r.offset(@enumFromInt(0x00000007)));
}

test "mask in middle bits" {
    // 18-bit mask in middle bits, base in outer bits
    const r = try IdRange.init(.fromInt(0x10000003), .fromInt(0x00FFFFC0));
    try std.testing.expectEqual(@as(u29, 0x40000), r.capacity());
    try expectAdd(r, 0x10000003, 0);
    try expectAdd(r, 0x10000043, 1);
    try expectAdd(r, 0x10FFFFC3, 0x3FFFF);
    try std.testing.expectEqual(@as(?x11.Resource, null), r.add(0x40000));
    try std.testing.expectEqual(@as(?u29, null), r.offset(@enumFromInt(0x10000000)));
}

test "zero base" {
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0), .fromInt(0x001FFFFF)));
}

test "zero mask" {
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0x04000000), .fromInt(0)));
}

test "mask too small" {
    // 17 bits is not enough
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0x04000000), .fromInt(0x0001FFFF)));
    // 1 bit
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0x04000000), .fromInt(0x00000001)));
}

test "non-contiguous mask" {
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0x04000000), .fromInt(0x00FF00FF)));
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0x04000000), .fromInt(0x01010101)));
}

test "base overlaps mask" {
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0x04000001), .fromInt(0x001FFFFF)));
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0xFFFFFFFF), .fromInt(0x001FFFFF)));
}

test "top 3 bits set" {
    // bit 29 set in base
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0x20000000), .fromInt(0x001FFFFF)));
    // bit 30 set in base
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0x40000000), .fromInt(0x001FFFFF)));
    // bit 31 set in base
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0x80000000), .fromInt(0x001FFFFF)));
    // top bits set in mask
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0x00000001), .fromInt(0xFFFFFFFE)));
    // top bits set in both
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0xE0000000), .fromInt(0x1FFFC000)));
}

test "all bit counts with shift 0" {
    // Test every tag variant (18-28) with mask in lowest bits.
    inline for (18..29) |bit_count| {
        const mask: u32 = (@as(u32, 1) << bit_count) - 1;
        // Base must be non-zero and outside mask bits.
        const base: u32 = @as(u32, 1) << bit_count;
        const r = try IdRange.init(.fromInt(base), .fromInt(mask));
        const g = r.generic();
        try std.testing.expectEqual(base, g.base);
        try std.testing.expectEqual(@as(u5, 0), g.shift);
        try std.testing.expectEqual(@as(u5, bit_count), g.bit_count);
        try expectAdd(r, base, 0);
        try expectAdd(r, base | 1, 1);
        const max_offset: u29 = (@as(u29, 1) << bit_count) - 1;
        try expectAdd(r, base | mask, max_offset);
        try std.testing.expectEqual(@as(?x11.Resource, null), r.add(@as(u29, 1) << bit_count));
    }
}

test "all bit counts with max shift" {
    // Test every tag variant with mask shifted as high as possible within 29 bits.
    inline for (18..29) |bit_count| {
        const max_shift = 29 - bit_count;
        const mask: u32 = ((@as(u32, 1) << bit_count) - 1) << max_shift;
        // Base in the low bits below the mask.
        const base: u32 = if (max_shift > 0) (@as(u32, 1) << max_shift) - 1 else 0;
        if (base == 0) continue; // skip if no room for a non-zero base
        const r = try IdRange.init(.fromInt(base), .fromInt(mask));
        const g = r.generic();
        try std.testing.expectEqual(base, g.base);
        try std.testing.expectEqual(@as(u5, max_shift), g.shift);
        try std.testing.expectEqual(@as(u5, bit_count), g.bit_count);
        try expectAdd(r, base, 0);
        try expectAdd(r, base | (@as(u32, 1) << max_shift), 1);
        try std.testing.expectEqual(@as(?x11.Resource, null), r.add(@as(u29, 1) << bit_count));
    }
}

test "split base roundtrip" {
    // Base bits both above and below the mask — exercises compress/decompress with split base.
    // mask = bits 4-21 (18 bits), base = bits 0-3 and 22-28
    const base: u32 = 0x1FC0000F; // bits 22-28 and 0-3 all set
    const mask: u32 = 0x003FFFF0; // bits 4-21
    const r = try IdRange.init(.fromInt(base), .fromInt(mask));
    const g = r.generic();
    try std.testing.expectEqual(base, g.base);
    try std.testing.expectEqual(@as(u5, 4), g.shift);
    try std.testing.expectEqual(@as(u5, 18), g.bit_count);
    try expectAdd(r, base, 0);
    try expectAdd(r, base | 0x10, 1);
    try expectAdd(r, base | mask, 0x3FFFF);
    try std.testing.expectEqual(@as(?x11.Resource, null), r.add(0x40000));
}

test "maximum capacity" {
    // 28-bit mask (maximum possible), base is a single bit at position 28
    const r = try IdRange.init(.fromInt(0x10000000), .fromInt(0x0FFFFFFF));
    try std.testing.expectEqual(@as(u29, 1 << 28), r.capacity());
    try expectAdd(r, 0x10000000, 0);
    try expectAdd(r, 0x1FFFFFFF, 0x0FFFFFFF);
    try std.testing.expectEqual(@as(?x11.Resource, null), r.add(0x10000000));
    // 29-bit mask would require base=0, which is invalid
    try std.testing.expectError(error.Protocol, IdRange.init(.fromInt(0), .fromInt(0x1FFFFFFF)));
}

test "offset rejects Resource.none" {
    const r = try IdRange.init(.fromInt(0x04000000), .fromInt(0x001FFFFF));
    try std.testing.expectEqual(@as(?u29, null), r.offset(.none));
}

test "offset rejects resources from a different range" {
    const r1 = try IdRange.init(.fromInt(0x04000000), .fromInt(0x001FFFFF));
    const r2 = try IdRange.init(.fromInt(0x08000000), .fromInt(0x001FFFFF));
    // r2's resources should not be accepted by r1
    try std.testing.expectEqual(@as(?u29, null), r1.offset(r2.add(0).?));
    try std.testing.expectEqual(@as(?u29, null), r1.offset(r2.add(1).?));
    try std.testing.expectEqual(@as(?u29, null), r1.offset(r2.add(42).?));
    // and vice versa
    try std.testing.expectEqual(@as(?u29, null), r2.offset(r1.add(0).?));
}

test "offset rejects resources with top 3 bits set" {
    const r = try IdRange.init(.fromInt(0x04000000), .fromInt(0x001FFFFF));
    // These can't come from any valid range but could appear as garbage
    try std.testing.expectEqual(@as(?u29, null), r.offset(@enumFromInt(0x84000000)));
    try std.testing.expectEqual(@as(?u29, null), r.offset(@enumFromInt(0xFFFFFFFF)));
}

test "offset with split base rejects partial base match" {
    // base has bits both above and below the mask
    const r = try IdRange.init(.fromInt(0x10000003), .fromInt(0x00FFFFC0));
    // correct low base bits but wrong high base bits
    try std.testing.expectEqual(@as(?u29, null), r.offset(@enumFromInt(0x00000003)));
    // correct high base bits but wrong low base bits
    try std.testing.expectEqual(@as(?u29, null), r.offset(@enumFromInt(0x10000000)));
    // all base bits flipped
    try std.testing.expectEqual(@as(?u29, null), r.offset(@enumFromInt(0x00FFFFC0)));
}

test "offset handles every u32 without panicking" {
    // Maximum capacity range: 28-bit mask, base at bit 28
    const r = try IdRange.init(.fromInt(0x10000000), .fromInt(0x0FFFFFFF));
    // Brute-force all resource IDs that pass the base check — they should all
    // roundtrip. Also throw every hostile u32 we can think of at it.
    const hostile = [_]u32{
        0x00000000, // none
        0x00000001, // wrong base
        0x0FFFFFFF, // mask bits only, no base
        0x10000000, // base only, offset 0 — valid
        0x1FFFFFFF, // base + all mask bits — valid (max offset)
        0x20000000, // bit 29 set
        0x40000000, // bit 30 set
        0x80000000, // bit 31 set
        0xFFFFFFFF, // all bits set
        0xF0000000, // top nibble + base
        0x10000000 | 0xE0000000, // base + top 3 bits
    };
    for (hostile) |id| {
        const resource: x11.Resource = @enumFromInt(id);
        if (r.offset(resource)) |off| {
            // If offset returned a value, add must roundtrip back
            try std.testing.expectEqual(resource, r.add(off).?);
        }
    }
}

const std = @import("std");
const x11 = @import("../x.zig");
