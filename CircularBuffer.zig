const std = @import("std");
const builtin = @import("builtin");
const os = std.os;

const CircularBuffer = @This();

ptr: [*]u8,
size: usize,
/// goes from 0 to (2*size)-1
/// if less than size, it has not wrapped yet
cursor: usize,

pub fn init(size: usize) !CircularBuffer {
    std.debug.assert((size % std.mem.page_size) == 0);

    if (builtin.os.tag == .windows)
        @panic("not implemented");

    const fd = try os.memfd_createZ("zigCircularBuffer", 0);
    errdefer os.close(fd);

    try os.ftruncate(fd, size);

    const ptr = (try os.mmap(null, 3 * size, os.PROT.NONE, os.MAP.PRIVATE | os.MAP.ANONYMOUS, -1, 0)).ptr;

    _ = try os.mmap(ptr,
        size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED | os.MAP.FIXED, fd, 0);
    _ = try os.mmap(@alignCast(std.mem.page_size, ptr + size),
        size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED | os.MAP.FIXED, fd, 0);
    _ = try os.mmap(@alignCast(std.mem.page_size, ptr + 2*size),
        size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED | os.MAP.FIXED, fd, 0);
    return CircularBuffer{
        .ptr = ptr,
        .size = size,
        .cursor = 0,
    };
}

pub fn initMinSize(min_size: usize) !CircularBuffer {
    // TODO: there's a faster way to do this using division/multiplication
    var size: usize = std.mem.page_size;
    while (size < min_size) {
        size += std.mem.page_size;
    }
    return init(size);
}

pub fn next(self: CircularBuffer) []u8 {
    return (self.ptr + self.cursor)[0 .. self.size];
}

pub fn scroll(self: *CircularBuffer, len: usize) void {
    std.debug.assert(len < self.size);
    self.cursor += len;
    if (self.cursor >= 2*self.size) {
        self.cursor -= self.size;
    }
}
