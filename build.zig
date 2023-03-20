const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("zigx", .{
        .source_file = .{ .path = "x.zig" },
    });
}
