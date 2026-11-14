/// MIT-SHM extension - https://www.x.org/releases/current/doc/xextproto/shm.html
///
/// Lets a client on the same machine as the X server share memory with it,
/// so image data can be handed to the server without copying it through the
/// socket. Only the fd-based requests (version 1.2+) are implemented here,
/// System V segments (Attach/CreatePixmap) are not.
const builtin = @import("builtin");
const std = @import("std");
const x11 = @import("../x.zig");

pub const name: x11.Slice(u16, [*]const u8) = .initComptime("MIT-SHM");

/// AttachFd requires version 1.2.
pub const attach_fd_version: Version = .{ .major = 1, .minor = 2 };

pub const Version = struct {
    major: u16,
    minor: u16,
    pub fn atLeast(v: Version, other: Version) bool {
        return v.major > other.major or (v.major == other.major and v.minor >= other.minor);
    }
};

/// An attached shared memory segment (SHMSEG). Allocate it from the client's
/// resource id range like any other resource.
pub const Seg = enum(u32) {
    none = 0,
    _,
    pub fn format(v: Seg, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .none => try writer.writeAll("none"),
            _ => |d| try writer.print("ShmSeg({d})", .{@backingInt(d)}),
        }
    }
};

pub const Opcode = enum(u8) {
    QueryVersion = 0,
    // Attach = 1, // System V segments, not implemented
    Detach = 2,
    PutImage = 3,
    // GetImage = 4,
    // CreatePixmap = 5,
    AttachFd = 6, // version 1.2
    // CreateSegment = 7, // version 1.2
};

/// Event codes, relative to the extension's event_base.
pub const EventCode = enum(u8) {
    Completion = 0,
};

pub const ImageFormat = enum(u8) {
    xy_bitmap = 0,
    xy_pixmap = 1,
    z_pixmap = 2,
};

/// Sent after the server has finished reading the segment for a PutImage
/// request that had `send_event` set. Once received, the client may write
/// to that part of the segment again.
pub const Completion = extern struct {
    kind: u8,
    unused: u8,
    sequence: u16,
    drawable: x11.Drawable,
    minor_event: u16,
    major_event: u8,
    unused2: u8,
    seg: Seg,
    offset: u32,
    unused3: [12]u8,

    comptime {
        std.debug.assert(@sizeOf(Completion) == 32);
    }

    /// Returns the Completion if the given extension event is one, null otherwise.
    pub fn fromEvent(event: *const x11.servermsg.ExtensionEvent, event_base: u8) ?Completion {
        if (event.kind != event_base + @backingInt(EventCode.Completion)) return null;
        return std.mem.bytesToValue(Completion, std.mem.asBytes(event));
    }
};

pub const request = struct {
    pub fn QueryVersion(sink: *x11.RequestSink, ext_opcode: u8) error{WriteFailed}!void {
        const msg_len =
            2 // extension and command opcodes
            + 2 // request length
        ;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @backingInt(Opcode.QueryVersion),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn Detach(sink: *x11.RequestSink, ext_opcode: u8, seg: Seg) error{WriteFailed}!void {
        const msg_len =
            2 // extension and command opcodes
            + 2 // request length
            + 4 // shmseg
        ;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @backingInt(Opcode.Detach),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, @backingInt(seg));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub const AttachFdError = error{
        WriteFailed,
        WouldBlock,
        BrokenPipe,
        ConnectionResetByPeer,
        SystemResources,
        /// A security module (e.g. AppArmor or SELinux) doesn't let the fd be
        /// passed to the server.
        AccessDenied,
        /// The process already has RLIMIT_NOFILE fds in flight over unix
        /// sockets (ETOOMANYREFS).
        ProcessFdQuotaExceeded,
    };

    /// Attaches the memory referred to by `fd` (e.g. a memfd) as `seg`.
    ///
    /// The fd is passed as SCM_RIGHTS ancillary data, so the connection must be
    /// a unix domain socket and `socket` must be the socket `sink.writer` writes to.
    /// This flushes `sink.writer` first so the request stays in order. The caller
    /// keeps ownership of `fd`, the server holds its own reference so it can be
    /// closed after this returns. Only implemented on Linux.
    ///
    /// An invalid `socket` or `fd`, or a `socket` that isn't a connected unix
    /// socket, is a bug in the caller: it panics in safe builds and is
    /// unreachable in unsafe ones. An errno sendmsg isn't documented to return
    /// panics in every build mode.
    pub fn AttachFd(
        sink: *x11.RequestSink,
        socket: std.posix.fd_t,
        ext_opcode: u8,
        seg: Seg,
        fd: std.posix.fd_t,
        read_only: bool,
    ) AttachFdError!void {
        if (builtin.os.tag != .linux) @compileError("shm.AttachFd is only implemented on Linux");
        const linux = std.os.linux;
        const msg_len =
            2 // extension and command opcodes
            + 2 // request length
            + 4 // shmseg
            + 1 // read only
            + 3 // unused
        ;
        var msg: [msg_len]u8 = undefined;
        msg[0] = ext_opcode;
        msg[1] = @backingInt(Opcode.AttachFd);
        std.mem.writeInt(u16, msg[2..4], msg_len >> 2, x11.native_endian);
        std.mem.writeInt(u32, msg[4..8], @backingInt(seg), x11.native_endian);
        msg[8] = @intFromBool(read_only);
        @memset(msg[9..12], 0);

        try sink.writer.flush();

        const Cmsg = extern struct {
            header: linux.cmsghdr,
            fd: std.posix.fd_t,
        };
        var cmsg: Cmsg = .{
            .header = .{
                .len = @offsetOf(Cmsg, "fd") + @sizeOf(std.posix.fd_t),
                .level = linux.SOL.SOCKET,
                .type = linux.SCM.RIGHTS,
            },
            .fd = fd,
        };
        const iov = [_]std.posix.iovec_const{.{ .base = &msg, .len = msg.len }};
        const msghdr: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = iov.len,
            .control = &cmsg,
            .controllen = @sizeOf(Cmsg),
            .flags = 0,
        };
        const sent: usize = while (true) {
            const rc = linux.sendmsg(socket, &msghdr, linux.MSG.NOSIGNAL);
            switch (linux.errno(rc)) {
                .SUCCESS => break rc,
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .PIPE, .NOTCONN => return error.BrokenPipe,
                .CONNRESET => return error.ConnectionResetByPeer,
                .NOBUFS, .NOMEM => return error.SystemResources,
                .ACCES, .PERM => return error.AccessDenied,
                .TOOMANYREFS => return error.ProcessFdQuotaExceeded,
                // `socket` or `fd` isn't valid, or `socket` isn't a connected unix socket
                .BADF, .NOTSOCK, .INVAL, .OPNOTSUPP, .DESTADDRREQ, .ISCONN, .FAULT => |e| {
                    if (std.debug.runtime_safety) std.debug.panic(
                        "MIT-SHM AttachFd: sendmsg misuse, errno={d}",
                        .{@backingInt(e)},
                    );
                    unreachable;
                },
                // the list above is wrong, the kernel is newer, or it has a bug
                else => |e| std.debug.panic("MIT-SHM AttachFd: sendmsg returned unexpected errno={d}", .{@backingInt(e)}),
            }
        };
        // the fd went with the first byte, any remainder is ordinary request data
        if (sent < msg.len) try sink.writer.writeAll(msg[sent..]);
        sink.sequence +%= 1;
    }

    pub const PutImageArgs = struct {
        drawable: x11.Drawable,
        gc_id: x11.GraphicsContext,
        /// Dimensions of the whole image stored in the segment at `offset`.
        total_width: u16,
        total_height: u16,
        /// The sub-rectangle of the stored image to draw.
        src_x: u16 = 0,
        src_y: u16 = 0,
        src_width: u16,
        src_height: u16,
        dst_x: i16,
        dst_y: i16,
        depth: x11.Depth,
        format: ImageFormat,
        /// Request a Completion event once the server is done reading the segment.
        send_event: bool,
        seg: Seg,
        /// Byte offset of the image within the segment.
        offset: u32,
    };

    pub fn PutImage(sink: *x11.RequestSink, ext_opcode: u8, args: PutImageArgs) error{WriteFailed}!void {
        const msg_len =
            2 // extension and command opcodes
            + 2 // request length
            + 4 // drawable
            + 4 // gc
            + 2 // total width
            + 2 // total height
            + 2 // src x
            + 2 // src y
            + 2 // src width
            + 2 // src height
            + 2 // dst x
            + 2 // dst y
            + 1 // depth
            + 1 // format
            + 1 // send event
            + 1 // unused
            + 4 // shmseg
            + 4 // offset
        ;
        var offset: usize = 0;
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            ext_opcode,
            @backingInt(Opcode.PutImage),
        });
        try x11.writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try x11.writeInt(sink.writer, &offset, u32, @backingInt(args.drawable));
        try x11.writeInt(sink.writer, &offset, u32, @backingInt(args.gc_id));
        try x11.writeInt(sink.writer, &offset, u16, args.total_width);
        try x11.writeInt(sink.writer, &offset, u16, args.total_height);
        try x11.writeInt(sink.writer, &offset, u16, args.src_x);
        try x11.writeInt(sink.writer, &offset, u16, args.src_y);
        try x11.writeInt(sink.writer, &offset, u16, args.src_width);
        try x11.writeInt(sink.writer, &offset, u16, args.src_height);
        try x11.writeInt(sink.writer, &offset, i16, args.dst_x);
        try x11.writeInt(sink.writer, &offset, i16, args.dst_y);
        try x11.writeAll(sink.writer, &offset, &[_]u8{
            args.depth.byte(),
            @backingInt(args.format),
            @intFromBool(args.send_event),
            0, // unused
        });
        try x11.writeInt(sink.writer, &offset, u32, @backingInt(args.seg));
        try x11.writeInt(sink.writer, &offset, u32, args.offset);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }
};
