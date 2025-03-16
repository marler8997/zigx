const builtin = @import("builtin");
const std = @import("std");

const examples = [_][]const u8{
    "examples/getserverfontnames.zig",
    "examples/testexample.zig",
    "examples/graphics.zig",
    "examples/queryfont.zig",
    "examples/example.zig",
    "examples/fontviewer.zig",
    "examples/input.zig",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigx_mod = b.addModule("x", .{
        .root_source_file = b.path("src/x.zig"),
    });

    for (examples) |example_file| {
        const basename = std.fs.path.basename(example_file);
        const name = basename[0 .. basename.len - std.fs.path.extension(basename).len];

        const example_mod = b.createModule(.{
            .root_source_file = b.path(example_file),
            .optimize = optimize,
            .target = target,
            .imports = &.{
                .{ .name = "x", .module = zigx_mod },
            },
        });

        const exe = b.addExecutable(.{
            .name = name,
            .root_module = example_mod,
        });

        b.installArtifact(exe);
    }
}
