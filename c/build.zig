const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const x_mod = b.createModule(.{
        .root_source_file = b.path("../x.zig"),
    });

    const x11_lib = b.addStaticLibrary(.{
        .name = "x11",
        .root_source_file = b.path("x11.zig"),
        .target = target,
        .optimize = optimize,
    });
    x11_lib.addIncludePath(b.path("include"));
    x11_lib.root_module.addImport("x", x_mod);
    // I *think* we'll want to link libc here because it's probably guaranteed that
    // the application will be linking libc and not linking libc means we could have
    // discrepancies, for example, zig's start code that initializes the environment
    // variables wouldn't have run
    x11_lib.linkLibC();
    b.installArtifact(x11_lib);

    {
        const exe = b.addExecutable(.{
            .name = "hellox11",
            .target = target,
            .optimize = optimize,
        });
        exe.addCSourceFiles(.{
            .files = &.{"example/hellox11.c"},
        });
        exe.addIncludePath(b.path("include"));
        exe.linkLibC();
        exe.linkLibrary(x11_lib);
        b.installArtifact(exe);
    }
}
