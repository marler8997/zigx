const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("zigx", .{
        .root_source_file = b.path("x.zig"),
    });
}
