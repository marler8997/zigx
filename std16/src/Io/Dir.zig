const Dir = @This();

const std = @import("../std.zig");
const Io = std.Io;
const File = Io.File;

handle: Handle,

pub const Handle = std.posix.fd_t;

fn legacy(dir: Dir) std.fs.Dir {
    return .{ .fd = dir.handle };
}

pub fn cwd() Dir {
    return .{ .handle = std.fs.cwd().fd };
}

pub fn openFile(dir: Dir, io: Io, sub_path: []const u8, flags: std.fs.File.OpenFlags) std.fs.File.OpenError!File {
    _ = io;
    return .{ .handle = (try dir.legacy().openFile(sub_path, flags)).handle };
}

pub fn readFileAlloc(
    dir: Dir,
    io: Io,
    sub_path: []const u8,
    gpa: std.mem.Allocator,
    limit: Io.Limit,
) ![]u8 {
    _ = io;
    const max_bytes: usize = switch (limit) {
        .unlimited => std.math.maxInt(usize),
        else => @intCast(@intFromEnum(limit)),
    };
    return dir.legacy().readFileAlloc(gpa, sub_path, max_bytes);
}
