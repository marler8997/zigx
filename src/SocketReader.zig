const SocketReader = @This();

io: Io,
interface: Io.Reader,
socket: Socket,
err: ?Error,

const max_iovecs_len = 8;

pub const Error = error{
    SystemResources,
    ConnectionResetByPeer,
    Timeout,
    SocketUnconnected,
    /// The file descriptor does not hold the required rights to read
    /// from it.
    AccessDenied,
    NetworkDown,
} || Io.Cancelable || error{Unexpected};

pub fn init(socket: Socket, io: std16.Io, buffer: []u8) SocketReader {
    var result: SocketReader = .{
        .io = io,
        .interface = .{
            .vtable = &.{
                .stream = streamImpl,
                .readVec = readVec,
                .discard = discard,
            },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
        .socket = socket,
        .err = null,
    };
    if (!zig_atleast_16) {
        switch (builtin.os.tag) {
            .windows => {
                // workaround https://github.com/ziglang/zig/issues/25620
                if (!zig_atleast_15_3) {
                    result.interface.vtable = &@import("netpatch.zig").vtable;
                }
            },
            else => {},
        }
    }
    return result;
}

fn streamImpl(
    io_r: *std16.Io.Reader,
    io_w: *std16.Io.Writer,
    limit: std16.Io.Limit,
) std16.Io.Reader.StreamError!usize {
    const dest = limit.slice(try io_w.writableSliceGreedy(1));
    var data: [1][]u8 = .{dest};
    const n = try readVec(io_r, &data);
    io_w.advance(n);
    return n;
}

fn discard(io_r: *std16.Io.Reader, limit: std16.Io.Limit) std16.Io.Reader.Error!usize {
    const r: *SocketReader = @alignCast(@fieldParentPtr("interface", io_r));
    const io = r.io;
    var scratch: [4096]u8 = undefined;
    const dest_len = @min(scratch.len, @intFromEnum(limit));
    var data: [1][]u8 = .{scratch[0..dest_len]};
    const n = io.vtable.netRead(io.userdata, r.socket, &data) catch |err| {
        r.err = err;
        return error.ReadFailed;
    };
    if (n == 0) return error.EndOfStream;
    return n;
}

fn readVec(io_r: *std16.Io.Reader, data: [][]u8) std16.Io.Reader.Error!usize {
    const r: *SocketReader = @alignCast(@fieldParentPtr("interface", io_r));
    const io = r.io;
    var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
    const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
    const dest = iovecs_buffer[0..dest_n];
    std.debug.assert(dest[0].len > 0);
    const n = io.vtable.netRead(io.userdata, r.socket, dest) catch |err| {
        r.err = err;
        return error.ReadFailed;
    };
    if (n == 0) {
        return error.EndOfStream;
    }
    if (n > data_size) {
        r.interface.end += n - data_size;
        return data_size;
    }
    return n;
}

pub const Socket = if (zig_atleast_16) std.Io.net.Socket.Handle else std.net.Stream.Handle;

pub const zig_atleast_15_3 = builtin.zig_version.order(.{ .major = 0, .minor = 15, .patch = 3 }) != .lt;
pub const zig_atleast_16 = builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

const builtin = @import("builtin");
const std = @import("std");
const std16 = if (zig_atleast_16) std else @import("std16");

const Io = std16.Io;
