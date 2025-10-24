// //! Cross-platform networking abstractions.

const std = @import("std.zig");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;
const Io = std.Io;
const native_os = builtin.os.tag;
const windows = std.os.windows;
const File15 = std.fs.File15;

const Stream = @import("std").net.Stream;

pub const Stream15 = struct {
    pub const Handle = switch (native_os) {
        .windows => windows.ws2_32.SOCKET,
        else => posix.fd_t,
    };

    pub const ReadError = posix.ReadError || error{
        SocketNotBound,
        MessageTooBig,
        NetworkSubsystemFailed,
        ConnectionResetByPeer,
        SocketNotConnected,
    };

    pub const WriteError = posix.SendMsgError || error{
        ConnectionResetByPeer,
        SocketNotBound,
        MessageTooBig,
        NetworkSubsystemFailed,
        SystemResources,
        SocketNotConnected,
        Unexpected,
    };

    pub const Reader = switch (native_os) {
        .windows => struct {
            /// Use `interface` for portable code.
            interface_state: Io.Reader,
            /// Use `getStream` for portable code.
            net_stream: Stream,
            /// Use `getError` for portable code.
            error_state: ?Error,

            pub const Error = ReadError;

            pub fn getStream(r: *const Reader) Stream {
                return r.net_stream;
            }

            pub fn getError(r: *const Reader) ?Error {
                return r.error_state;
            }

            pub fn interface(r: *Reader) *Io.Reader {
                return &r.interface_state;
            }

            pub fn init(net_stream: Stream, buffer: []u8) Reader {
                return .{
                    .interface_state = .{
                        .vtable = &.{
                            .stream = stream,
                            .readVec = readVec,
                        },
                        .buffer = buffer,
                        .seek = 0,
                        .end = 0,
                    },
                    .net_stream = net_stream,
                    .error_state = null,
                };
            }

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
        },
        else => struct {
            /// Use `getStream`, `interface`, and `getError` for portable code.
            file_reader: File15.Reader,

            pub const Error = ReadError;

            pub fn interface(r: *Reader) *Io.Reader {
                return &r.file_reader.interface;
            }

            pub fn init(net_stream: Stream, buffer: []u8) Reader {
                return .{
                    .file_reader = .{
                        .interface = File15.Reader.initInterface(buffer),
                        .file = .{ .handle = net_stream.handle },
                        .mode = .streaming,
                        .seek_err = error.Unseekable,
                        .size_err = error.Streaming,
                    },
                };
            }

            pub fn getStream(r: *const Reader) Stream {
                return .{ .handle = r.file_reader.file.handle };
            }

            pub fn getError(r: *const Reader) ?Error {
                return r.file_reader.err;
            }
        },
    };

    pub const Writer = switch (native_os) {
        .windows => struct {
            /// This field is present on all systems.
            interface: Io.Writer,
            /// Use `getStream` for cross-platform support.
            stream: Stream,
            /// This field is present on all systems.
            err: ?Error = null,

            pub const Error = WriteError;

            pub fn init(stream: Stream, buffer: []u8) Writer {
                return .{
                    .stream = stream,
                    .interface = .{
                        .vtable = &.{ .drain = drain },
                        .buffer = buffer,
                    },
                };
            }

            pub fn getStream(w: *const Writer) Stream {
                return w.stream;
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

            fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
                const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
                const buffered = io_w.buffered();
                comptime assert(native_os == .windows);
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

            fn sendBufs(handle: Stream15.Handle, bufs: []windows.ws2_32.WSABUF) Error!u32 {
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
        },
        else => struct {
            /// This field is present on all systems.
            interface: Io.Writer,

            err: ?Error = null,
            file_writer: File15.Writer,

            pub const Error = WriteError;

            pub fn init(stream: Stream, buffer: []u8) Writer {
                return .{
                    .interface = .{
                        .vtable = &.{
                            .drain = drain,
                            .sendFile = sendFile,
                        },
                        .buffer = buffer,
                    },
                    .file_writer = .initStreaming(.{ .handle = stream.handle }, &.{}),
                };
            }

            pub fn getStream(w: *const Writer) Stream {
                return .{ .handle = w.file_writer.file.handle };
            }

            fn addBuf(v: []posix.iovec_const, i: *@FieldType(posix.msghdr_const, "iovlen"), bytes: []const u8) void {
                // OS checks ptr addr before length so zero length vectors must be omitted.
                if (bytes.len == 0) return;
                if (v.len - i.* == 0) return;
                v[i.*] = .{ .base = bytes.ptr, .len = bytes.len };
                i.* += 1;
            }

            fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
                const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
                const buffered = io_w.buffered();
                var iovecs: [max_buffers_len]posix.iovec_const = undefined;
                var msg: posix.msghdr_const = .{
                    .name = null,
                    .namelen = 0,
                    .iov = &iovecs,
                    .iovlen = 0,
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                };
                addBuf(&iovecs, &msg.iovlen, buffered);
                for (data[0 .. data.len - 1]) |bytes| addBuf(&iovecs, &msg.iovlen, bytes);
                const pattern = data[data.len - 1];
                if (iovecs.len - msg.iovlen != 0) switch (splat) {
                    0 => {},
                    1 => addBuf(&iovecs, &msg.iovlen, pattern),
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
                            addBuf(&iovecs, &msg.iovlen, buf);
                            var remaining_splat = splat - buf.len;
                            while (remaining_splat > splat_buffer.len and iovecs.len - msg.iovlen != 0) {
                                assert(buf.len == splat_buffer.len);
                                addBuf(&iovecs, &msg.iovlen, splat_buffer);
                                remaining_splat -= splat_buffer.len;
                            }
                            addBuf(&iovecs, &msg.iovlen, splat_buffer[0..remaining_splat]);
                        },
                        else => for (0..@min(splat, iovecs.len - msg.iovlen)) |_| {
                            addBuf(&iovecs, &msg.iovlen, pattern);
                        },
                    },
                };
                const flags = posix.MSG.NOSIGNAL;
                return io_w.consume(posix.sendmsg(w.file_writer.file.handle, &msg, flags) catch |err| {
                    w.err = err;
                    return error.WriteFailed;
                });
            }

            fn sendFile(io_w: *Io.Writer, file_reader: *File15.Reader, limit: Io.Limit) Io.Writer.FileError!usize {
                const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
                const n = try w.file_writer.interface.sendFileHeader(io_w.buffered(), file_reader, limit);
                return io_w.consume(n);
            }
        },
    };

    const max_buffers_len = 8;
};
