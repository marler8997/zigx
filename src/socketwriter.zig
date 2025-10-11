const zig_atleast_15 = builtin.zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

const Iovlen = if (!zig_atleast_15 and builtin.cpu.arch == .x86_64)
    u32
else
    @FieldType(std.posix.msghdr_const, "iovlen");

pub const SocketWriter = if (zig_atleast_15) std.net.Stream.Writer else struct {
    interface: Writer,
    stream: std.net.Stream,
    err: ?anyerror = null,

    pub fn init(stream: std.net.Stream, buffer: []u8) SocketWriter {
        return .{
            .stream = stream,
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = buffer,
            },
        };
    }

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
    fn sendBufs(handle: std.posix.socket_t, bufs: []windows.ws2_32.WSABUF) !u32 {
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
    fn handleSendError(winsock_error: windows.ws2_32.WinsockError) !void {
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

    fn drain(io_w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const w: *SocketWriter = @alignCast(@fieldParentPtr("interface", io_w));
        if (builtin.os.tag == .windows) {
            const buffered = io_w.buffered();
            var iovecs: [max_buffers_len]windows.ws2_32.WSABUF = undefined;
            var len: u32 = 0;
            addWsaBuf(&iovecs, &len, buffered);
            for (data[0 .. data.len - 1]) |bytes| addWsaBuf(&iovecs, &len, bytes);
            const pattern = data[data.len - 1];
            if (iovecs.len - len != 0) switch (splat) {
                0 => {},
                1 => addWsaBuf(&iovecs, &len, pattern),
                else => switch (pattern.len) {
                    0 => {},
                    1 => {
                        const splat_buffer_candidate = io_w.buffer[io_w.end..];
                        var backup_buffer: [64]u8 = undefined;
                        const splat_buffer = if (splat_buffer_candidate.len >= backup_buffer.len)
                            splat_buffer_candidate
                        else
                            &backup_buffer;
                        const memset_len = @min(splat_buffer.len, splat);
                        const buf = splat_buffer[0..memset_len];
                        @memset(buf, pattern[0]);
                        addWsaBuf(&iovecs, &len, buf);
                        var remaining_splat = splat - buf.len;
                        while (remaining_splat > splat_buffer.len and len < iovecs.len) {
                            addWsaBuf(&iovecs, &len, splat_buffer);
                            remaining_splat -= splat_buffer.len;
                        }
                        addWsaBuf(&iovecs, &len, splat_buffer[0..remaining_splat]);
                    },
                    else => for (0..@min(splat, iovecs.len - len)) |_| {
                        addWsaBuf(&iovecs, &len, pattern);
                    },
                },
            };
            const n = sendBufs(w.stream.handle, iovecs[0..len]) catch |err| {
                w.err = err;
                return error.WriteFailed;
            };
            return io_w.consume(n);
        }

        const buffered = io_w.buffered();
        var iovecs: [max_buffers_len]std.posix.iovec_const = undefined;
        var msg: std.posix.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iovecs,
            .iovlen = 0,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        {
            var iovlen: Iovlen = @bitCast(msg.iovlen);
            addBuf(&iovecs, &iovlen, buffered);
            msg.iovlen = @bitCast(iovlen);
        }
        for (data[0 .. data.len - 1]) |bytes| {
            var iovlen: Iovlen = @bitCast(msg.iovlen);
            addBuf(&iovecs, &iovlen, bytes);
            msg.iovlen = @bitCast(iovlen);
        }
        const pattern = data[data.len - 1];
        if (iovecs.len - @as(Iovlen, @bitCast(msg.iovlen)) != 0) switch (splat) {
            0 => {},
            1 => {
                var iovlen: Iovlen = @bitCast(msg.iovlen);
                addBuf(&iovecs, &iovlen, pattern);
                msg.iovlen = @bitCast(iovlen);
            },
            else => switch (pattern.len) {
                0 => {},
                1 => {
                    const splat_buffer_candidate = io_w.buffer[io_w.end..];
                    var backup_buffer: [64]u8 = undefined;
                    const splat_buffer = if (splat_buffer_candidate.len >= backup_buffer.len)
                        splat_buffer_candidate
                    else
                        &backup_buffer;
                    const memset_len = @min(splat_buffer.len, splat);
                    const buf = splat_buffer[0..memset_len];
                    @memset(buf, pattern[0]);
                    {
                        var iovlen: Iovlen = @bitCast(msg.iovlen);
                        addBuf(&iovecs, &iovlen, buf);
                        msg.iovlen = @bitCast(iovlen);
                    }
                    var remaining_splat = splat - buf.len;
                    while (remaining_splat > splat_buffer.len and iovecs.len - @as(Iovlen, @bitCast(msg.iovlen)) != 0) {
                        std.debug.assert(buf.len == splat_buffer.len);
                        var iovlen: Iovlen = @bitCast(msg.iovlen);
                        addBuf(&iovecs, &iovlen, splat_buffer);
                        msg.iovlen = @bitCast(iovlen);
                        remaining_splat -= splat_buffer.len;
                    }

                    var iovlen: Iovlen = @bitCast(msg.iovlen);
                    addBuf(&iovecs, &iovlen, splat_buffer[0..remaining_splat]);
                    msg.iovlen = @bitCast(iovlen);
                },
                else => for (0..@min(splat, iovecs.len - @as(Iovlen, @bitCast(msg.iovlen)))) |_| {
                    var iovlen: Iovlen = @bitCast(msg.iovlen);
                    addBuf(&iovecs, &iovlen, pattern);
                    msg.iovlen = @bitCast(iovlen);
                },
            },
        };
        const flags = std.posix.MSG.NOSIGNAL;
        return io_w.consume(std.posix.sendmsg(w.stream.handle, &msg, flags) catch |err| {
            w.err = err;
            return error.WriteFailed;
        });
    }
};

const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
const Writer = @import("writer.zig").Writer;
