/// A DoubleBuffer is 2 consecutive buffers of the same memory.
/// Any modifications to one half are immediately reflected in
/// the other half.
///
/// The main use case for DoubleBuffer is to maintain a queue of
/// data that can always be presented as contiguous without moving memory
/// around.
const DoubleBuffer = @This();

const builtin = @import("builtin");
const std = @import("std");
const ContiguousReadBuffer = @import("ContiguousReadBuffer.zig");
const Memfd = @import("Memfd.zig");

const impl: enum { memfd } = switch (builtin.os.tag) {
    .linux, .freebsd => .memfd,
    else => @compileError("DoubleBuffer not implemented for this target OS"),
};

ptr: [*]align(std.mem.page_size) u8,
half_len: usize,
data: switch (impl) {
    .memfd => Memfd,
},

pub const InitOptions = struct {
    /// Configure the memfd name (only applies to linux and freebsd).
    memfd_name: [*:0]const u8 = "DoubleBuffer",
};

pub fn init(half_len: usize, opt: InitOptions) !DoubleBuffer {
    switch (impl) {
        .memfd => {
            const memfd = try Memfd.init(opt.memfd_name);
            errdefer memfd.deinit();
            const ptr = try memfd.toDoubleBuffer(half_len);
            return .{
                .ptr = ptr,
                .half_len = half_len,
                .data = memfd,
            };
        },
    }
}

pub fn deinit(self: DoubleBuffer) void {
    switch (impl) {
        .memfd => {
            std.os.munmap(self.ptr[0 .. self.half_len * 2]);
            self.data.deinit();
        },
    }
}

pub fn contiguousReadBuffer(self: DoubleBuffer) ContiguousReadBuffer {
    return .{
        .double_buffer_ptr = self.ptr,
        .half_len = self.half_len,
    };
}
