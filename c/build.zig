const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const x11_lib = b.addStaticLibrary("x11", "x11.zig");
    x11_lib.setTarget(target);
    x11_lib.setBuildMode(mode);
    x11_lib.addIncludePath(b.pathJoin(&.{ b.build_root, "include" }));
    x11_lib.addPackagePath("x", b.pathJoin(&.{ b.build_root, "../x.zig" }));
    // I *think* we'll want to link libc here because it's probably guaranteed that
    // the application will be linking libc and not linking libc means we could have
    // discrepancies, for example, zig's start code that initializes the environment
    // variables wouldn't have run
    x11_lib.linkLibC();
    x11_lib.install();

    {
        const exe = b.addExecutable("hellox11", "example/hellox11.c");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.addIncludePath(b.pathJoin(&.{ b.build_root, "include" }));
        exe.linkLibC();
        exe.linkLibrary(x11_lib);
        exe.install();
    }
}
