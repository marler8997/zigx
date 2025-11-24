const builtin = @import("builtin");
const std = @import("std");

pub const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

const examples = [_][]const u8{
    // ordered by what's easier to test first
    "getserverfontnames",
    "queryfont",
    "hello",
    "graphics",
    "fontviewer",
    "dbe",
    "keys",
    "input",
    "draw",
    "transparent",
    "testexample",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // In almost all cases, Zig programs should only use this module, not the
    // library defined below, that's for C programs.
    const x_mod = b.addModule("x11", .{
        .root_source_file = b.path("src/x.zig"),
    });
    if (!zig_atleast_15) {
        if (b.lazyDependency("iobackport", .{})) |iobackport_dep| {
            x_mod.addImport("std15", iobackport_dep.module("std15"));
        }
    }

    const examples_exe = b.addExecutable(.{
        .name = "examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/runall.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const run_examples = b.addRunArtifact(examples_exe);

    const test_step = b.step("test", "Run all tests and interactive examples)");
    test_step.dependOn(&run_examples.step);

    const build_examples_step = b.step("build-examples", "");

    inline for (examples) |example_name| {
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
        build_examples_step.dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
        b.step("build-" ++ example_name, "").dependOn(&install.step);

        run_examples.addArtifactArg(exe);
        run_examples.step.dependOn(&install.step);

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
    {
        const install = b.addInstallArtifact(x11_lib, .{});
        b.step("lib", "").dependOn(&install.step);
        // disabled for now as the build is currently broken
        // b.getInstallStep().dependOn(&install.step);
    }

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
        b.step("install-hellox11b", "").dependOn(&install.step);
        // disabled for now as the build is currently broken
        // b.getInstallStep().dependOn(&install.step);

        // run_examples.addArtifactArg(exe);
        // run_examples.step.dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(&install.step);
        if (b.args) |args| {
            run.addArgs(args);
        }
        b.step("hellox11", "").dependOn(&run.step);
    }

    const test_non_interactive = b.step("test-non-interactive", "Run unit tests (excluding interactive examples)");
    test_step.dependOn(test_non_interactive);

    {
        const x_mod_with_target = b.createModule(.{
            .root_source_file = b.path("src/x.zig"),
            .target = target,
        });
        if (!zig_atleast_15) {
            if (b.lazyDependency("iobackport", .{})) |iobackport_dep| {
                x_mod_with_target.addImport("std15", iobackport_dep.module("std15"));
            }
        }
        const unit_tests = b.addTest(.{
            .root_module = x_mod_with_target,
        });
        const run = b.addRunArtifact(unit_tests);
        test_non_interactive.dependOn(&run.step);
    }

    {
        const xauth_exe = b.addExecutable(.{
            .name = "xauth",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/xauth.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "x11", .module = x_mod },
                },
            }),
        });
        const install = b.addInstallArtifact(xauth_exe, .{});
        b.step("install-xauth", "").dependOn(&install.step);
        test_non_interactive.dependOn(&install.step);

        const run = b.addRunArtifact(xauth_exe);
        run.step.dependOn(&install.step);
        if (b.args) |args| run.addArgs(args);
        b.step("xauth", "Run the xauth cmdline tool").dependOn(&run.step);
    }
}
