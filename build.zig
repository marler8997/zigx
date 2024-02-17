const builtin = @import("builtin");
const std = @import("std");

const is_zig_0_11 = std.mem.eql(u8, builtin.zig_version_string, "0.11.0");

pub fn build(b: *std.Build) void {
    if (is_zig_0_11) {
        _ = b.addModule("zigx", .{
            .source_file = .{ .path = "x.zig" },
        });
    } else {
        _ = b.addModule("zigx", .{
            .root_source_file = .{ .path = "x.zig" },
        });
    }
}
