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

    // In almost all cases, Zig programs should only use this module, not the
    // library defined below, that's for C programs.
    const x_mod = b.addModule("x", .{
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
                .{ .name = "x", .module = x_mod },
            },
        });

        const exe = b.addExecutable(.{
            .name = name,
            .root_module = example_mod,
        });

        b.installArtifact(exe);
    }

    // This library is for C programs, not Zig programs
    const x11_lib = b.addLibrary(.{
        .name = "x11",
        .root_module = b.createModule(.{
            .root_source_file = b.path("c/x11.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    x11_lib.root_module.addImport("x", x_mod);
    x11_lib.addIncludePath(b.path("c/include"));
    x11_lib.installHeadersDirectory(
        b.path("c/include/X11"),
        "X11",
        .{},
    );
    x11_lib.linkLibC();
    b.installArtifact(x11_lib);

    {
        const exe = b.addExecutable(.{
            .name = "hellox11",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.addCSourceFiles(.{
            .files = &.{"c/example/hellox11.c"},
        });
        exe.addIncludePath(b.path("include"));
        exe.linkLibC();
        exe.linkLibrary(x11_lib);
        b.installArtifact(exe);
    }
}
