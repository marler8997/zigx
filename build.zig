const builtin = @import("builtin");
const std = @import("std");

const examples = [_][]const u8{
    "getserverfontnames",
    "testexample",
    "graphics",
    "queryfont",
    "example",
    "fontviewer",
    "keys",
    "input",
    "dbe",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // In almost all cases, Zig programs should only use this module, not the
    // library defined below, that's for C programs.
    const x_mod = b.addModule("x11", .{
        .root_source_file = b.path("src/x.zig"),
    });

    const examples_step = b.step("examples", "");

    inline for (examples) |example_name| {
        // const basename = std.fs.path.basename(example_file);
        // const name = basename[0 .. basename.len - std.fs.path.extension(basename).len];
        const example_mod = b.createModule(.{
            .root_source_file = b.path("examples/" ++ example_name ++ ".zig"),
            .optimize = optimize,
            .target = target,
            .imports = &.{
                .{ .name = "x11", .module = x_mod },
            },
        });

        const exe = b.addExecutable(.{
            .name = example_name,
            .root_module = example_mod,
        });

        const install = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        if (b.args) |args| {
            run.addArgs(args);
        }
        b.step(example_name, "").dependOn(&run.step);
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
    x11_lib.root_module.addImport("x11", x_mod);
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

        const install = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        if (b.args) |args| {
            run.addArgs(args);
        }
        b.step("hellox11", "").dependOn(&run.step);
    }

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/x.zig"),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // This exposes a `test` step to the `zig build --help` menu, providing a way for
    // the user to request running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
