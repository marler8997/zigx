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

const impl: enum { memfd, shm, windows } = switch (builtin.os.tag) {
    .linux, .freebsd => .memfd,
    .macos => .shm,
    .windows => .windows,
    else => @compileError("DoubleBuffer not implemented for OS " ++ @tagName(builtin.os.tag)),
};

ptr: [*]align(std.mem.page_size) u8,
half_len: usize,
data: switch (impl) {
    .memfd => os.fd_t,
    .shm => os.fd_t,
    .windows => win32.HANDLE,
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
            if (fd == -1) switch (@as(std.os.E, @enumFromInt(std.c._errno().*))) {
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
        .windows => {
            const full_len = half_len * 2;
            const ptr: [*]align(std.mem.page_size) u8 = @alignCast(@ptrCast(win32.VirtualAlloc2FromApp(
                null, null,
                full_len,
                win32.MEM_RESERVE | win32.MEM_RESERVE_PLACEHOLDER,
                win32.PAGE_NOACCESS,
                null, 0,
            ) orelse switch (win32.GetLastError()) {
                else => |err| return std.os.windows.unexpectedError(err),
            }));

            var free_ptr = true;
            defer if (free_ptr) {
                std.os.windows.VirtualFree(ptr, 0, win32.MEM_RELEASE);
            };

            std.os.windows.VirtualFree(
                ptr,
                half_len,
                win32.MEM_RELEASE | win32.MEM_PRESERVE_PLACEHOLDER,
            );

            const back_ptr = ptr + half_len;
            var free_back_ptr = true;
            defer if (free_back_ptr) {
                std.os.windows.VirtualFree(back_ptr, 0, win32.MEM_RELEASE);
            };

            const map = win32.CreateFileMappingW(
                std.os.windows.INVALID_HANDLE_VALUE,
                null,
                win32.PAGE_READWRITE,
                @intCast((half_len >> 32)),
                @intCast((half_len >>  0) & std.math.maxInt(u32)),
                null,
            ) orelse switch (win32.GetLastError()) {
                else => |err| return std.os.windows.unexpectedError(err),
            };
            errdefer os.close(map);

            const ptr_again = win32.MapViewOfFile3FromApp(
                map,
                null,
                ptr,
                0,
                half_len,
                win32.MEM_REPLACE_PLACEHOLDER,
                win32.PAGE_READWRITE,
                null, 0,
            ) orelse switch (win32.GetLastError()) {
                else => |err| return std.os.windows.unexpectedError(err),
            };
            errdefer std.debug.assert(0 != win32.UnmapViewOfFile(ptr_again));
            std.debug.assert(ptr_again == ptr);
            free_ptr = false; // ownership transferred

            const back_ptr_again = win32.MapViewOfFile3FromApp(
                map,
                null,
                back_ptr,
                0,
                half_len,
                win32.MEM_REPLACE_PLACEHOLDER,
                win32.PAGE_READWRITE,
                null, 0,
            ) orelse switch (win32.GetLastError()) {
                else => |err| return std.os.windows.unexpectedError(err),
            };
            errdefer std.debug.assert(0 != win32.UnmapViewOfFile(back_ptr_again));
            std.debug.assert(back_ptr == back_ptr_again);
            free_back_ptr = false; // ownership transferred
            return .{
                .ptr = ptr,
                .half_len = half_len,
                .data = map,
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
        .windows => {
            std.debug.assert(0 != win32.UnmapViewOfFile(self.ptr + self.half_len));
            std.debug.assert(0 != win32.UnmapViewOfFile(self.ptr));
            errdefer os.close(self.data);
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
    _ = try os.mmap(@alignCast(ptr + half_size),
        half_size, os.PROT.READ | os.PROT.WRITE, os.MAP.SHARED | os.MAP.FIXED, fd, 0);
    return ptr;
}

const win32 = struct {
    pub const BOOL = i32;
    pub const HANDLE = std.os.windows.HANDLE;
    pub const GetLastError = std.os.windows.kernel32.GetLastError;
    pub const PAGE_NOACCESS = 1;
    pub const PAGE_READWRITE = 4;
    pub extern "kernel32" fn CreateFileMappingW(
        hFile: ?HANDLE,
        lpFileMappingAttributes: ?*anyopaque,
        flProtect: u32,
        dwMaximumSizeHigh: u32,
        dwMaximumSizeLow: u32,
        lpName: ?[*:0]const u16,
    ) callconv(@import("std").os.windows.WINAPI) ?HANDLE;
    pub const MEM_PRESERVE_PLACEHOLDER = 0x00002;
    pub const MEM_COMMIT               = 0x01000;
    pub const MEM_RESERVE              = 0x02000;
    pub const MEM_REPLACE_PLACEHOLDER  = 0x04000;
    pub const MEM_RELEASE              = 0x08000;
    pub const MEM_FREE                 = 0x10000;
    pub const MEM_RESERVE_PLACEHOLDER  = 0x40000;
    pub const MEM_RESET                = 0x80000;
    pub extern "api-ms-win-core-memory-l1-1-6" fn VirtualAlloc2FromApp(
        Process: ?HANDLE,
        BaseAddress: ?*anyopaque,
        Size: usize,
        AllocationType: u32,
        PageProtection: u32,
        ExtendedParameters: ?*anyopaque,
        ParameterCount: u32,
    ) callconv(@import("std").os.windows.WINAPI) ?*anyopaque;
    pub extern "api-ms-win-core-memory-l1-1-6" fn MapViewOfFile3FromApp(
        FileMapping: ?HANDLE,
        Process: ?HANDLE,
        BaseAddress: ?*anyopaque,
        Offset: u64,
        ViewSize: usize,
        AllocationType: u32,
        PageProtection: u32,
        ExtendedParameters: ?*anyopaque,
        ParameterCount: u32,
    ) callconv(@import("std").os.windows.WINAPI) ?[*]u8;
    pub extern "kernel32" fn UnmapViewOfFile(
        lpBaseAddress: ?[*]const u8,
    ) callconv(@import("std").os.windows.WINAPI) BOOL;
};
