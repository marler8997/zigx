const std = @import("../std.zig");
const builtin = @import("builtin");
pub const off_t = @import("std").os.linux.off_t;
fn errnoFromSyscall(r: usize) E {
    const signed_r: isize = @bitCast(r);
    const int = if (signed_r > -4096 and signed_r < 0) -signed_r else 0;
    return @enumFromInt(int);
}
pub const sendfile = @import("std").os.linux.sendfile;
pub const statx = @import("std").os.linux.statx;
pub const copy_file_range = @import("std").os.linux.copy_file_range;
pub const E = @import("std").os.linux.E;
const fd_t = @import("std").os.linux.fd_t;
pub const AT = @import("std").os.linux.AT;
pub const S = @import("std").os.linux.S;
pub const STATX_TYPE = @import("std").os.linux.STATX_TYPE;
pub const STATX_MODE = @import("std").os.linux.STATX_MODE;
pub const STATX_ATIME = @import("std").os.linux.STATX_ATIME;
pub const STATX_MTIME = @import("std").os.linux.STATX_MTIME;
pub const STATX_CTIME = @import("std").os.linux.STATX_CTIME;
pub const Statx = @import("std").os.linux.Statx;
pub const wrapped = struct {
    pub const lfs64_abi = builtin.link_libc and (builtin.abi.isGnu() or builtin.abi.isAndroid());
    const system = if (builtin.link_libc) std.c else std.os.linux;

    pub const SendfileError = std.posix.UnexpectedError || error{
        BrokenPipe,
        UnsupportedOperation,
        WouldBlock,
        InputOutput,
        SystemResources,
        Unseekable,
    };

    pub fn sendfile(
        out_fd: fd_t,
        in_fd: fd_t,
        in_offset: ?*off_t,
        in_len: usize,
    ) SendfileError!usize {
        const adjusted_len = @min(in_len, 0x7ffff000); // Prevents EOVERFLOW.
        const sendfileSymbol = if (lfs64_abi) system.sendfile64 else system.sendfile;
        const rc = sendfileSymbol(out_fd, in_fd, in_offset, adjusted_len);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return invalidApiUsage(), // Always a race condition.
            .FAULT => return invalidApiUsage(), // Segmentation fault.
            .OVERFLOW => return unexpectedErrno(.OVERFLOW), // We avoid passing too large of a `count`.
            .NOTCONN => return error.BrokenPipe, // `out_fd` is an unconnected socket
            .INVAL => return error.UnsupportedOperation,
            .AGAIN => return error.WouldBlock,
            .IO => return error.InputOutput,
            .PIPE => return error.BrokenPipe,
            .NOMEM => return error.SystemResources,
            .NXIO => return error.Unseekable,
            .SPIPE => return error.Unseekable,
            else => |err| return unexpectedErrno(err),
        }
    }

    pub const CopyFileRangeError = std.posix.UnexpectedError || error{
        BadFileFlags,
        FileTooBig,
        InvalidArguments,
        InputOutput,
        IsDir,
        OutOfMemory,
        NoSpaceLeft,
        OperationNotSupported,
        Overflow,
        PermissionDenied,
        SwapFile,
        NotSameFileSystem,
    };

    pub fn copy_file_range(fd_in: fd_t, off_in: ?*i64, fd_out: fd_t, off_out: ?*i64, len: usize, flags: u32) CopyFileRangeError!usize {
        const use_c = std.c.versionCheck(if (builtin.abi.isAndroid()) .{ .major = 34, .minor = 0, .patch = 0 } else .{ .major = 2, .minor = 27, .patch = 0 });
        const sys = if (use_c) std.c else std.os.linux;
        const rc = sys.copy_file_range(fd_in, off_in, fd_out, off_out, len, flags);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .BADF => return error.BadFileFlags,
            .FBIG => return error.FileTooBig,
            .INVAL => return error.InvalidArguments,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOMEM => return error.OutOfMemory,
            .NOSPC => return error.NoSpaceLeft,
            .OPNOTSUPP => return error.OperationNotSupported,
            .OVERFLOW => return error.Overflow,
            .PERM => return error.PermissionDenied,
            .TXTBSY => return error.SwapFile,
            .XDEV => return error.NotSameFileSystem,
            else => |err| return unexpectedErrno(err),
        }
    }

    const unexpectedErrno = std.posix.unexpectedErrno;

    fn invalidApiUsage() error{Unexpected} {
        if (builtin.mode == .Debug) @panic("invalid API usage");
        return error.Unexpected;
    }

    fn errno(rc: anytype) E {
        if (builtin.link_libc) {
            return if (rc == -1) @enumFromInt(std.c._errno().*) else .SUCCESS;
        } else {
            return errnoFromSyscall(rc);
        }
    }
};
