const MappedFile = @This();

const builtin = @import("builtin");
const std = @import("std");
const HANDLE = std.os.windows.HANDLE;

mem: []align(std.mem.page_size) u8,
mapping: if (builtin.os.tag == .windows) HANDLE else void,

pub const Options = struct {
    mode: enum { read_only, read_write } = .read_only,
};
const empty_mem: [0]u8 align(std.mem.page_size) = undefined;

pub fn init(filename: []const u8, opt: Options) !MappedFile {
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    const file_size = try file.getEndPos();

    if (builtin.os.tag == .windows) {
        if (file_size == 0) return MappedFile{
            .mem = &empty_mem,
            .mapping = undefined,
        };

        const mapping = win32.CreateFileMappingA(
            file.handle,
            null,
            switch (opt.mode) {
                .read_only => win32.PAGE_READONLY,
                .read_write => win32.PAGE_READWRITE,
            },
            @intCast(0xffffffff & (file_size >> 32)),
            @intCast(0xffffffff & (file_size)),
            null,
        ) orelse return switch (win32.GetLastError()) {
            .DISK_FULL => |e| switch (opt.mode) {
                .read_only => std.os.windows.unexpectedError(e),
                .read_write => error.DiskFull,
            },
            else => |err| std.os.windows.unexpectedError(err),
        };
        errdefer std.os.windows.CloseHandle(mapping);

        const ptr = win32.MapViewOfFile(
            mapping,
            switch (opt.mode) {
                .read_only => win32.FILE_MAP_READ,
                .read_write => win32.FILE_MAP_READ | win32.FILE_MAP_READ,
            },
            0, 0, 0,
        ) orelse return switch (win32.GetLastError()) {
            // TODO: handle some error codes
            else => |err| std.os.windows.unexpectedError(err),
        };
        errdefer std.debug.assert(0 != win32.UnmapViewOfFile(ptr));
        
        return .{
            .mem = @as([*]align(std.mem.page_size)u8, @alignCast(@ptrCast(ptr)))[0 .. file_size],
            .mapping = mapping,
        };        
    }
    return .{
        .mem = try std.os.mmap(
            null,
            file_size,
            switch (opt.mode) {
                .read_only => std.os.PROT.READ,
                .read_write => std.os.PROT.READ | std.os.PROT.WRITE,
            },
            std.os.MAP.PRIVATE,
            file.handle,
            0,
        ),
        .mapping = {},
    };    
}
             
pub fn unmap(self: MappedFile) void {
    if (builtin.os.tag == .windows) {
        if (self.mem.len != 0) {
            std.debug.assert(0 != win32.UnmapViewOfFile(self.mem.ptr));
            std.os.windows.CloseHandle(self.mapping);
        }
    } else {
        std.os.munmap(self.mem);
    }
}

const win32 = struct {
    pub const BOOL = i32;
    pub const GetLastError = std.os.windows.kernel32.GetLastError;
    pub const PAGE_READONLY = 2;
    pub const PAGE_READWRITE = 4;
    pub extern "kernel32" fn CreateFileMappingA(
        hFile: ?HANDLE,
        lpFileMappingAttributes: ?*anyopaque,
        flProtect: u32,
        dwMaximumSizeHigh: u32,
        dwMaximumSizeLow: u32,
        lpName: ?[*:0]const u8,
    ) callconv(std.os.windows.WINAPI) ?HANDLE;

    pub const FILE_MAP_WRITE = 2;
    pub const FILE_MAP_READ = 4;
    pub extern "kernel32" fn MapViewOfFile(
        hFileMappingObject: ?HANDLE,
        dwDesiredAccess: u32,
        dwFileOffsetHigh: u32,
        dwFileOffsetLow: u32,
        dwNumberOfBytesToMap: usize,
    ) callconv(std.os.windows.WINAPI) ?*anyopaque;
    pub extern "kernel32" fn UnmapViewOfFile(
        lpBaseAddress: ?*const anyopaque,
    ) callconv(std.os.windows.WINAPI) BOOL;
};
