const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const x_mod = b.createModule(.{
        .source_file = .{ .path = b.pathJoin(&.{ b.build_root.path.?, "../x.zig" }) },
    });

    const x11_lib = b.addStaticLibrary(.{
        .name = "x11",
        .root_source_file = .{ .path = "x11.zig" },
        .target = target,
        .optimize = optimize,
    });
    x11_lib.addIncludePath(.{ .path = b.pathJoin(&.{ b.build_root.path.?, "include" }) });
    x11_lib.addModule("x", x_mod);
    // I *think* we'll want to link libc here because it's probably guaranteed that
    // the application will be linking libc and not linking libc means we could have
    // discrepancies, for example, zig's start code that initializes the environment
    // variables wouldn't have run
    x11_lib.linkLibC();
    b.installArtifact(x11_lib);

    {
        const exe = b.addExecutable(.{
            .name = "hellox11",
            .root_source_file = .{ .path = "example/hellox11.c" },
            .target = target,
            .optimize = optimize,
        });
        exe.addIncludePath(.{ .path = b.pathJoin(&.{ b.build_root.path.?, "include" })});
        exe.linkLibC();
        exe.linkLibrary(x11_lib);
        b.installArtifact(exe);
    }
}
