const zig_atleast_15 = builtin.zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

const Iovlen = if (!zig_atleast_15 and builtin.cpu.arch == .x86_64)
    u32
else
    @FieldType(std.posix.msghdr_const, "iovlen");

pub const Writer = if (zig_atleast_15) std.Io.Writer else struct {
    vtable: *const VTable,
    buffer: []u8,
    end: usize = 0,

    pub const VTable = struct {
        drain: *const fn (w: *Writer, data: []const []const u8, splat: usize) Error!usize,
        flush: *const fn (w: *Writer) Error!void = defaultFlush,
    };

    pub const Error = error{
        WriteFailed,
    };

    const max_buffers_len = 8;

    fn addBuf(v: []std.posix.iovec_const, i: *Iovlen, bytes: []const u8) void {
        // OS checks ptr addr before length so zero length vectors must be omitted.
        if (bytes.len == 0) return;
        if (v.len - i.* == 0) return;
        v[i.*] = .{ .base = bytes.ptr, .len = bytes.len };
        i.* += 1;
    }
    fn addWsaBuf(v: []windows.ws2_32.WSABUF, i: *u32, bytes: []const u8) void {
        const cap = std.math.maxInt(u32);
        var remaining = bytes;
        while (remaining.len > cap) {
            if (v.len - i.* == 0) return;
            v[i.*] = .{ .buf = @constCast(remaining.ptr), .len = cap };
            i.* += 1;
            remaining = remaining[cap..];
        } else {
            @branchHint(.likely);
            if (v.len - i.* == 0) return;
            v[i.*] = .{ .buf = @constCast(remaining.ptr), .len = @intCast(remaining.len) };
            i.* += 1;
        }
    }
    fn sendBufs(handle: std.posix.socket_t, bufs: []windows.ws2_32.WSABUF) Error!u32 {
        var n: u32 = undefined;
        var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        if (windows.ws2_32.WSASend(
            handle,
            bufs.ptr,
            @intCast(bufs.len),
            &n,
            0,
            &overlapped,
            null,
        ) == windows.ws2_32.SOCKET_ERROR) switch (windows.ws2_32.WSAGetLastError()) {
            .WSA_IO_PENDING => {
                var result_flags: u32 = undefined;
                if (windows.ws2_32.WSAGetOverlappedResult(
                    handle,
                    &overlapped,
                    &n,
                    windows.TRUE,
                    &result_flags,
                ) == windows.FALSE) try handleSendError(windows.ws2_32.WSAGetLastError());
            },
            else => |winsock_error| try handleSendError(winsock_error),
        };

        return n;
    }
    fn handleSendError(winsock_error: windows.ws2_32.WinsockError) Error!void {
        switch (winsock_error) {
            .WSAECONNABORTED => return error.ConnectionResetByPeer,
            .WSAECONNRESET => return error.ConnectionResetByPeer,
            .WSAEFAULT => unreachable, // a pointer is not completely contained in user address space.
            .WSAEINPROGRESS, .WSAEINTR => unreachable, // deprecated and removed in WSA 2.2
            .WSAEINVAL => return error.SocketNotBound,
            .WSAEMSGSIZE => return error.MessageTooBig,
            .WSAENETDOWN => return error.NetworkSubsystemFailed,
            .WSAENETRESET => return error.ConnectionResetByPeer,
            .WSAENOBUFS => return error.SystemResources,
            .WSAENOTCONN => return error.SocketNotConnected,
            .WSAENOTSOCK => unreachable, // not a socket
            .WSAEOPNOTSUPP => unreachable, // only for message-oriented sockets
            .WSAESHUTDOWN => unreachable, // cannot send on a socket after write shutdown
            .WSAEWOULDBLOCK => return error.WouldBlock,
            .WSANOTINITIALISED => unreachable, // WSAStartup must be called before this function
            .WSA_IO_PENDING => unreachable,
            .WSA_OPERATION_ABORTED => unreachable, // not using overlapped I/O
            else => |err| return windows.unexpectedWSAError(err),
        }
    }

    pub fn flush(w: *Writer) Error!void {
        return w.vtable.flush(w);
    }
    /// Repeatedly calls `VTable.drain` until `end` is zero.
    pub fn defaultFlush(w: *Writer) Error!void {
        const drainFn = w.vtable.drain;
        while (w.end != 0) _ = try drainFn(w, &.{""}, 1);
    }

    pub fn consume(w: *Writer, n: usize) usize {
        if (n < w.end) {
            const remaining = w.buffer[n..w.end];
            std.mem.copyForwards(u8, w.buffer[0..remaining.len], remaining);
            w.end = remaining.len;
            return 0;
        }
        defer w.end = 0;
        return n - w.end;
    }

    pub fn buffered(w: *const Writer) []u8 {
        return w.buffer[0..w.end];
    }

    fn countSplat(data: []const []const u8, splat: usize) usize {
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |buf| total += buf.len;
        total += data[data.len - 1].len * splat;
        return total;
    }

    pub fn writeSplat(w: *Writer, data: []const []const u8, splat: usize) Error!usize {
        std.debug.assert(data.len > 0);
        const buffer = w.buffer;
        const count = countSplat(data, splat);
        if (w.end + count > buffer.len) return w.drain(data, splat);
        for (data[0 .. data.len - 1]) |bytes| {
            @memcpy(buffer[w.end..][0..bytes.len], bytes);
            w.end += bytes.len;
        }
        const pattern = data[data.len - 1];
        switch (pattern.len) {
            0 => {},
            1 => {
                @memset(buffer[w.end..][0..splat], pattern[0]);
                w.end += splat;
            },
            else => for (0..splat) |_| {
                @memcpy(buffer[w.end..][0..pattern.len], pattern);
                w.end += pattern.len;
            },
        }
        return count;
    }

    pub fn writeVec(w: *Writer, data: []const []const u8) Error!usize {
        return writeSplat(w, data, 1);
    }

    pub fn write(w: *Writer, bytes: []const u8) Error!usize {
        if (w.end + bytes.len <= w.buffer.len) {
            @branchHint(.likely);
            @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
            w.end += bytes.len;
            return bytes.len;
        }
        return w.vtable.drain(w, &.{bytes}, 1);
    }

    pub fn writeAll(w: *Writer, bytes: []const u8) Error!void {
        var index: usize = 0;
        while (index < bytes.len) index += try w.write(bytes[index..]);
    }
    pub inline fn writeInt(w: *Writer, comptime T: type, value: T, endian: std.builtin.Endian) Error!void {
        var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(std.math.ByteAlignedInt(@TypeOf(value)), &bytes, value, endian);
        return w.writeAll(&bytes);
    }
    pub fn writeVecAll(w: *Writer, data: [][]const u8) Error!void {
        var index: usize = 0;
        var truncate: usize = 0;
        while (index < data.len) {
            {
                const untruncated = data[index];
                data[index] = untruncated[truncate..];
                defer data[index] = untruncated;
                truncate += try w.writeVec(data[index..]);
            }
            while (index < data.len and truncate >= data[index].len) {
                truncate -= data[index].len;
                index += 1;
            }
        }
    }
};

const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
