//! This file exists to patch this discard bug: https://github.com/ziglang/zig/issues/25620
pub const vtable: std.Io.Reader.VTable = .{
    .stream = stream,
    .readVec = readVec,
    .discard = defaultDiscardPatched,
};

const max_buffers_len = 8;
const Error = std.net.Stream.ReadError;

fn stream(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const dest = limit.slice(try io_w.writableSliceGreedy(1));
    var bufs: [1][]u8 = .{dest};
    const n = try readVec(io_r, &bufs);
    io_w.advance(n);
    return n;
}

fn readVec(io_r: *std.Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    const r: *Reader = @alignCast(@fieldParentPtr("interface_state", io_r));
    var iovecs: [max_buffers_len]windows.ws2_32.WSABUF = undefined;
    const bufs_n, const data_size = try io_r.writableVectorWsa(&iovecs, data);
    const bufs = iovecs[0..bufs_n];
    assert(bufs[0].len != 0);
    const n = streamBufs(r, bufs) catch |err| {
        r.error_state = err;
        return error.ReadFailed;
    };
    if (n == 0) return error.EndOfStream;
    if (n > data_size) {
        io_r.end += n - data_size;
        return data_size;
    }
    return n;
}

fn handleRecvError(winsock_error: windows.ws2_32.WinsockError) Error!void {
    switch (winsock_error) {
        .WSAECONNRESET => return error.ConnectionResetByPeer,
        .WSAEFAULT => unreachable, // a pointer is not completely contained in user address space.
        .WSAEINPROGRESS, .WSAEINTR => unreachable, // deprecated and removed in WSA 2.2
        .WSAEINVAL => return error.SocketNotBound,
        .WSAEMSGSIZE => return error.MessageTooBig,
        .WSAENETDOWN => return error.NetworkSubsystemFailed,
        .WSAENETRESET => return error.ConnectionResetByPeer,
        .WSAENOTCONN => return error.SocketNotConnected,
        .WSAEWOULDBLOCK => return error.WouldBlock,
        .WSANOTINITIALISED => unreachable, // WSAStartup must be called before this function
        .WSA_IO_PENDING => unreachable,
        .WSA_OPERATION_ABORTED => unreachable, // not using overlapped I/O
        else => |err| return windows.unexpectedWSAError(err),
    }
}

fn streamBufs(r: *Reader, bufs: []windows.ws2_32.WSABUF) Error!u32 {
    var flags: u32 = 0;
    var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);

    var n: u32 = undefined;
    if (windows.ws2_32.WSARecv(
        r.net_stream.handle,
        bufs.ptr,
        @intCast(bufs.len),
        &n,
        &flags,
        &overlapped,
        null,
    ) == windows.ws2_32.SOCKET_ERROR) switch (windows.ws2_32.WSAGetLastError()) {
        .WSA_IO_PENDING => {
            var result_flags: u32 = undefined;
            if (windows.ws2_32.WSAGetOverlappedResult(
                r.net_stream.handle,
                &overlapped,
                &n,
                windows.TRUE,
                &result_flags,
            ) == windows.FALSE) try handleRecvError(windows.ws2_32.WSAGetLastError());
        },
        else => |winsock_error| try handleRecvError(winsock_error),
    };

    return n;
}

fn defaultDiscardPatched(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
    std.debug.assert(r.seek == r.end);
    r.seek = 0;
    r.end = 0;
    var d: std.Io.Writer.Discarding = .init(r.buffer);
    var n = r.stream(&d.writer, limit) catch |err| switch (err) {
        error.WriteFailed => unreachable,
        error.ReadFailed => return error.ReadFailed,
        error.EndOfStream => return error.EndOfStream,
    };
    // If `stream` wrote to `r.buffer` without going through the writer,
    // we need to discard as much of the buffered data as possible.
    const remaining = @intFromEnum(limit) - n;
    const buffered_n_to_discard = @min(remaining, r.end - r.seek);
    n += buffered_n_to_discard;
    r.seek += buffered_n_to_discard;
    std.debug.assert(n <= @intFromEnum(limit));
    return n;
}

const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
const native_os = builtin.os.tag;
const Reader = std.net.Stream.Reader;
const Io = std.Io;
const assert = std.debug.assert;
