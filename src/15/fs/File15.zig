const builtin = @import("builtin");
const Os = std.builtin.Os;
const native_os = builtin.os.tag;
const is_windows = native_os == .windows;

const File = @import("std").fs.File;
const std = @import("../std.zig");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const io = std.io;
const math = std.math;
const assert = @import("std").debug.assert;
const linux = std.os.linux;
const windows = std.os.windows;
const maxInt = std.math.maxInt;
const Alignment = std.mem.Alignment;

const Mode = posix.mode_t;
const INode = posix.ino_t;

const SetEndPosError = posix.TruncateError;
const SeekError = posix.SeekError;
const Stat = @import("std").fs.File.Stat;
const StatError = posix.FStatError;

const stat = @import("std").fs.File.stat;
const ReadError = posix.ReadError;

const WriteError = posix.WriteError;

pub const Reader = struct {
    file: File,
    err: ?ReadError = null,
    mode: Reader.Mode = .positional,
    /// Tracks the true seek position in the file. To obtain the logical
    /// position, use `logicalPos`.
    pos: u64 = 0,
    size: ?u64 = null,
    size_err: ?SizeError = null,
    seek_err: ?Reader.SeekError = null,
    interface: std.Io.Reader,

    pub const SizeError = std.os.windows.GetFileSizeError || StatError || error{
        /// Occurs if, for example, the file handle is a network socket and therefore does not have a size.
        Streaming,
    };

    pub const SeekError = File.SeekError || error{
        /// Seeking fell back to reading, and reached the end before the requested seek position.
        /// `pos` remains at the end of the file.
        EndOfStream,
        /// Seeking fell back to reading, which failed.
        ReadFailed,
    };

    pub const Mode = enum {
        streaming,
        positional,
        /// Avoid syscalls other than `read` and `readv`.
        streaming_reading,
        /// Avoid syscalls other than `pread` and `preadv`.
        positional_reading,
        /// Indicates reading cannot continue because of a seek failure.
        failure,

        pub fn toStreaming(m: @This()) @This() {
            return switch (m) {
                .positional, .streaming => .streaming,
                .positional_reading, .streaming_reading => .streaming_reading,
                .failure => .failure,
            };
        }

        pub fn toReading(m: @This()) @This() {
            return switch (m) {
                .positional, .positional_reading => .positional_reading,
                .streaming, .streaming_reading => .streaming_reading,
                .failure => .failure,
            };
        }
    };

    pub fn initInterface(buffer: []u8) std.Io.Reader {
        return .{
            .vtable = &.{
                .stream = Reader.stream,
                .discard = Reader.discard,
                .readVec = Reader.readVec,
            },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        };
    }

    pub fn init(file: File, buffer: []u8) Reader {
        return .{
            .file = file,
            .interface = initInterface(buffer),
        };
    }

    pub fn initSize(file: File, buffer: []u8, size: ?u64) Reader {
        return .{
            .file = file,
            .interface = initInterface(buffer),
            .size = size,
        };
    }

    /// Positional is more threadsafe, since the global seek position is not
    /// affected, but when such syscalls are not available, preemptively
    /// initializing in streaming mode skips a failed syscall.
    pub fn initStreaming(file: File, buffer: []u8) Reader {
        return .{
            .file = file,
            .interface = Reader.initInterface(buffer),
            .mode = .streaming,
            .seek_err = error.Unseekable,
            .size_err = error.Streaming,
        };
    }

    pub fn getSize(r: *Reader) SizeError!u64 {
        return r.size orelse {
            if (r.size_err) |err| return err;
            if (is_windows) {
                if (windows.GetFileSizeEx(r.file.handle)) |size| {
                    r.size = size;
                    return size;
                } else |err| {
                    r.size_err = err;
                    return err;
                }
            }
            if (posix.Stat == void) {
                r.size_err = error.Streaming;
                return error.Streaming;
            }
            if (stat(r.file)) |st| {
                if (st.kind == .file) {
                    r.size = st.size;
                    return st.size;
                } else {
                    r.mode = r.mode.toStreaming();
                    r.size_err = error.Streaming;
                    return error.Streaming;
                }
            } else |err| {
                r.size_err = err;
                return err;
            }
        };
    }

    pub fn seekBy(r: *Reader, offset: i64) Reader.SeekError!void {
        switch (r.mode) {
            .positional, .positional_reading => {
                setLogicalPos(r, @intCast(@as(i64, @intCast(logicalPos(r))) + offset));
            },
            .streaming, .streaming_reading => {
                if (posix.SEEK == void) {
                    r.seek_err = error.Unseekable;
                    return error.Unseekable;
                }
                const seek_err = r.seek_err orelse e: {
                    if (posix.lseek_CUR(r.file.handle, offset)) |_| {
                        setLogicalPos(r, @intCast(@as(i64, @intCast(logicalPos(r))) + offset));
                        return;
                    } else |err| {
                        r.seek_err = err;
                        break :e err;
                    }
                };
                var remaining = std.math.cast(u64, offset) orelse return seek_err;
                while (remaining > 0) {
                    remaining -= discard(&r.interface, .limited64(remaining)) catch |err| {
                        r.seek_err = err;
                        return err;
                    };
                }
                r.interface.seek = 0;
                r.interface.end = 0;
            },
            .failure => return r.seek_err.?,
        }
    }

    pub fn seekTo(r: *Reader, offset: u64) Reader.SeekError!void {
        switch (r.mode) {
            .positional, .positional_reading => {
                setLogicalPos(r, offset);
            },
            .streaming, .streaming_reading => {
                const logical_pos = logicalPos(r);
                if (offset >= logical_pos) return Reader.seekBy(r, @intCast(offset - logical_pos));
                if (r.seek_err) |err| return err;
                posix.lseek_SET(r.file.handle, offset) catch |err| {
                    r.seek_err = err;
                    return err;
                };
                setLogicalPos(r, offset);
            },
            .failure => return r.seek_err.?,
        }
    }

    pub fn logicalPos(r: *const Reader) u64 {
        return r.pos - r.interface.bufferedLen();
    }

    fn setLogicalPos(r: *Reader, offset: u64) void {
        const logical_pos = logicalPos(r);
        if (offset < logical_pos or offset >= r.pos) {
            r.interface.seek = 0;
            r.interface.end = 0;
            r.pos = offset;
        } else {
            const logical_delta: usize = @intCast(offset - logical_pos);
            r.interface.seek += logical_delta;
        }
    }

    /// Number of slices to store on the stack, when trying to send as many byte
    /// vectors through the underlying read calls as possible.
    const max_buffers_len = 16;

    fn stream(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        switch (r.mode) {
            .positional, .streaming => return w.sendFile(r, limit) catch |write_err| switch (write_err) {
                error.Unimplemented => {
                    r.mode = r.mode.toReading();
                    return 0;
                },
                else => |e| return e,
            },
            .positional_reading => {
                const dest = limit.slice(try w.writableSliceGreedy(1));
                var data: [1][]u8 = .{dest};
                const n = try readVecPositional(r, &data);
                w.advance(n);
                return n;
            },
            .streaming_reading => {
                const dest = limit.slice(try w.writableSliceGreedy(1));
                var data: [1][]u8 = .{dest};
                const n = try readVecStreaming(r, &data);
                w.advance(n);
                return n;
            },
            .failure => return error.ReadFailed,
        }
    }

    fn readVec(io_reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        switch (r.mode) {
            .positional, .positional_reading => return readVecPositional(r, data),
            .streaming, .streaming_reading => return readVecStreaming(r, data),
            .failure => return error.ReadFailed,
        }
    }

    fn readVecPositional(r: *Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const io_reader = &r.interface;
        if (is_windows) {
            // Unfortunately, `ReadFileScatter` cannot be used since it
            // requires page alignment.
            if (io_reader.seek == io_reader.end) {
                io_reader.seek = 0;
                io_reader.end = 0;
            }
            const first = data[0];
            if (first.len >= io_reader.buffer.len - io_reader.end) {
                return readPositional(r, first);
            } else {
                io_reader.end += try readPositional(r, io_reader.buffer[io_reader.end..]);
                return 0;
            }
        }
        var iovecs_buffer: [max_buffers_len]posix.iovec = undefined;
        const dest_n, const data_size = try io_reader.writableVectorPosix(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        assert(dest[0].len > 0);
        const n = posix.preadv(r.file.handle, dest, r.pos) catch |err| switch (err) {
            error.Unseekable => {
                r.mode = r.mode.toStreaming();
                const pos = r.pos;
                if (pos != 0) {
                    r.pos = 0;
                    r.seekBy(@intCast(pos)) catch {
                        r.mode = .failure;
                        return error.ReadFailed;
                    };
                }
                return 0;
            },
            else => |e| {
                r.err = e;
                return error.ReadFailed;
            },
        };
        if (n == 0) {
            r.size = r.pos;
            return error.EndOfStream;
        }
        r.pos += n;
        if (n > data_size) {
            io_reader.end += n - data_size;
            return data_size;
        }
        return n;
    }

    fn readVecStreaming(r: *Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const io_reader = &r.interface;
        if (is_windows) {
            // Unfortunately, `ReadFileScatter` cannot be used since it
            // requires page alignment.
            if (io_reader.seek == io_reader.end) {
                io_reader.seek = 0;
                io_reader.end = 0;
            }
            const first = data[0];
            if (first.len >= io_reader.buffer.len - io_reader.end) {
                return readStreaming(r, first);
            } else {
                io_reader.end += try readStreaming(r, io_reader.buffer[io_reader.end..]);
                return 0;
            }
        }
        var iovecs_buffer: [max_buffers_len]posix.iovec = undefined;
        const dest_n, const data_size = try io_reader.writableVectorPosix(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        assert(dest[0].len > 0);
        const n = posix.readv(r.file.handle, dest) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        if (n == 0) {
            r.size = r.pos;
            return error.EndOfStream;
        }
        r.pos += n;
        if (n > data_size) {
            io_reader.end += n - data_size;
            return data_size;
        }
        return n;
    }

    fn discard(io_reader: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));
        const file = r.file;
        const pos = r.pos;
        switch (r.mode) {
            .positional, .positional_reading => {
                const size = r.getSize() catch {
                    r.mode = r.mode.toStreaming();
                    return 0;
                };
                const delta = @min(@intFromEnum(limit), size - pos);
                r.pos = pos + delta;
                return delta;
            },
            .streaming, .streaming_reading => {
                // Unfortunately we can't seek forward without knowing the
                // size because the seek syscalls provided to us will not
                // return the true end position if a seek would exceed the
                // end.
                fallback: {
                    if (r.size_err == null and r.seek_err == null) break :fallback;
                    var trash_buffer: [128]u8 = undefined;
                    if (is_windows) {
                        const n = windows.ReadFile(file.handle, limit.slice(&trash_buffer), null) catch |err| {
                            r.err = err;
                            return error.ReadFailed;
                        };
                        if (n == 0) {
                            r.size = pos;
                            return error.EndOfStream;
                        }
                        r.pos = pos + n;
                        return n;
                    }
                    var iovecs: [max_buffers_len]std.posix.iovec = undefined;
                    var iovecs_i: usize = 0;
                    var remaining = @intFromEnum(limit);
                    while (remaining > 0 and iovecs_i < iovecs.len) {
                        iovecs[iovecs_i] = .{ .base = &trash_buffer, .len = @min(trash_buffer.len, remaining) };
                        remaining -= iovecs[iovecs_i].len;
                        iovecs_i += 1;
                    }
                    const n = posix.readv(file.handle, iovecs[0..iovecs_i]) catch |err| {
                        r.err = err;
                        return error.ReadFailed;
                    };
                    if (n == 0) {
                        r.size = pos;
                        return error.EndOfStream;
                    }
                    r.pos = pos + n;
                    return n;
                }
                const size = r.getSize() catch return 0;
                const n = @min(size - pos, maxInt(i64), @intFromEnum(limit));
                file.seekBy(n) catch |err| {
                    r.seek_err = err;
                    return 0;
                };
                r.pos = pos + n;
                return n;
            },
            .failure => return error.ReadFailed,
        }
    }

    fn readPositional(r: *Reader, dest: []u8) std.Io.Reader.Error!usize {
        const n = r.file.pread(dest, r.pos) catch |err| switch (err) {
            error.Unseekable => {
                r.mode = r.mode.toStreaming();
                const pos = r.pos;
                if (pos != 0) {
                    r.pos = 0;
                    r.seekBy(@intCast(pos)) catch {
                        r.mode = .failure;
                        return error.ReadFailed;
                    };
                }
                return 0;
            },
            else => |e| {
                r.err = e;
                return error.ReadFailed;
            },
        };
        if (n == 0) {
            r.size = r.pos;
            return error.EndOfStream;
        }
        r.pos += n;
        return n;
    }

    fn readStreaming(r: *Reader, dest: []u8) std.Io.Reader.Error!usize {
        const n = r.file.read(dest) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        if (n == 0) {
            r.size = r.pos;
            return error.EndOfStream;
        }
        r.pos += n;
        return n;
    }

    pub fn atEnd(r: *Reader) bool {
        // Even if stat fails, size is set when end is encountered.
        const size = r.size orelse return false;
        return size - r.pos == 0;
    }
};

pub const Writer = struct {
    file: File,
    err: ?WriteError = null,
    mode: Writer.Mode = .positional,
    /// Tracks the true seek position in the file. To obtain the logical
    /// position, add the buffer size to this value.
    pos: u64 = 0,
    sendfile_err: ?SendfileError = null,
    copy_file_range_err: ?CopyFileRangeError = null,
    fcopyfile_err: ?FcopyfileError = null,
    seek_err: ?SeekError = null,
    interface: std.Io.Writer,

    pub const Mode = Reader.Mode;

    pub const SendfileError = error{
        UnsupportedOperation,
        SystemResources,
        InputOutput,
        BrokenPipe,
        WouldBlock,
        Unexpected,
    };

    // pub const CopyFileRangeError = std.os.freebsd.CopyFileRangeError || std.os.linux.wrapped.CopyFileRangeError;
    pub const CopyFileRangeError = std.os.linux.wrapped.CopyFileRangeError;

    pub const FcopyfileError = error{
        OperationNotSupported,
        OutOfMemory,
        Unexpected,
    };

    /// Number of slices to store on the stack, when trying to send as many byte
    /// vectors through the underlying write calls as possible.
    const max_buffers_len = 16;

    pub fn init(file: File, buffer: []u8) Writer {
        return .{
            .file = file,
            .interface = initInterface(buffer),
            .mode = .positional,
        };
    }

    /// Positional is more threadsafe, since the global seek position is not
    /// affected, but when such syscalls are not available, preemptively
    /// initializing in streaming mode will skip a failed syscall.
    pub fn initStreaming(file: File, buffer: []u8) Writer {
        return .{
            .file = file,
            .interface = initInterface(buffer),
            .mode = .streaming,
        };
    }

    pub fn initInterface(buffer: []u8) std.Io.Writer {
        return .{
            .vtable = &.{
                .drain = drain,
                .sendFile = switch (builtin.zig_backend) {
                    else => sendFile,
                    .stage2_aarch64 => std.Io.Writer.unimplementedSendFile,
                },
            },
            .buffer = buffer,
        };
    }

    pub fn moveToReader(w: *Writer) Reader {
        defer w.* = undefined;
        return .{
            .file = w.file,
            .mode = w.mode,
            .pos = w.pos,
            .interface = Reader.initInterface(w.interface.buffer),
            .seek_err = w.seek_err,
        };
    }

    pub fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
        const handle = w.file.handle;
        const buffered = io_w.buffered();
        if (is_windows) switch (w.mode) {
            .positional, .positional_reading => {
                if (buffered.len != 0) {
                    const n = windows.WriteFile(handle, buffered, w.pos) catch |err| {
                        w.err = err;
                        return error.WriteFailed;
                    };
                    w.pos += n;
                    return io_w.consume(n);
                }
                for (data[0 .. data.len - 1]) |buf| {
                    if (buf.len == 0) continue;
                    const n = windows.WriteFile(handle, buf, w.pos) catch |err| {
                        w.err = err;
                        return error.WriteFailed;
                    };
                    w.pos += n;
                    return io_w.consume(n);
                }
                const pattern = data[data.len - 1];
                if (pattern.len == 0 or splat == 0) return 0;
                const n = windows.WriteFile(handle, pattern, w.pos) catch |err| {
                    w.err = err;
                    return error.WriteFailed;
                };
                w.pos += n;
                return io_w.consume(n);
            },
            .streaming, .streaming_reading => {
                if (buffered.len != 0) {
                    const n = windows.WriteFile(handle, buffered, null) catch |err| {
                        w.err = err;
                        return error.WriteFailed;
                    };
                    w.pos += n;
                    return io_w.consume(n);
                }
                for (data[0 .. data.len - 1]) |buf| {
                    if (buf.len == 0) continue;
                    const n = windows.WriteFile(handle, buf, null) catch |err| {
                        w.err = err;
                        return error.WriteFailed;
                    };
                    w.pos += n;
                    return io_w.consume(n);
                }
                const pattern = data[data.len - 1];
                if (pattern.len == 0 or splat == 0) return 0;
                const n = windows.WriteFile(handle, pattern, null) catch |err| {
                    w.err = err;
                    return error.WriteFailed;
                };
                w.pos += n;
                return io_w.consume(n);
            },
            .failure => return error.WriteFailed,
        };
        var iovecs: [max_buffers_len]std.posix.iovec_const = undefined;
        var len: usize = 0;
        if (buffered.len > 0) {
            iovecs[len] = .{ .base = buffered.ptr, .len = buffered.len };
            len += 1;
        }
        for (data[0 .. data.len - 1]) |d| {
            if (d.len == 0) continue;
            iovecs[len] = .{ .base = d.ptr, .len = d.len };
            len += 1;
            if (iovecs.len - len == 0) break;
        }
        const pattern = data[data.len - 1];
        if (iovecs.len - len != 0) switch (splat) {
            0 => {},
            1 => if (pattern.len != 0) {
                iovecs[len] = .{ .base = pattern.ptr, .len = pattern.len };
                len += 1;
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
                    iovecs[len] = .{ .base = buf.ptr, .len = buf.len };
                    len += 1;
                    var remaining_splat = splat - buf.len;
                    while (remaining_splat > splat_buffer.len and iovecs.len - len != 0) {
                        assert(buf.len == splat_buffer.len);
                        iovecs[len] = .{ .base = splat_buffer.ptr, .len = splat_buffer.len };
                        len += 1;
                        remaining_splat -= splat_buffer.len;
                    }
                    if (remaining_splat > 0 and iovecs.len - len != 0) {
                        iovecs[len] = .{ .base = splat_buffer.ptr, .len = remaining_splat };
                        len += 1;
                    }
                },
                else => for (0..splat) |_| {
                    iovecs[len] = .{ .base = pattern.ptr, .len = pattern.len };
                    len += 1;
                    if (iovecs.len - len == 0) break;
                },
            },
        };
        if (len == 0) return 0;
        switch (w.mode) {
            .positional, .positional_reading => {
                const n = std.posix.pwritev(handle, iovecs[0..len], w.pos) catch |err| switch (err) {
                    error.Unseekable => {
                        w.mode = w.mode.toStreaming();
                        const pos = w.pos;
                        if (pos != 0) {
                            w.pos = 0;
                            w.seekTo(@intCast(pos)) catch {
                                w.mode = .failure;
                                return error.WriteFailed;
                            };
                        }
                        return 0;
                    },
                    else => |e| {
                        w.err = e;
                        return error.WriteFailed;
                    },
                };
                w.pos += n;
                return io_w.consume(n);
            },
            .streaming, .streaming_reading => {
                const n = std.posix.writev(handle, iovecs[0..len]) catch |err| {
                    w.err = err;
                    return error.WriteFailed;
                };
                w.pos += n;
                return io_w.consume(n);
            },
            .failure => return error.WriteFailed,
        }
    }

    pub fn sendFile(
        io_w: *std.Io.Writer,
        file_reader: *Reader,
        limit: std.Io.Limit,
    ) std.Io.Writer.FileError!usize {
        const reader_buffered = file_reader.interface.buffered();
        if (reader_buffered.len >= @intFromEnum(limit))
            return sendFileBuffered(io_w, file_reader, limit.slice(reader_buffered));
        const writer_buffered = io_w.buffered();
        const file_limit = @intFromEnum(limit) - reader_buffered.len;
        const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
        const out_fd = w.file.handle;
        const in_fd = file_reader.file.handle;

        if (file_reader.size) |size| {
            if (size - file_reader.pos == 0) {
                if (reader_buffered.len != 0) {
                    return sendFileBuffered(io_w, file_reader, reader_buffered);
                } else {
                    return error.EndOfStream;
                }
            }
        }

        if (native_os == .freebsd and w.mode == .streaming) sf: {
            // Try using sendfile on FreeBSD.
            if (w.sendfile_err != null) break :sf;
            const offset = std.math.cast(std.c.off_t, file_reader.pos) orelse break :sf;
            var hdtr_data: std.c.sf_hdtr = undefined;
            var headers: [2]posix.iovec_const = undefined;
            var headers_i: u8 = 0;
            if (writer_buffered.len != 0) {
                headers[headers_i] = .{ .base = writer_buffered.ptr, .len = writer_buffered.len };
                headers_i += 1;
            }
            if (reader_buffered.len != 0) {
                headers[headers_i] = .{ .base = reader_buffered.ptr, .len = reader_buffered.len };
                headers_i += 1;
            }
            const hdtr: ?*std.c.sf_hdtr = if (headers_i == 0) null else b: {
                hdtr_data = .{
                    .headers = &headers,
                    .hdr_cnt = headers_i,
                    .trailers = null,
                    .trl_cnt = 0,
                };
                break :b &hdtr_data;
            };
            var sbytes: std.c.off_t = undefined;
            const nbytes: usize = @min(file_limit, maxInt(usize));
            const flags = 0;
            switch (posix.errno(std.c.sendfile(in_fd, out_fd, offset, nbytes, hdtr, &sbytes, flags))) {
                .SUCCESS, .INTR => {},
                .INVAL, .OPNOTSUPP, .NOTSOCK, .NOSYS => w.sendfile_err = error.UnsupportedOperation,
                .BADF => if (builtin.mode == .Debug) @panic("race condition") else {
                    w.sendfile_err = error.Unexpected;
                },
                .FAULT => if (builtin.mode == .Debug) @panic("segmentation fault") else {
                    w.sendfile_err = error.Unexpected;
                },
                .NOTCONN => w.sendfile_err = error.BrokenPipe,
                .AGAIN, .BUSY => if (sbytes == 0) {
                    w.sendfile_err = error.WouldBlock;
                },
                .IO => w.sendfile_err = error.InputOutput,
                .PIPE => w.sendfile_err = error.BrokenPipe,
                .NOBUFS => w.sendfile_err = error.SystemResources,
                else => |err| w.sendfile_err = posix.unexpectedErrno(err),
            }
            if (w.sendfile_err != null) {
                // Give calling code chance to observe the error before trying
                // something else.
                return 0;
            }
            if (sbytes == 0) {
                file_reader.size = file_reader.pos;
                return error.EndOfStream;
            }
            const consumed = io_w.consume(@intCast(sbytes));
            file_reader.seekBy(@intCast(consumed)) catch return error.ReadFailed;
            return consumed;
        }

        if (native_os.isDarwin() and w.mode == .streaming) sf: {
            // Try using sendfile on macOS.
            if (w.sendfile_err != null) break :sf;
            const offset = std.math.cast(std.c.off_t, file_reader.pos) orelse break :sf;
            var hdtr_data: std.c.sf_hdtr = undefined;
            var headers: [2]posix.iovec_const = undefined;
            var headers_i: u8 = 0;
            if (writer_buffered.len != 0) {
                headers[headers_i] = .{ .base = writer_buffered.ptr, .len = writer_buffered.len };
                headers_i += 1;
            }
            if (reader_buffered.len != 0) {
                headers[headers_i] = .{ .base = reader_buffered.ptr, .len = reader_buffered.len };
                headers_i += 1;
            }
            const hdtr: ?*std.c.sf_hdtr = if (headers_i == 0) null else b: {
                hdtr_data = .{
                    .headers = &headers,
                    .hdr_cnt = headers_i,
                    .trailers = null,
                    .trl_cnt = 0,
                };
                break :b &hdtr_data;
            };
            const max_count = maxInt(i32); // Avoid EINVAL.
            var len: std.c.off_t = @min(file_limit, max_count);
            const flags = 0;
            switch (posix.errno(std.c.sendfile(in_fd, out_fd, offset, &len, hdtr, flags))) {
                .SUCCESS, .INTR => {},
                .OPNOTSUPP, .NOTSOCK, .NOSYS => w.sendfile_err = error.UnsupportedOperation,
                .BADF => if (builtin.mode == .Debug) @panic("race condition") else {
                    w.sendfile_err = error.Unexpected;
                },
                .FAULT => if (builtin.mode == .Debug) @panic("segmentation fault") else {
                    w.sendfile_err = error.Unexpected;
                },
                .INVAL => if (builtin.mode == .Debug) @panic("invalid API usage") else {
                    w.sendfile_err = error.Unexpected;
                },
                .NOTCONN => w.sendfile_err = error.BrokenPipe,
                .AGAIN => if (len == 0) {
                    w.sendfile_err = error.WouldBlock;
                },
                .IO => w.sendfile_err = error.InputOutput,
                .PIPE => w.sendfile_err = error.BrokenPipe,
                else => |err| w.sendfile_err = posix.unexpectedErrno(err),
            }
            if (w.sendfile_err != null) {
                // Give calling code chance to observe the error before trying
                // something else.
                return 0;
            }
            if (len == 0) {
                file_reader.size = file_reader.pos;
                return error.EndOfStream;
            }
            const consumed = io_w.consume(@bitCast(len));
            file_reader.seekBy(@intCast(consumed)) catch return error.ReadFailed;
            return consumed;
        }

        if (native_os == .linux and w.mode == .streaming) sf: {
            // Try using sendfile on Linux.
            if (w.sendfile_err != null) break :sf;
            // Linux sendfile does not support headers.
            if (writer_buffered.len != 0 or reader_buffered.len != 0)
                return sendFileBuffered(io_w, file_reader, reader_buffered);
            const max_count = 0x7ffff000; // Avoid EINVAL.
            var off: std.os.linux.off_t = undefined;
            const off_ptr: ?*std.os.linux.off_t, const count: usize = switch (file_reader.mode) {
                .positional => o: {
                    const size = file_reader.getSize() catch return 0;
                    off = std.math.cast(std.os.linux.off_t, file_reader.pos) orelse return error.ReadFailed;
                    break :o .{ &off, @min(@intFromEnum(limit), size - file_reader.pos, max_count) };
                },
                .streaming => .{ null, limit.minInt(max_count) },
                .streaming_reading, .positional_reading => break :sf,
                .failure => return error.ReadFailed,
            };
            const n = std.os.linux.wrapped.sendfile(out_fd, in_fd, off_ptr, count) catch |err| switch (err) {
                error.Unseekable => {
                    file_reader.mode = file_reader.mode.toStreaming();
                    const pos = file_reader.pos;
                    if (pos != 0) {
                        file_reader.pos = 0;
                        file_reader.seekBy(@intCast(pos)) catch {
                            file_reader.mode = .failure;
                            return error.ReadFailed;
                        };
                    }
                    return 0;
                },
                else => |e| {
                    w.sendfile_err = e;
                    return 0;
                },
            };
            if (n == 0) {
                file_reader.size = file_reader.pos;
                return error.EndOfStream;
            }
            file_reader.pos += n;
            w.pos += n;
            return n;
        }

        const copy_file_range = switch (native_os) {
            .freebsd => std.os.freebsd.copy_file_range,
            .linux => std.os.linux.wrapped.copy_file_range,
            else => {},
        };
        if (@TypeOf(copy_file_range) != void) cfr: {
            if (w.copy_file_range_err != null) break :cfr;
            if (writer_buffered.len != 0 or reader_buffered.len != 0)
                return sendFileBuffered(io_w, file_reader, reader_buffered);
            var off_in: i64 = undefined;
            var off_out: i64 = undefined;
            const off_in_ptr: ?*i64 = switch (file_reader.mode) {
                .positional_reading, .streaming_reading => return error.Unimplemented,
                .positional => p: {
                    off_in = @intCast(file_reader.pos);
                    break :p &off_in;
                },
                .streaming => null,
                .failure => return error.WriteFailed,
            };
            const off_out_ptr: ?*i64 = switch (w.mode) {
                .positional_reading, .streaming_reading => return error.Unimplemented,
                .positional => p: {
                    off_out = @intCast(w.pos);
                    break :p &off_out;
                },
                .streaming => null,
                .failure => return error.WriteFailed,
            };
            const n = copy_file_range(in_fd, off_in_ptr, out_fd, off_out_ptr, @intFromEnum(limit), 0) catch |err| {
                w.copy_file_range_err = err;
                return 0;
            };
            if (n == 0) {
                file_reader.size = file_reader.pos;
                return error.EndOfStream;
            }
            file_reader.pos += n;
            w.pos += n;
            return n;
        }

        if (builtin.os.tag.isDarwin()) fcf: {
            if (w.fcopyfile_err != null) break :fcf;
            if (file_reader.pos != 0) break :fcf;
            if (w.pos != 0) break :fcf;
            if (limit != .unlimited) break :fcf;
            const size = file_reader.getSize() catch break :fcf;
            if (writer_buffered.len != 0 or reader_buffered.len != 0)
                return sendFileBuffered(io_w, file_reader, reader_buffered);
            const rc = std.c.fcopyfile(in_fd, out_fd, null, .{ .DATA = true });
            switch (posix.errno(rc)) {
                .SUCCESS => {},
                .INVAL => if (builtin.mode == .Debug) @panic("invalid API usage") else {
                    w.fcopyfile_err = error.Unexpected;
                    return 0;
                },
                .NOMEM => {
                    w.fcopyfile_err = error.OutOfMemory;
                    return 0;
                },
                .OPNOTSUPP => {
                    w.fcopyfile_err = error.OperationNotSupported;
                    return 0;
                },
                else => |err| {
                    w.fcopyfile_err = posix.unexpectedErrno(err);
                    return 0;
                },
            }
            file_reader.pos = size;
            w.pos = size;
            return size;
        }

        return error.Unimplemented;
    }

    fn sendFileBuffered(
        io_w: *std.Io.Writer,
        file_reader: *Reader,
        reader_buffered: []const u8,
    ) std.Io.Writer.FileError!usize {
        const n = try drain(io_w, &.{reader_buffered}, 1);
        file_reader.seekBy(@intCast(n)) catch return error.ReadFailed;
        return n;
    }

    pub fn seekTo(w: *Writer, offset: u64) SeekError!void {
        switch (w.mode) {
            .positional, .positional_reading => {
                w.pos = offset;
            },
            .streaming, .streaming_reading => {
                if (w.seek_err) |err| return err;
                posix.lseek_SET(w.file.handle, offset) catch |err| {
                    w.seek_err = err;
                    return err;
                };
                w.pos = offset;
            },
            .failure => return w.seek_err.?,
        }
    }

    pub const EndError = SetEndPosError || std.Io.Writer.Error;

    /// Flushes any buffered data and sets the end position of the file.
    ///
    /// If not overwriting existing contents, then calling `interface.flush`
    /// directly is sufficient.
    ///
    /// Flush failure is handled by setting `err` so that it can be handled
    /// along with other write failures.
    pub fn end(w: *Writer) EndError!void {
        try w.interface.flush();
        switch (w.mode) {
            .positional,
            .positional_reading,
            => w.file.setEndPos(w.pos) catch |err| switch (err) {
                error.NonResizable => return,
                else => |e| return e,
            },

            .streaming,
            .streaming_reading,
            .failure,
            => {},
        }
    }
};
