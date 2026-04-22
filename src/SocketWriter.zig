const SocketWriter = @This();

io: Io,
interface: Io.Writer,
socket: Socket,
err: ?Error = null,
write_file_err: ?WriteFileError = null,

pub const Error = error{
    /// Another TCP Fast Open is already in progress.
    FastOpenAlreadyInProgress,
    /// Network session was unexpectedly closed by recipient.
    ConnectionResetByPeer,
    /// The output queue for a network interface was full. This generally indicates that the
    /// interface has stopped sending, but may be caused by transient congestion. (Normally,
    /// this does not occur in Linux. Packets are just silently dropped when a device queue
    /// overflows.)
    ///
    /// This is also caused when there is not enough kernel memory available.
    SystemResources,
    /// No route to network.
    NetworkUnreachable,
    /// Network reached but no route to host.
    HostUnreachable,
    /// The local network interface used to reach the destination is down.
    NetworkDown,
    /// The destination address is not listening.
    ConnectionRefused,
    /// The passed address didn't have the correct address family in its sa_family field.
    AddressFamilyUnsupported,
    /// Local end has been shut down on a connection-oriented socket, or
    /// the socket was never connected.
    SocketUnconnected,
    SocketNotBound,
} || Io.UnexpectedError || Io.Cancelable;

pub const WriteFileError = error{
    NetworkDown,
} || Io.Cancelable || Io.UnexpectedError;

pub fn init(socket: Socket, io: Io, buffer: []u8) SocketWriter {
    return .{
        .io = io,
        .socket = socket,
        .interface = .{
            .vtable = &.{
                .drain = drain,
                .sendFile = sendFile,
            },
            .buffer = buffer,
        },
    };
}

fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
    const w: *SocketWriter = @alignCast(@fieldParentPtr("interface", io_w));
    const io = w.io;
    const buffered = io_w.buffered();
    const n = io.vtable.netWrite(io.userdata, w.socket, buffered, data, splat) catch |err| {
        w.err = err;
        return error.WriteFailed;
    };
    return io_w.consume(n);
}

fn sendFile(io_w: *Io.Writer, file_reader: *SendFileReader, limit: Io.Limit) Io.Writer.FileError!usize {
    _ = io_w;
    _ = file_reader;
    _ = limit;
    return error.Unimplemented; // TODO
}

pub const Socket = if (zig_atleast_16) std.Io.net.Socket.Handle else std.net.Stream.Handle;

pub const zig_atleast_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

const std = @import("std");
const std16 = if (zig_atleast_16) std else @import("std16");

const Io = std16.Io;
const SendFileReader = if (zig_atleast_16) std.Io.File.Reader else std.fs.File.Reader;
