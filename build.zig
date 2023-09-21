const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("zigx", .{
        .source_file = .{ .path = "x.zig" },
    });

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "x.zig" },
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // This exposes a `test` step to the `zig build --help` menu, providing a way for
    // the user to request running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
