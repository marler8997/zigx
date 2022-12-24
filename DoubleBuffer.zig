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
const os = std.os;
const ContiguousReadBuffer = @import("ContiguousReadBuffer.zig");

const impl: enum { memfd, shm } = switch (builtin.os.tag) {
    .linux, .freebsd => .memfd,
    .macos => .shm,
    else => @compileError("DoubleBuffer not implemented for OS " ++ @tagName(builtin.os.tag)),
};

ptr: [*]align(std.mem.page_size) u8,
half_len: usize,
data: switch (impl) {
    .memfd => os.fd_t,
    .shm => os.fd_t,
},

pub const InitOptions = struct {
    /// On linux/freebsd, this is the name of the memfd.
    memfd_name: [*:0]const u8 = "DoubleBuffer",
};

pub fn init(half_len: usize, opt: InitOptions) !DoubleBuffer {
    switch (impl) {
        .memfd => {
            const fd = try os.memfd_createZ(opt.memfd_name, 0);
            errdefer os.close(fd);
            const ptr = try mapFdDouble(fd, half_len);
            return .{
                .ptr = ptr,
                .half_len = half_len,
                .data = fd,
            };
        },
        .shm => {
            // WARNING!
            // this this shared memory will continue to exist
            // even after the process dies.  We need some way
            // to make sure that this memory gets cleaned up
            // even if our process crashes.
            // macos limits the name of shm object pretty small
            const rand_byte_len = 15;
            // TODO: use something like base64 instead of hex
            const rand_hex_len = rand_byte_len * 2;
            var unique_name_buf: [rand_hex_len + 1]u8 = undefined;
            const unique_name = blk: {
                var rand_bytes: [rand_byte_len]u8 = undefined;
                try os.getrandom(&rand_bytes);
                break :blk std.fmt.bufPrintZ(
                    &unique_name_buf,
                    "{}",
                    .{ std.fmt.fmtSliceHexLower(&rand_bytes) },
                ) catch unreachable;
            };
            std.debug.assert(unique_name.len + 1 == unique_name_buf.len);

            const fd = std.c.shm_open(
                unique_name,
                std.os.O.RDWR | std.os.O.CREAT | std.os.O.EXCL,
                std.os.S.IRUSR | std.os.S.IWUSR,
            );
            if (fd == -1) switch (@intToEnum(std.os.E, std.c._errno().*)) {
                .EXIST => return error.PathAlreadyExists,
                .NAMETOOLONG => return error.NameTooLong,
                else => |err| return std.os.unexpectedErrno(err),
            };
            errdefer os.close(fd);
            const ptr = try mapFdDouble(fd, half_len);
            return .{
                .ptr = ptr,
                .half_len = half_len,
                .data = fd,
            };
        },
    }
}

pub fn deinit(self: DoubleBuffer) void {
    switch (impl) {
        .memfd, .shm => {
            os.munmap(self.ptr[0 .. self.half_len * 2]);
            os.close(self.data);
        },
    }
}

pub fn contiguousReadBuffer(self: DoubleBuffer) ContiguousReadBuffer {
    return .{
        .double_buffer_ptr = self.ptr,
        .half_len = self.half_len,
    };
}


pub fn mapFdDouble(fd: os.fd_t, half_size: usize) ![*]align(std.mem.page_size) u8 {
    std.debug.assert((half_size % std.mem.page_size) == 0);
    try os.ftruncate(fd, half_size);
    const ptr = (try os.mmap(null, 2 * half_size, os.PROT.NONE, os.MAP.PRIVATE | os.MAP.ANONYMOUS, -1, 0)).ptr;
    _ = try os.mmap(ptr,
        half_size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED | os.MAP.FIXED, fd, 0);
    _ = try os.mmap(@alignCast(std.mem.page_size, ptr + half_size),
        half_size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED | os.MAP.FIXED, fd, 0);
    return ptr;
}
