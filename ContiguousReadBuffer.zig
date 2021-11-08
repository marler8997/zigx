///! Provides a read/reserve interface which allows data to be read and processed
///! continguously without moving memory around.
///!
///! This is useful if you're reading data and processing it, but sometimes need
///! to leave data in the buffer before the next read.
const std = @import("std");

const ContiguousReadBuffer = @This();

double_buffer_ptr: [*]u8,
half_size: usize,

// reserved_limit is always < buf.half_size
reserved_limit: usize = 0,

// reserved_len is always <= buf.half_size
reserved_len: usize = 0,

pub fn nextReadBuffer(self: ContiguousReadBuffer) []u8 {
    return self.double_buffer_ptr[self.reserved_limit .. self.reserved_limit + self.half_size - self.reserved_len];
}

pub fn nextReservedBuffer(self: ContiguousReadBuffer) []u8 {
    const limit = self.reserved_limit + self.half_size;
    return self.double_buffer_ptr[limit - self.reserved_len .. limit];
}

pub fn reserve(self: *ContiguousReadBuffer, len: usize) void {
    const new_len = self.reserved_len + len;
    std.debug.assert(new_len <= self.half_size);
    var new_reserved_limit = self.reserved_limit + len;
    if (new_reserved_limit >= self.half_size) {
        new_reserved_limit -= self.half_size;
    }
    self.reserved_limit = new_reserved_limit;
    self.reserved_len = new_len;
}

pub fn release(self: *ContiguousReadBuffer, len: usize) void {
    std.debug.assert(len <= self.reserved_len);
    self.reserved_len -= len;
}

/// Call this after calling 'release' if you want to reset the read buffer
/// back to the beginning when it is empty.
pub fn resetIfEmpty(self: *ContiguousReadBuffer) void {
    if (self.reserved_len == 0) {
        self.reserved_limit = 0;
    }
}
