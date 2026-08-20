const File = @This();

const std = @import("../std.zig");
const Io = std.Io;

handle: Handle,

pub const Handle = std.posix.fd_t;

pub const Reader = std.fs.File.Reader;
pub const Writer = std.fs.File.Writer;

fn legacy(dir: File) std.fs.File {
    return .{ .handle = dir.handle };
}

pub fn stdout() File {
    return .{ .handle = std.fs.File.stdout().handle };
}

pub fn stderr() File {
    return .{ .handle = std.fs.File.stderr().handle };
}

pub const StatError = error{
    SystemResources,
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to get its filestat information.
    AccessDenied,
    PermissionDenied,
    /// Attempted to stat a non-file stream.
    Streaming,
} || Io.Cancelable || Io.UnexpectedError;

pub const OpenError = std.fs.File.OpenError;

pub fn close(file: File, io: Io) void {
    _ = io;
    file.legacy().close();
}

pub const SeekError = error{
    Unseekable,
    /// The file descriptor does not hold the required rights to seek on it.
    AccessDenied,
} || Io.Cancelable || Io.UnexpectedError;

pub fn reader(file: File, io: Io, buffer: []u8) Reader {
    _ = io;
    return file.legacy().reader(buffer);
}

pub fn writer(file: File, io: Io, buffer: []u8) Writer {
    _ = io;
    return file.legacy().writer(buffer);
}
