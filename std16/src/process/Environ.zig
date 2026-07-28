const Environ = @This();

const std = @import("../std.zig");

pub fn getPosix(e: Environ, key: []const u8) ?[:0]const u8 {
    _ = e;
    return std.posix.getenv(key);
}

pub const GetAllocError = error{ OutOfMemory, InvalidWtf8, EnvironmentVariableNotFound };
pub fn getAlloc(e: Environ, gpa: std.mem.Allocator, key: []const u8) GetAllocError![]u8 {
    _ = e;
    return std.process.getEnvVarOwned(gpa, key);
}
