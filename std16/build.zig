pub fn build(b: *std.Build) void {
    _ = b.addModule("std16", .{
        .root_source_file = b.path("src/std.zig"),
    });
}

const std = @import("std");
