const builtin = @import("builtin");
const std = @import("std");
const os = std.os;
const Memfd = @This();

fd: os.fd_t,

pub fn init(name: [:0]const u8) !Memfd {
    return Memfd{ .fd = try os.memfd_createZ(name, 0) };
}

pub fn deinit(self: Memfd) void {
    os.close(self.fd);
}

pub fn toDoubleBuffer(self: Memfd, half_size: usize) ![*]u8 {
    std.debug.assert((half_size % std.mem.page_size) == 0);

    if (builtin.os.tag == .windows)
        @panic("not implemented");

    try os.ftruncate(self.fd, half_size);

    const ptr = (try os.mmap(null, 2 * half_size, os.PROT.NONE, os.MAP.PRIVATE | os.MAP.ANONYMOUS, -1, 0)).ptr;

    _ = try os.mmap(ptr,
        half_size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED | os.MAP.FIXED, self.fd, 0);
    _ = try os.mmap(@alignCast(std.mem.page_size, ptr + half_size),
        half_size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED | os.MAP.FIXED, self.fd, 0);

    return ptr;
}
