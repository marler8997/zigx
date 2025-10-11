const builtin = @import("builtin");
const native_os = builtin.os.tag;
const windows = @import("std").os.windows;
pub const system = @import("std").posix.system;
pub const MSG = @import("std").posix.MSG;
pub const SEEK = system.SEEK;
pub const Stat = system.Stat;
pub const fd_t = system.fd_t;
pub const ino_t = system.ino_t;
pub const mode_t = system.mode_t;
pub const msghdr_const = switch (builtin.os.tag) {
    .linux => extern struct {
        name: ?*const sockaddr,
        namelen: socklen_t,
        iov: [*]const iovec_const,
        iovlen: usize,
        control: ?*const anyopaque,
        controllen: usize,
        flags: u32,
    },
    else => system.msghdr_const,
};
pub const sockaddr = system.sockaddr;
pub const socklen_t = system.socklen_t;
pub const iovec = @import("std").posix.iovec;
pub const iovec_const = @import("std").posix.iovec_const;
pub const socket_t = @import("std").posix.socket_t;
pub const errno = @import("std").posix.errno;
pub const ReadError = @import("std").posix.ReadError;
pub const readv = @import("std").posix.readv;
pub const preadv = @import("std").posix.preadv;
pub const WriteError = @import("std").posix.WriteError;
pub const writev = @import("std").posix.writev;
pub const pwritev = @import("std").posix.pwritev;
pub const FStatError = @import("std").posix.FStatError;
pub const SeekError = @import("std").posix.SeekError;
pub const lseek_SET = @import("std").posix.lseek_SET;
pub const lseek_CUR = @import("std").posix.lseek_CUR;
pub const SendMsgError = @import("std").posix.SendMsgError;
pub fn sendmsg(
    /// The file descriptor of the sending socket.
    sockfd: socket_t,
    /// Message header and iovecs
    msg: *const msghdr_const,
    flags: u32,
) SendMsgError!usize {
    while (true) {
        const rc = system.sendmsg(sockfd, @ptrCast(msg), flags);
        if (native_os == .windows) {
            if (rc == windows.ws2_32.SOCKET_ERROR) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSAEACCES => return error.AccessDenied,
                    .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                    .WSAECONNRESET => return error.ConnectionResetByPeer,
                    .WSAEMSGSIZE => return error.MessageTooBig,
                    .WSAENOBUFS => return error.SystemResources,
                    .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                    .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                    .WSAEDESTADDRREQ => unreachable, // A destination address is required.
                    .WSAEFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                    .WSAEHOSTUNREACH => return error.NetworkUnreachable,
                    // TODO: WSAEINPROGRESS, WSAEINTR
                    .WSAEINVAL => unreachable,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENETRESET => return error.ConnectionResetByPeer,
                    .WSAENETUNREACH => return error.NetworkUnreachable,
                    .WSAENOTCONN => return error.SocketNotConnected,
                    .WSAESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                    .WSAEWOULDBLOCK => return error.WouldBlock,
                    .WSANOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                    else => |err| return windows.unexpectedWSAError(err),
                }
            } else {
                return @intCast(rc);
            }
        } else {
            switch (errno(rc)) {
                .SUCCESS => return @intCast(rc),

                .ACCES => return error.AccessDenied,
                .AGAIN => return error.WouldBlock,
                .ALREADY => return error.FastOpenAlreadyInProgress,
                .BADF => unreachable, // always a race condition
                .CONNRESET => return error.ConnectionResetByPeer,
                .DESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
                .FAULT => unreachable, // An invalid user space address was specified for an argument.
                .INTR => continue,
                .INVAL => unreachable, // Invalid argument passed.
                .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
                .MSGSIZE => return error.MessageTooBig,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
                .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
                .PIPE => return error.BrokenPipe,
                .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                .LOOP => return error.SymLinkLoop,
                .NAMETOOLONG => return error.NameTooLong,
                .NOENT => return error.FileNotFound,
                .NOTDIR => return error.NotDir,
                .HOSTUNREACH => return error.NetworkUnreachable,
                .NETUNREACH => return error.NetworkUnreachable,
                .NOTCONN => return error.SocketNotConnected,
                .NETDOWN => return error.NetworkSubsystemFailed,
                else => |err| return unexpectedErrno(err),
            }
        }
    }
}
pub const UnexpectedError = @import("std").posix.UnexpectedError;
pub const unexpectedErrno = @import("std").posix.unexpectedErrno;
