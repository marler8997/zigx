// Protocol Specification: https://www.x.org/docs/XProtocol/proto.pdf
//
// Request format
// -------------------------
// size | offset | description
// -------------------------
//  1   |    0   | major opcode
//  2   |    1   | total request length (including this header)
//  1   |    3   | data?
//
// Major Opcodes (128 - 255 reserved for extensions)
//
// Every request is implicitly assigned a sequence number, starting with 1, that is used in replies, errors and events
//
//
// Reply Format
// -------------------------
// size | offset | description
// -------------------------
//  4   |    0   | length not including first 32 bytes
//  2   |    4   | sequence number
//
//
// Event Format
// ...todo...
//

const std = @import("std");
const stdext = @import("stdext.zig");
const testing = std.testing;
const builtin = @import("builtin");
const posix = std.posix;
const windows = std.os.windows;

pub const ext = @import("x/ext.zig");
pub const inputext = @import("xinputext.zig");
pub const render = @import("render.zig");
pub const dbe = @import("xdbe.zig");
pub const shape = @import("xshape.zig");
pub const testext = @import("xtest.zig");

// Expose some helpful stuff
pub const BoundedArray = @import("bounded_array.zig").BoundedArray;
pub const MappedFile = @import("MappedFile.zig");
pub const charset = @import("charset.zig");
pub const Charset = charset.Charset;
pub const DoubleBuffer = @import("DoubleBuffer.zig");
pub const ContiguousReadBuffer = @import("ContiguousReadBuffer.zig");
pub const Slice = @import("x/slice.zig").Slice;
pub const SliceWithMaxLen = @import("x/slice.zig").SliceWithMaxLen;
pub const keymap = @import("keymap.zig");

pub const log = std.log.scoped(.x11);

pub const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;
pub const zig_atleast_15_3 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 3 }) != .lt;

const std15 = if (zig_atleast_15) std else @import("15/std.zig");
const Stream15 = if (zig_atleast_15) std.net.Stream else std15.net.Stream15;

pub const Writer = std15.Io.Writer;
pub const Reader = std15.Io.Reader;

pub const FileWriter = if (zig_atleast_15) std.fs.File.Writer else std15.fs.File15.Writer;
pub const Stream = std.net.Stream;
pub const SocketWriter = Stream15.Writer;
pub const SocketReader = Stream15.Reader;

pub fn stdout() std.fs.File {
    return if (zig_atleast_15) std.fs.File.stdout() else std.io.getStdOut();
}

pub fn socketWriter(stream: std.net.Stream, buffer: []u8) SocketWriter {
    if (zig_atleast_15) return stream.writer(buffer);
    return .init(stream, buffer);
}
pub fn socketReader(stream: std.net.Stream, buffer: []u8) SocketReader {
    if (zig_atleast_15) {
        switch (builtin.os.tag) {
            .windows => {
                // workaround https://github.com/ziglang/zig/issues/25620
                if (!zig_atleast_15_3) {
                    var reader = stream.reader(buffer);
                    reader.interface_state.vtable = &@import("netpatch.zig").vtable;
                    return reader;
                }
            },
            else => {},
        }
        return stream.reader(buffer);
    }
    return .init(stream, buffer);
}

pub const ProtocolError = error{
    /// Received data that violates the X11 protocol.
    X11Protocol,
};

const x_test = @import("test/x_test.zig");

test {
    // Perhaps we can use `std.testing.refAllDecls(@This());` instead but that requires
    // us to make the `x_test` import public.
    _ = x_test;
}

pub const TcpBasePort = 6000;

pub const max_port = 65535;
pub const max_display_num = max_port - TcpBasePort;

pub const BigEndian = 'B';
pub const LittleEndian = 'l';

const align4 = if (zig_atleast_15) .@"4" else 4;

pub fn Pad(comptime align_to: comptime_int) type {
    return switch (align_to) {
        4 => u2,
        8 => u3,
        else => @compileError("unsupported alignment"),
    };
}
/// Returns the padding needed to align the given len.
pub fn padLen(comptime align_to: comptime_int, len: Pad(align_to)) Pad(align_to) {
    return (0 -% len) & (align_to - 1);
}

// Returns the padding needed to align the given content len to 4-bytes.
// Note that it returns 0 for values already 4-byte aligned.
pub fn pad4Len(len: u2) u2 {
    return padLen(4, len);
}

test padLen {
    try std.testing.expectEqual(0, pad4Len(0));
    try std.testing.expectEqual(0, pad4Len(@truncate(4)));
    try std.testing.expectEqual(0, pad4Len(@truncate(8)));
    try std.testing.expectEqual(1, pad4Len(3)); // 7 -> 8
    try std.testing.expectEqual(2, pad4Len(2)); // 6 -> 8
    try std.testing.expectEqual(3, pad4Len(1)); // 1 -> 4
    try std.testing.expectEqual(2, pad4Len(@truncate(14)));
    try std.testing.expectEqual(3, pad4Len(@truncate(29)));

    inline for (&.{ 4, 8 }) |align_to| {
        for (0..10) |multiplier| {
            try std.testing.expectEqual(0, padLen(align_to, @truncate(multiplier * align_to)));
        }
        for (1..align_to + 1) |i| {
            try std.testing.expectEqual(align_to - i, padLen(align_to, @truncate(i)));
        }
    }
}

// TODO: is there another way to do this, is this somewhere in std?
pub fn optEql(optLeft: anytype, optRight: anytype) bool {
    if (optLeft) |left| {
        if (optRight) |right| {
            return left == right;
        } else return false;
    } else {
        if (optRight) |_| {
            return false;
        } else return true;
    }
}

pub const ParsedDisplay = struct {
    proto: ?Protocol,
    hostStart: u16,
    hostLimit: u16,
    display_num: DisplayNum,
    preferredScreen: ?u32,

    pub fn asFilePath(self: @This(), ptr: [*]const u8) ?[]const u8 {
        if (ptr[0] != '/') return null;
        return ptr[0..self.hostLimit];
    }
    pub fn hostSlice(self: @This(), ptr: [*]const u8) []const u8 {
        return ptr[self.hostStart..self.hostLimit];
    }
    pub fn equals(self: @This(), other: @This()) bool {
        return self.protoLen == other.protoLen and self.hostLimit == other.hostLimit and self.display_num == other.display_num and optEql(self.preferredScreen, other.preferredScreen);
    }
};

// I think I can get away without an allocator here and without
// freeing it and without error.
pub fn getDisplay() []const u8 {
    if (builtin.os.tag == .windows) {
        // we'll just make an allocator and never free it, no
        // big deal
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        return std.process.getEnvVarOwned(arena.allocator(), "DISPLAY") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return ":0",
            error.OutOfMemory => @panic("Out of memory"),
            error.InvalidWtf8 => @panic("Environment Variables are invalid wtf8?"),
        };
    }
    return posix.getenv("DISPLAY") orelse ":0";
}

pub const Protocol = enum {
    unix,
    tcp,
    inet,
    inet6,
    w32,
};

const proto_map = std.StaticStringMap(Protocol).initComptime(.{
    .{ "unix", .unix },
    .{ "tcp", .tcp },
    .{ "inet", .inet },
    .{ "inet6", .inet6 },
});
fn protoFromString(s: []const u8) error{UnknownProtocol}!Protocol {
    return proto_map.get(s) orelse error.UnknownProtocol;
}

pub const InvalidDisplayError = error{
    IsEmpty, // TODO: is this an error?
    UnknownProtocol,
    HasMultipleProtocols,
    IsTooLarge,
    NoDisplayNumber,
    BadDisplayNumber,
    BadScreenNumber,
};

// display format: [PROTOCOL/]HOST:DISPLAYNUM[.SCREEN]
// assumption: display.len > 0
pub fn parseDisplay(display: []const u8) InvalidDisplayError!ParsedDisplay {
    if (display.len == 0) return error.IsEmpty;
    if (display.len >= std.math.maxInt(u16))
        return error.IsTooLarge;

    // Xming (X server for windows) set this
    if (builtin.os.tag == .windows) {
        if (std.mem.eql(u8, display, "w32")) return .{
            .proto = .w32,
            .hostStart = 0,
            .hostLimit = undefined,
            .display_num = undefined,
            .preferredScreen = undefined,
        };
    }

    var parsed: ParsedDisplay = .{
        .proto = null,
        .hostStart = 0,
        .hostLimit = undefined,
        .display_num = undefined,
        .preferredScreen = undefined,
    };
    var index: u16 = 0;

    // TODO: if launchd supported, check for <path to socket>[.<screen>]

    while (true) {
        const c = display[index];
        if (c == ':') {
            break;
        }
        if (c == '/') {
            // I guess a DISPLAY that starts with '/' is a file path?
            // This is the case on my M1 macos laptop.
            if (index == 0) return .{
                .proto = null,
                .hostStart = 0,
                .hostLimit = @intCast(display.len),
                .display_num = .@"0",
                .preferredScreen = null,
            };
            if (parsed.proto) |_|
                return error.HasMultipleProtocols;
            parsed.proto = try protoFromString(display[0..index]);
            parsed.hostStart = index + 1;
        }
        index += 1;
        if (index == display.len)
            return error.NoDisplayNumber;
    }

    parsed.hostLimit = index;
    index += 1;
    if (index == display.len)
        return error.NoDisplayNumber;

    while (true) {
        const c = display[index];
        if (c == '.')
            break;
        index += 1;
        if (index == display.len)
            break;
    }

    //std.debug.warn("num '{}'\n", .{display[parsed.hostLimit + 1..index]});
    parsed.display_num = try DisplayNum.fromInt(std.fmt.parseInt(u16, display[parsed.hostLimit + 1 .. index], 10) catch
        return error.BadDisplayNumber);
    if (index == display.len) {
        parsed.preferredScreen = null;
    } else {
        index += 1;
        parsed.preferredScreen = std.fmt.parseInt(u32, display[index..], 10) catch
            return error.BadScreenNumber;
    }
    return parsed;
}

const ConnectError = error{
    UnknownHostName,
    ConnectionRefused,

    BadXauthEnv,
    XauthEnvFileNotFound,

    AccessDenied,
    SystemResources,
    InputOutput,
    SymLinkLoop,
    FileBusy,

    Unexpected,
};

// NOTE: this function takes the display/parsed display because the app
//       should know the display to provide to the user in case of an error
//       and should also have handled an invalid display error before
//       calling connect.
pub fn connect(display: []const u8, parsed: ParsedDisplay) !std.net.Stream {
    const optional_host: ?[]const u8 = blk: {
        const host_slice = parsed.hostSlice(display.ptr);
        break :blk if (host_slice.len == 0) null else host_slice;
    };
    return connectExplicit(optional_host, parsed.proto, parsed.display_num);
}

fn defaultTcpHost(optional_host: ?[]const u8) []const u8 {
    return if (optional_host) |host| host else "127.0.0.1";
}

pub const DisplayNum = enum(u16) {
    @"0" = 0,
    _,

    pub fn fromInt(int: u16) error{BadDisplayNumber}!DisplayNum {
        if (int > max_display_num) return error.BadDisplayNumber;
        return @enumFromInt(int);
    }

    pub fn asPort(self: DisplayNum) u16 {
        return TcpBasePort + @as(u16, @intFromEnum(self));
    }

    pub const format = if (zig_atleast_15) formatNew else formatLegacy;
    fn formatNew(self: DisplayNum, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{}", .{@intFromEnum(self)});
    }
    fn formatLegacy(
        self: DisplayNum,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}", .{@intFromEnum(self)});
    }
};

pub fn connectExplicit(optional_host: ?[]const u8, optional_protocol: ?Protocol, display_num: DisplayNum) ConnectError!std.net.Stream {
    if (optional_protocol) |proto| return switch (proto) {
        .unix => {
            if (optional_host) |_|
                @panic("TODO: DISPLAY is unix protocol with a host? Is this possible?");
            return connectUnixDisplayNum(display_num);
        },
        .tcp, .inet => connectTcp(defaultTcpHost(optional_host), display_num.asPort(), .{}),
        .inet6 => connectTcp(defaultTcpHost(optional_host), display_num.asPort(), .{ .inet6 = true }),
        .w32 => return tcpConnect(std.net.Address.parseIp4("127.0.0.1", TcpBasePort) catch unreachable),
    };

    if (optional_host) |host| {
        if (std.mem.eql(u8, host, "unix")) {
            // I don't want to carry this complexity if I don't have to, so for now I'll just make it an error
            std.debug.panic("host is 'unix' this might mean 'unix domain socket' but not sure, giving up for now", .{});
        }
        if (host[0] == '/')
            return connectUnixPath(host);
        return connectTcp(host, display_num.asPort(), .{});
    } else {
        if (builtin.os.tag == .windows) {
            std.log.err(
                "unsure how to connect to DISPLAY :{} on windows, how about specifing a hostname? i.e. localhost:{0}",
                .{@intFromEnum(display_num)},
            );
            std.process.exit(0xff);
        }
        // otherwise, strategy is to try connecting to a unix domain socket first
        // and fall back to tcp localhost otherwise
        return connectUnixDisplayNum(display_num) catch |err| switch (err) {
            else => |e| return e,
        };

        // TODO: uncomment this one we handle some of the errors from connectUnix
        //return connectTcp("localhost", try displayToTcpPort(display_num), .{});
    }
}

pub fn getAddressList(allocator: std.mem.Allocator, name: []const u8, port: u16) ConnectError!*std.net.AddressList {
    return std.net.getAddressList(allocator, name, port) catch |err| switch (err) {
        error.SystemResources,
        error.AccessDenied,
        => |e| return e,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        => return error.ConnectionRefused,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return error.SystemResources,
        // There's sooo many possible errors here it's silly to list them all, by default
        // we'll just panic and only when we know there's a reason to handle a specific
        // error we'll add it.
        else => |e| std.debug.panic("resolve DNS name '{s}' (port {}) failed with {s}", .{ name, port, @errorName(e) }),
    };
}

pub const ConnectTcpOptions = struct {
    inet6: bool = false,
};
pub fn connectTcp(name: []const u8, port: u16, options: ConnectTcpOptions) ConnectError!std.net.Stream {
    if (options.inet6) @panic("inet6 protocol not implemented");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const list = try getAddressList(arena.allocator(), name, port);
    defer list.deinit();
    for (list.addrs) |addr| {
        return tcpConnect(addr) catch |err| switch (err) {
            error.ConnectionRefused => continue,
            error.AccessDenied,
            error.SystemResources,
            => |e| return e,
        };
    }
    if (list.addrs.len == 0) return error.UnknownHostName;
    return error.ConnectionRefused;
}

const TcpConnectError = error{
    AccessDenied,
    ConnectionRefused,
    SystemResources,
};
fn tcpConnect(addr: std.net.Address) TcpConnectError!std.net.Stream {
    if (zig_atleast_15) return std.net.tcpConnectToAddress(addr) catch |err| switch (err) {
        error.ConnectionTimedOut,
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.ConnectionPending,
        error.ConnectionResetByPeer,
        => return error.ConnectionRefused,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return error.SystemResources,
        error.AccessDenied,
        error.PermissionDenied,
        => return error.AccessDenied,
        error.AddressInUse,
        error.AddressNotAvailable,
        error.WouldBlock,
        error.Unexpected,
        error.FileNotFound,
        error.AddressFamilyNotSupported,
        error.ProtocolFamilyNotAvailable,
        error.ProtocolNotSupported,
        error.SocketTypeNotSupported,
        => |e| std.debug.panic("TCP connect to {f} failed with {s}", .{ addr, @errorName(e) }),
    };
    return std.net.tcpConnectToAddress(addr) catch |err| switch (err) {
        error.ConnectionTimedOut,
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.ConnectionPending,
        error.ConnectionResetByPeer,
        => return error.ConnectionRefused,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return error.SystemResources,
        error.PermissionDenied => return error.AccessDenied,
        error.AddressInUse,
        error.AddressNotAvailable,
        error.WouldBlock,
        error.Unexpected,
        error.FileNotFound,
        error.AddressFamilyNotSupported,
        error.ProtocolFamilyNotAvailable,
        error.ProtocolNotSupported,
        error.SocketTypeNotSupported,
        => |e| std.debug.panic("TCP connect to {} failed with {s}", .{ addr, @errorName(e) }),
    };
}

pub fn disconnect(sock: posix.socket_t) void {
    posix.shutdown(sock, .both) catch {}; // ignore any error here
    posix.close(sock);
}

pub fn connectUnixDisplayNum(display_num: DisplayNum) ConnectError!std.net.Stream {
    const path_prefix = "/tmp/.X11-unix/X";
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    const path = std.fmt.bufPrintZ(
        &addr.path,
        "{s}{d}",
        .{ path_prefix, @intFromEnum(display_num) },
    ) catch unreachable;
    return connectUnixAddr(&addr, path.len);
}

pub fn connectUnixPath(socket_path: []const u8) ConnectError!std.net.Stream {
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    const path = std.fmt.bufPrintZ(
        &addr.path,
        "{s}",
        .{socket_path},
    ) catch unreachable;
    return connectUnixAddr(&addr, path.len);
}

pub fn connectUnixAddr(addr: *const posix.sockaddr.un, path_len: usize) ConnectError!std.net.Stream {
    const sock = if (zig_atleast_15) posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| switch (err) {
        error.SystemResources => |e| return e,
        error.AccessDenied => return error.AccessDenied,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return error.SystemResources,
        error.AddressFamilyNotSupported,
        error.ProtocolFamilyNotAvailable,
        error.ProtocolNotSupported,
        error.SocketTypeNotSupported,
        error.Unexpected,
        => |e| std.debug.panic("create socket failed with {s}", .{@errorName(e)}),
    } else posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| switch (err) {
        error.SystemResources => |e| return e,
        error.PermissionDenied => return error.AccessDenied,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return error.SystemResources,
        error.AddressFamilyNotSupported,
        error.ProtocolFamilyNotAvailable,
        error.ProtocolNotSupported,
        error.SocketTypeNotSupported,
        error.Unexpected,
        => |e| std.debug.panic("create socket failed with {s}", .{@errorName(e)}),
    };
    errdefer posix.close(sock);

    // TODO: should we set any socket options?
    const addr_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + path_len + 1);
    posix.connect(sock, @ptrCast(addr), addr_len) catch |err| switch (err) {
        // TODO: handle some of these errors and translate them so we can "fall back" to tcp
        //       for example, we might handle error.FileNotFound, but I would probably
        //       translate most errors to custom ones so we only fallback when we get
        //       an error on the "connect" call itself
        else => |e| {
            std.debug.panic(
                "TODO: connect unix to '{s}' failed with {s}, need to implement fallback to TCP",
                .{ std.mem.sliceTo(&addr.path, 0), @errorName(e) },
            );
            return e;
        },
    };
    return .{ .handle = sock };
}

pub fn ArrayPointer(comptime T: type) type {
    const err = "ArrayPointer not implemented for " ++ @typeName(T);
    switch (@typeInfo(T)) {
        .pointer => |info| {
            switch (info.size) {
                .one => {
                    switch (@typeInfo(info.child)) {
                        .Array => |array_info| {
                            return @Type(std.builtin.Type{ .pointer = .{
                                .size = .Many,
                                .is_const = true,
                                .is_volatile = false,
                                .alignment = @alignOf(array_info.child),
                                .address_space = info.address_space,
                                .child = array_info.child,
                                .is_allowzero = false,
                                .sentinel = array_info.sentinel,
                            } });
                        },
                        else => @compileError("here"),
                    }
                },
                .slice => {
                    return @Type(std.builtin.Type{ .pointer = .{
                        .size = .many,
                        .is_const = info.is_const,
                        .is_volatile = info.is_volatile,
                        .alignment = info.alignment,
                        .address_space = info.address_space,
                        .child = info.child,
                        .is_allowzero = info.is_allowzero,
                        .sentinel_ptr = info.sentinel_ptr,
                    } });
                },
                else => @compileError(err),
            }
        },
        else => @compileError(err),
    }
}

pub fn slice(comptime LenType: type, s: anytype) Slice(LenType, ArrayPointer(@TypeOf(s))) {
    switch (@typeInfo(@TypeOf(s))) {
        .pointer => |info| {
            switch (info.size) {
                .one => {
                    switch (@typeInfo(info.child)) {
                        .Array => |array_info| {
                            _ = array_info;
                            @compileError("here");
                            //                            return @Type(std.builtin.Type { .Pointer = .{
                            //                                .size = .Many,
                            //                                .is_const = true,
                            //                                .is_volatile = false,
                            //                                .alignment = @alignOf(array_info.child),
                            //                                .child = array_info.child,
                            //                                .is_allowzero = false,
                            //                                .sentinel = array_info.sentinel,
                            //                            }});
                        },
                        else => @compileError("here"),
                    }
                },
                .slice => return .{ .ptr = s.ptr, .len = @intCast(s.len) },
                else => @compileError("cannot slice"),
            }
        },
        else => @compileError("cannot slice"),
    }
}

pub const AuthFilename = struct {
    str: []const u8,
    owned: bool,

    pub fn deinit(self: AuthFilename, allocator: std.mem.Allocator) void {
        if (self.owned) {
            allocator.free(self.str);
        }
    }
};

pub const AuthFilenameError = error{
    BadXauthEnv,
    XauthEnvFileNotFound,

    OutOfMemory,

    AccessDenied,
    SystemResources,
    InputOutput,
    SymLinkLoop,
    FileBusy,

    Unexpected,
};

// returns the auth filename only if it exists.
pub fn getAuthFilename(allocator: std.mem.Allocator) AuthFilenameError!?AuthFilename {
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "XAUTHORITY")) |filename| {
            return .{ .str = filename, .owned = true };
        } else |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EnvironmentVariableNotFound => null,
            error.InvalidWtf8 => error.BadXauthEnv,
        };
    }

    if (posix.getenv("XAUTHORITY")) |xauth| return if (try xauthFileExists(std.fs.cwd(), xauth))
        .{ .str = xauth, .owned = false }
    else
        error.XauthEnvFileNotFound;

    if (posix.getenv("HOME")) |e| {
        const path = try std.fs.path.joinZ(allocator, &.{ e, ".Xauthority" });
        var free_path = true;
        defer if (free_path) allocator.free(path);
        if (try xauthFileExists(std.fs.cwd(), path)) {
            free_path = false;
            return .{ .str = path, .owned = true };
        }
    }
    return null;
}

fn xauthFileExists(dir: std.fs.Dir, sub_path: [*:0]const u8) !bool {
    if (dir.accessZ(sub_path, .{})) {
        return true;
    } else |err| if (zig_atleast_15) switch (err) {
        error.InvalidUtf8,
        error.NameTooLong,
        error.InvalidWtf8,
        error.BadPathName,
        => return error.BadXauthEnv,
        error.InputOutput,
        error.SystemResources,
        error.Unexpected,
        error.SymLinkLoop,
        error.FileBusy,
        => |e| return e,
        error.FileNotFound => return false,
        error.PermissionDenied,
        error.AccessDenied,
        => return error.AccessDenied,
        error.ReadOnlyFileSystem => unreachable,
    } else switch (err) {
        error.InvalidUtf8,
        error.NameTooLong,
        error.InvalidWtf8,
        error.BadPathName,
        => return error.BadXauthEnv,
        error.InputOutput,
        error.SystemResources,
        error.Unexpected,
        error.SymLinkLoop,
        error.FileBusy,
        => |e| return e,
        error.FileNotFound => return false,
        error.PermissionDenied => return error.AccessDenied,
        error.ReadOnlyFileSystem => unreachable,
    }
}

pub const AuthFamily = enum(u16) {
    inet = 0,
    unix = 256,
    wild = 65535,
    _,
    pub fn str(self: AuthFamily) ?[]const u8 {
        // TODO: can we use an inline switch?
        return switch (self) {
            .inet => "inet",
            .unix => "unix",
            .wild => "wild",
            else => null,
        };
    }
};

pub const AuthFilterReason = enum {
    address,
    display_num,
};

pub const max_sock_filter_addr = if (builtin.os.tag == .windows) 255 else posix.HOST_NAME_MAX;

pub const Addr = struct {
    family: AuthFamily,
    data: []const u8,

    pub const format = if (@import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) == .lt)
        formatLegacy
    else
        formatNew;
    fn formatLegacy(
        self: Addr,
        comptime fmt_spec: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt_spec;
        _ = options;
        const d = self.data;
        switch (self.family) {
            .inet => if (d.len == 4) {
                try writer.print("{}.{}.{}.{}", .{ d[0], d[1], d[2], d[3] });
            } else {
                // TODO: support ipv6?
                try writer.print("{}/inet", .{std.fmt.fmtSliceHexLower(d)});
            },
            .unix => try writer.print("{s}/unix", .{d}),
            .wild => try writer.print("*", .{}),
            else => |family| try writer.print("{}/{}", .{
                std.fmt.fmtSliceHexLower(d),
                family,
            }),
        }
    }
    fn formatNew(self: Addr, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const d = self.data;
        switch (self.family) {
            .inet => if (d.len == 4) {
                try writer.print("{}.{}.{}.{}", .{ d[0], d[1], d[2], d[3] });
            } else {
                // TODO: support ipv6?
                try writer.print("{x}/inet", .{d});
            },
            .unix => try writer.print("{s}/unix", .{d}),
            .wild => try writer.print("*", .{}),
            else => |family| try writer.print("{x}/{}", .{ d, family }),
        }
    }
};

pub const AuthFilter = struct {
    addr: Addr,
    display_num: ?DisplayNum,

    pub fn applySocket(self: *AuthFilter, sock: std.posix.socket_t, addr_buf: *[max_sock_filter_addr]u8) !void {
        var addr: posix.sockaddr.storage = undefined;
        var addrlen: posix.socklen_t = @sizeOf(@TypeOf(addr));
        try posix.getsockname(sock, @ptrCast(&addr), &addrlen);

        if (@hasDecl(posix.AF, "LOCAL")) {
            if (addr.family == posix.AF.LOCAL) {
                self.addr = .{
                    .family = .unix,
                    .data = try posix.gethostname(addr_buf),
                };
                return;
            }
        }
        switch (addr.family) {
            posix.AF.INET, posix.AF.INET6 => {
                //var remote_addr: posix.sockaddr = undefined;
                //var remote_addrlen: posix.socklen_t = 0;
                //try posix.getpeername(sock, &remote_addr, &remote_addrlen);
                return error.InternetSocketsNotImplemented;
            },
            else => {},
        }
    }

    pub fn isFiltered(
        self: AuthFilter,
        auth_mem: []const u8,
        entry: AuthIteratorEntry,
    ) ?AuthFilterReason {
        if (self.addr.family != .wild and entry.family != .wild) {
            if (entry.family != self.addr.family) return .address;
            if (!std.mem.eql(u8, self.addr.data, entry.addr(auth_mem))) return .address;
        }
        if (self.display_num) |num| {
            if (entry.display_num) |entry_num| {
                if (num != entry_num) return .display_num;
            }
        }
        return null;
    }
};

pub const AuthIteratorEntry = struct {
    family: AuthFamily,
    addr_start: usize,
    addr_end: usize,
    name_start: usize,
    display_num: ?DisplayNum,
    name_end: usize,
    data_end: usize,
    pub fn addr(self: AuthIteratorEntry, mem: []const u8) []const u8 {
        return mem[self.addr_start..self.addr_end];
    }
    pub fn name(self: AuthIteratorEntry, mem: []const u8) []const u8 {
        return mem[self.name_start..self.name_end];
    }
    pub fn data(self: AuthIteratorEntry, mem: []const u8) []const u8 {
        return mem[self.name_end + 2 .. self.data_end];
    }

    pub fn fmt(self: AuthIteratorEntry, mem: []const u8) Formatter {
        return .{ .mem = mem, .entry = self };
    }
    const Formatter = struct {
        mem: []const u8,
        entry: AuthIteratorEntry,
        pub const format = if (@import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) == .lt)
            formatLegacy
        else
            formatNew;
        fn formatLegacy(
            self: Formatter,
            comptime fmt_spec: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) @TypeOf(writer).Error!void {
            _ = fmt_spec;
            _ = options;

            const data_slice = self.entry.data(self.mem);
            try writer.print("address={} display={?} name='{}' data {} bytes: {}", .{
                Addr{
                    .family = self.entry.family,
                    .data = self.entry.addr(self.mem),
                },
                self.entry.display_num,
                std.zig.fmtEscapes(self.entry.name(self.mem)),
                data_slice.len,
                std.fmt.fmtSliceHexUpper(data_slice),
            });
        }
        fn formatNew(self: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const data_slice = self.entry.data(self.mem);
            try writer.print("address={f} display={?f} name='{f}' data {} bytes: {X}", .{
                Addr{
                    .family = self.entry.family,
                    .data = self.entry.addr(self.mem),
                },
                self.entry.display_num,
                std.zig.fmtString(self.entry.name(self.mem)),
                data_slice.len,
                data_slice,
            });
        }
    };
};

pub const AuthIterator = struct {
    mem: []const u8,
    idx: usize = 0,

    pub fn next(self: *AuthIterator) error{InvalidAuthFile}!?AuthIteratorEntry {
        if (self.idx == self.mem.len) return null;
        if (self.idx + 10 > self.mem.len) return error.InvalidAuthFile;

        // TODO: is big endian guaranteed?
        //       using a fixed endianness makes it look like these files are supposed
        //       to be compatible across machines, but then it's using c_short which isn't?
        const family = std.mem.readInt(u16, self.mem[self.idx..][0..2], .big);
        const addr_len = std.mem.readInt(u16, self.mem[self.idx + 2 ..][0..2], .big);
        const addr_start = self.idx + 4;
        const addr_end = addr_start + addr_len;
        if (addr_end + 2 > self.mem.len) return error.InvalidAuthFile;
        const num_len = std.mem.readInt(u16, self.mem[addr_end..][0..2], .big);
        const num_end = addr_end + 2 + num_len;
        if (num_end + 2 > self.mem.len) return error.InvalidAuthFile;
        const name_len = std.mem.readInt(u16, self.mem[num_end..][0..2], .big);
        const name_end = num_end + 2 + name_len;
        if (name_end + 2 > self.mem.len) return error.InvalidAuthFile;
        const data_len = std.mem.readInt(u16, self.mem[name_end..][0..2], .big);
        const data_end = name_end + 2 + data_len;
        if (data_end > self.mem.len) return error.InvalidAuthFile;

        const num_str = self.mem[addr_end + 2 .. num_end];
        const num: ?DisplayNum = blk: {
            if (num_str.len == 0) break :blk null;
            break :blk DisplayNum.fromInt(
                std.fmt.parseInt(u16, num_str, 10) catch return error.InvalidAuthFile,
            ) catch return error.InvalidAuthFile;
        };

        self.idx = data_end;
        return AuthIteratorEntry{
            .family = @enumFromInt(family),
            .addr_start = addr_start,
            .addr_end = addr_end,
            .display_num = num,
            .name_start = num_end + 2,
            .name_end = name_end,
            .data_end = data_end,
        };
    }
};

pub const RequestSink = struct {
    writer: *Writer,
    sequence: u16 = 0,

    pub fn CreateWindow(sink: *RequestSink, args: CreateWindowArgs, options: window.Options) Writer.Error!void {
        const msg = inspectCreateWindow(&options);
        var offset: usize = 0;

        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.create_window),
            args.depth,
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg.len >> 2));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(args.window_id));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(args.parent_window_id));
        try writeInt(sink.writer, &offset, i16, args.x);
        try writeInt(sink.writer, &offset, i16, args.y);
        try writeInt(sink.writer, &offset, u16, args.width);
        try writeInt(sink.writer, &offset, u16, args.height);
        try writeInt(sink.writer, &offset, u16, args.border_width);
        try writeInt(sink.writer, &offset, u16, @intFromEnum(args.class));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(args.visual_id));
        try writeInt(sink.writer, &offset, u32, @bitCast(msg.option_mask));
        inline for (std.meta.fields(window.Options)) |field| {
            if (!isDefaultValue(&options, field)) {
                try writeInt(sink.writer, &offset, u32, optionToU32(@field(options, field.name)));
            }
        }
        std.debug.assert(msg.len == offset);
        sink.sequence +%= 1;
    }

    pub fn ChangeWindowAttributes(sink: *RequestSink) Writer.Error!void {
        _ = sink;
        @panic("todo");
    }

    pub fn DestroyWindow(sink: *RequestSink, window_id: Window) Writer.Error!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.destroy_window),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(window_id));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn MapWindow(sink: *RequestSink, w: Window) Writer.Error!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.map_window),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(w));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn ConfigureWindow(
        sink: *RequestSink,
        window_id: Window,
        options: configure_window.Options,
    ) Writer.Error!void {
        const msg = inspectConfigureWindow(&options);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.configure_window),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg.len >> 2));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(window_id));
        try writeInt(sink.writer, &offset, u32, @bitCast(msg.option_mask));
        inline for (std.meta.fields(configure_window.Options)) |field| {
            if (!isDefaultValue(&options, field)) {
                try writeInt(sink.writer, &offset, u32, optionToU32(@field(options, field.name)));
            }
        }
        std.debug.assert(msg.len == offset);
        sink.sequence +%= 1;
    }

    fn inspectConfigureWindow(options: *const configure_window.Options) struct {
        len: u18,
        option_mask: configure_window.OptionMask,
    } {
        const non_option_len: u18 = configure_window.non_option_len;
        var len: u18 = non_option_len;
        var option_mask: configure_window.OptionMask = .{};
        inline for (std.meta.fields(configure_window.Options)) |field| {
            if (!isDefaultValue(options, field)) {
                @field(option_mask, field.name) = 1;
                len += 4;
            }
        }
        return .{ .len = len, .option_mask = option_mask };
    }
    pub fn QueryTree(sink: *RequestSink, window_id: Window) Writer.Error!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.query_tree),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(window_id));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn InternAtom(sink: *RequestSink, args: intern_atom.Args) Writer.Error!void {
        const msg_len = intern_atom.getLen(args.name.len);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.intern_atom),
            @intFromBool(args.only_if_exists),
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u16, args.name.len);
        try writeAll(sink.writer, &offset, &[_]u8{ 0, 0 }); // unused
        try writeAll(sink.writer, &offset, args.name.nativeSlice());
        try writePad4(sink.writer, &offset);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }
    pub fn ChangeProperty(
        sink: *RequestSink,
        mode: change_property.Mode,
        window_id: Window,
        property: Atom, // atom
        /// atom
        ///
        /// This value isn't interpreted by the X server. It's just passed back
        /// to the client application when using the `get_property` request.
        property_type: Atom,
        comptime T: type,
        values: Slice(u16, [*]const T),
    ) Writer.Error!void {
        const non_list_len =
            2 // opcode and mode
            + 2 // request length
            + 4 // window ID
            + 4 // property atom
            + 4 // type
            + 1 // value format
            + 3 // unused
            + 4 // value length
        ;
        const msg_len = non_list_len + std.mem.alignForward(u16, values.len * @sizeOf(T), 4);
        std.debug.assert(msg_len & 3 == 0);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.change_property),
            @intFromEnum(mode),
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(window_id));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(property));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(property_type));
        try writeAll(sink.writer, &offset, &[_]u8{
            @intCast(@sizeOf(T) * 8),
            0, // unused
            0, // unused
            0, // unused
        });
        try writeInt(sink.writer, &offset, u32, values.len);
        for (values.nativeSlice()) |value| {
            try writeInt(sink.writer, &offset, T, value);
        }
        try writePad4(sink.writer, &offset);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub fn GetProperty(
        sink: *RequestSink,
        window_id: Window,
        named: struct {
            property: Atom,
            /// Atom or AnyPropertyType (0)
            ///
            /// The expected type of the property. If the actual property is a different
            /// type, the return type is the actual type of the property, the format is the
            /// actual format of the property, the bytes-after is the length of the property
            /// in bytes (even if the format is 16 or 32), and the value is empty.
            type: Atom,
            /// The returned value starts at this offset in 4-byte units
            offset: u32,
            /// The number of 4-byte units to read from the offset
            len: u32,
            /// This delete argument is ignored if the `property` doesn't exist or if the
            /// `type` doesn't match
            delete: bool,
        },
    ) Writer.Error!void {
        const msg_len = 24;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.get_property),
            @intFromBool(named.delete),
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(window_id));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(named.property));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(named.type));
        try writeInt(sink.writer, &offset, u32, named.offset);
        try writeInt(sink.writer, &offset, u32, named.len);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn GrabPointer(sink: *RequestSink, named: struct {
        owner_events: bool,
        grab_window: Window,
        event_mask: PointerEventMask,
        pointer_mode: SyncMode,
        keyboard_mode: SyncMode,
        confine_to: Window,
        cursor: Cursor,
        time: Timestamp,
    }) Writer.Error!void {
        const msg_len = 24;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.grab_pointer),
            if (named.owner_events) 1 else 0,
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(named.grab_window));
        try writeInt(sink.writer, &offset, u16, @bitCast(named.event_mask));
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(named.pointer_mode),
            @intFromEnum(named.keyboard_mode),
        });
        try writeInt(sink.writer, &offset, u32, @intFromEnum(named.confine_to));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(named.cursor));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(named.time));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn UngrabPointer(sink: *RequestSink, time: Timestamp) Writer.Error!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.ungrab_pointer),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(time));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn WarpPointer(sink: *RequestSink, named: struct {
        src_window: Window,
        dst_window: Window,
        src_x: i16,
        src_y: i16,
        src_width: u16,
        src_height: u16,
        dst_x: i16,
        dst_y: i16,
    }) Writer.Error!void {
        const msg_len = 24;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.warp_pointer),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(named.src_window));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(named.dst_window));
        try writeInt(sink.writer, &offset, i16, named.src_x);
        try writeInt(sink.writer, &offset, i16, named.src_y);
        try writeInt(sink.writer, &offset, u16, named.src_width);
        try writeInt(sink.writer, &offset, u16, named.src_height);
        try writeInt(sink.writer, &offset, i16, named.dst_x);
        try writeInt(sink.writer, &offset, i16, named.dst_y);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }
    pub fn OpenFont(sink: *RequestSink, font_id: Font, name: Slice(u16, [*]const u8)) Writer.Error!void {
        const non_list_len =
            2 // opcode and unused
            + 2 // request length
            + 4 // font id
            + 4 // name length (2 bytes) and 2 unused bytes
        ;
        const msg_len = non_list_len + std.mem.alignForward(u16, name.len, 4);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.open_font),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(font_id));
        try writeInt(sink.writer, &offset, u16, name.len);
        try writeAll(sink.writer, &offset, &[_]u8{ 0, 0 }); // unused
        try writeAll(sink.writer, &offset, name.nativeSlice());
        try writePad4(sink.writer, &offset);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub fn CloseFont(sink: *RequestSink, font_id: Font) Writer.Error!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.close_font),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(font_id));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn QueryFont(sink: *RequestSink, font: Fontable) Writer.Error!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.query_font),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(font));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn ListFonts(sink: *RequestSink, max_names: u16, pattern: Slice(u16, [*]const u8)) Writer.Error!void {
        const non_list_len =
            2 // opcode and unused
            + 2 // request length
            + 2 // max names
            + 2 // pattern length
        ;
        const msg_len = non_list_len + std.mem.alignForward(u16, pattern.len, 4);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.list_fonts),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u16, max_names);
        try writeInt(sink.writer, &offset, u16, pattern.len);
        try writeAll(sink.writer, &offset, pattern.nativeSlice());
        try writePad4(sink.writer, &offset);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }
    pub fn QueryTextExtents(
        sink: *RequestSink,
        font_id: Fontable,
        text: Slice(u16, [*]const u16),
    ) Writer.Error!void {
        const non_list_len =
            2 // opcode and odd_length
            + 2 // request length
            + 4 // font_id
        ;
        const msg_len = non_list_len + std.mem.alignForward(u16, text.len * 2, 4);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.query_text_extents),
            @intCast(text.len % 2), // odd_length
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(font_id));
        for (text.nativeSlice()) |c| {
            try writeInt(sink.writer, &offset, u16, std.mem.nativeToBig(u16, c));
        }
        try writePad4(sink.writer, &offset);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    // list_fonts = 49,
    // get_font_path = 52,

    pub fn CreatePixmap(sink: *RequestSink, id: Pixmap, drawable: Drawable, named: struct {
        depth: u8,
        width: u16,
        height: u16,
    }) Writer.Error!void {
        const msg_len = 16;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.create_pixmap),
            named.depth,
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(id));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(drawable));
        try writeInt(sink.writer, &offset, u16, named.width);
        try writeInt(sink.writer, &offset, u16, named.height);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub fn FreePixmap(sink: *RequestSink, id: Pixmap) Writer.Error!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.free_pixmap),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(id));
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub inline fn CreateGc(sink: *RequestSink, gc: GraphicsContext, drawable: Drawable, opt: GcOptions) Writer.Error!void {
        try sink.updateGc(gc, .{ .create = drawable }, &opt);
    }
    pub inline fn ChangeGc(sink: *RequestSink, gc: GraphicsContext, opt: GcOptions) Writer.Error!void {
        try sink.updateGc(gc, .change, &opt);
    }
    fn updateGc(
        sink: *RequestSink,
        gc: GraphicsContext,
        variant: GcVariant,
        options: *const GcOptions,
    ) Writer.Error!void {
        const msg = inspectUpdateGc(variant, options);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            switch (variant) {
                .create => @intFromEnum(Opcode.create_gc),
                .change => @intFromEnum(Opcode.change_gc),
            },
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg.len >> 2));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(gc));
        switch (variant) {
            .create => |drawable| {
                try writeInt(sink.writer, &offset, u32, @intFromEnum(drawable));
            },
            .change => {},
        }
        try writeInt(sink.writer, &offset, u32, @bitCast(msg.option_mask));
        inline for (std.meta.fields(GcOptions)) |field| {
            if (!isDefaultValue(options, field)) {
                try writeInt(sink.writer, &offset, u32, optionToU32(@field(options, field.name)));
            }
        }
        std.debug.assert(msg.len == offset);
        sink.sequence +%= 1;
    }

    pub fn FreeGc(sink: *RequestSink, gc: GraphicsContext) Writer.Error!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.free_gc),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(gc));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn ClearArea(
        sink: *RequestSink,
        window_id: Window,
        area: Rectangle,
        named: struct { exposures: bool },
    ) Writer.Error!void {
        const msg_len = 16;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.clear_area),
            if (named.exposures) 1 else 0,
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(window_id));
        try writeInt(sink.writer, &offset, i16, area.x);
        try writeInt(sink.writer, &offset, i16, area.y);
        try writeInt(sink.writer, &offset, u16, area.width);
        try writeInt(sink.writer, &offset, u16, area.height);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    /// The src and dest drawables must have the same root and depth. If you want to copy
    /// between two different drawables with different depths, use the X Render extension
    /// -> `composite`.
    pub fn CopyArea(sink: *RequestSink, named: struct {
        src_drawable: Drawable,
        dst_drawable: Drawable,
        gc: GraphicsContext,
        src_x: i16,
        src_y: i16,
        dst_x: i16,
        dst_y: i16,
        width: u16,
        height: u16,
    }) Writer.Error!void {
        const msg_len = 28;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.copy_area),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(named.src_drawable));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(named.dst_drawable));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(named.gc));
        try writeInt(sink.writer, &offset, i16, named.src_x);
        try writeInt(sink.writer, &offset, i16, named.src_y);
        try writeInt(sink.writer, &offset, i16, named.dst_x);
        try writeInt(sink.writer, &offset, i16, named.dst_y);
        try writeInt(sink.writer, &offset, u16, named.width);
        try writeInt(sink.writer, &offset, u16, named.height);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn PolyLine(
        sink: *RequestSink,
        coordinate_mode: enum(u8) { origin = 0, previous = 1 },
        drawable: Drawable,
        gc: GraphicsContext,
        points: Slice(u18, [*]const XY(i16)),
    ) Writer.Error!void {
        const msg_len: u18 =
            2 // opcode and coordinate-mode
            + 2 // request length
            + 4 // drawable id
            + 4 // gc id
            + points.len * 4; // each point is 4 bytes (i16 x, i16 y)
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.poly_line),
            @intFromEnum(coordinate_mode),
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg_len >> 2));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(drawable));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(gc));
        for (points.nativeSlice()) |point| {
            try writeInt(sink.writer, &offset, i16, point.x);
            try writeInt(sink.writer, &offset, i16, point.y);
        }
        std.debug.assert((offset & 0x3) == 0);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub inline fn PolyRectangle(
        sink: *RequestSink,
        drawable: Drawable,
        gc: GraphicsContext,
        rectangles: Slice(u18, [*]const Rectangle),
    ) Writer.Error!void {
        try sink.polyRectangle(drawable, gc, rectangles, @intFromEnum(Opcode.poly_rectangle));
    }

    pub inline fn PolyFillRectangle(
        sink: *RequestSink,
        drawable: Drawable,
        gc: GraphicsContext,
        rectangles: Slice(u18, [*]const Rectangle),
    ) Writer.Error!void {
        try sink.polyRectangle(drawable, gc, rectangles, @intFromEnum(Opcode.poly_fill_rectangle));
    }

    fn polyRectangle(
        sink: *RequestSink,
        drawable: Drawable,
        gc: GraphicsContext,
        rectangles: Slice(u18, [*]const Rectangle),
        opcode: u8,
    ) Writer.Error!void {
        const msg_len: u18 =
            2 // opcode and unused
            + 2 // request length
            + 4 // drawable id
            + 4 // gc id
            + rectangles.len * 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            opcode,
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg_len >> 2));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(drawable));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(gc));
        for (rectangles.nativeSlice()) |rectangle| {
            try writeInt(sink.writer, &offset, i16, rectangle.x);
            try writeInt(sink.writer, &offset, i16, rectangle.y);
            try writeInt(sink.writer, &offset, u16, rectangle.width);
            try writeInt(sink.writer, &offset, u16, rectangle.height);
        }
        std.debug.assert((offset & 0x3) == 0);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub fn PutImage(
        sink: *RequestSink,
        args: put_image.Args,
        data: Slice(u18, [*]const u8),
    ) Writer.Error!void {
        var offset = try PutImageStart(sink, args, data.len);
        try writeAll(sink.writer, &offset, data.nativeSlice());
        offset += data.len;
        try PutImageFinish(sink, args, data.len, offset);
    }

    pub fn PutImageStart(
        sink: *RequestSink,
        args: put_image.Args,
        data_len: u18,
    ) Writer.Error!usize {
        const msg_len = put_image.getLen(data_len);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.put_image),
            @intFromEnum(args.format),
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg_len >> 2));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(args.drawable));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(args.gc_id));
        try writeInt(sink.writer, &offset, u16, args.width);
        try writeInt(sink.writer, &offset, u16, args.height);
        try writeInt(sink.writer, &offset, i16, args.x);
        try writeInt(sink.writer, &offset, i16, args.y);
        try writeAll(sink.writer, &offset, &[_]u8{
            args.left_pad,
            args.depth,
            0, // unused
            0, // unused
        });
        std.debug.assert((offset & 0x3) == 0);
        std.debug.assert(offset == put_image.non_list_len);
        return offset;
    }

    pub fn PutImageFinish(
        sink: *RequestSink,
        data_len: u18,
        msg_offset: usize,
    ) Writer.Error!void {
        const msg_len = put_image.getLen(data_len);
        var offset = msg_offset;
        try writePad4(sink.writer, &offset);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub fn GetImage(sink: *RequestSink, named: struct {
        format: enum(u8) {
            xy_pixmap = 1,
            z_pixmap = 2,
        },
        drawable: Drawable,
        x: i16,
        y: i16,
        width: u16,
        height: u16,
        plane_mask: u32,
    }) Writer.Error!void {
        const msg_len =
            1 // opcode
            + 1 // format
            + 2 // request length
            + 4 // drawable id
            + 2 // x
            + 2 // y
            + 2 // width
            + 2 // height
            + 4 // plane-mask
        ;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.get_image),
            @intFromEnum(named.format),
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg_len >> 2));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(named.drawable));
        try writeInt(sink.writer, &offset, i16, named.x);
        try writeInt(sink.writer, &offset, i16, named.y);
        try writeInt(sink.writer, &offset, u16, named.width);
        try writeInt(sink.writer, &offset, u16, named.height);
        try writeInt(sink.writer, &offset, u32, named.plane_mask);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }
    pub fn PolyText8(
        sink: *RequestSink,
        drawable: Drawable,
        gc: GraphicsContext,
        pos: XY(i16),
        items: []const TextItem8,
    ) Writer.Error!void {
        const non_list_len =
            2 // opcode and string_length
            + 2 // request length
            + 4 // drawable id
            + 4 // gc id
            + 4 // x, y coordinates
        ;
        const msg_len = blk: {
            var total_len: u16 = non_list_len;
            for (items) |item| switch (item) {
                .text_element => |text_elem| {
                    // 1 byte for string length + 1 byte for delta + string data
                    total_len += 1 + 1 + @as(u16, text_elem.string.len);
                },
                .font_change => {
                    // Font changes are encoded as: length=255, followed by 4 bytes for font ID
                    total_len += 1 + 4;
                },
            };
            break :blk std.mem.alignForward(u16, total_len, 4);
        };
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.poly_text8),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(drawable));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(gc));
        try writeInt(sink.writer, &offset, i16, pos.x);
        try writeInt(sink.writer, &offset, i16, pos.y);
        for (items) |item| switch (item) {
            .text_element => |text_elem| {
                text_elem.string.validateMaxLen();
                try writeAll(sink.writer, &offset, &[_]u8{
                    text_elem.string.len,
                    @bitCast(text_elem.delta),
                });
                try writeAll(sink.writer, &offset, text_elem.string.nativeSlice());
            },
            .font_change => |font| {
                try sink.writer.writeByte(255);
                offset += 1;
                try writeInt(sink.writer, &offset, u32, @intFromEnum(font));
            },
        };
        try writePad4(sink.writer, &offset);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub fn printImageText8(
        sink: *RequestSink,
        drawable: Drawable,
        gc: GraphicsContext,
        pos: XY(i16),
        comptime fmt: []const u8,
        args: anytype,
    ) (error{TextTooLong} || Writer.Error)!void {
        const text_len_u64 = std.fmt.count(fmt, args);
        const text_len = std.math.cast(u8, text_len_u64) orelse return error.TextTooLong;
        var text_buf: [std.math.maxInt(@TypeOf(text_len))]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buf, fmt, args) catch unreachable;
        std.debug.assert(text.len == text_len);
        try sink.ImageText8(
            drawable,
            gc,
            pos,
            .init(text.ptr, text_len),
        );
    }
    pub fn ImageText8(
        sink: *RequestSink,
        drawable: Drawable,
        gc: GraphicsContext,
        pos: XY(i16),
        text: Slice(u8, [*]const u8),
    ) Writer.Error!void {
        const msg_len =
            2 // opcode and string_length
            + 2 // request length
            + 4 // drawable id
            + 4 // gc id
            + 4 // x, y coordinates
            + std.mem.alignForward(u16, text.len, 4);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.image_text8),
            text.len,
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @intFromEnum(drawable));
        try writeInt(sink.writer, &offset, u32, @intFromEnum(gc));
        try writeInt(sink.writer, &offset, i16, pos.x);
        try writeInt(sink.writer, &offset, i16, pos.y);
        try writeAll(sink.writer, &offset, text.nativeSlice());
        try writePad4(sink.writer, &offset);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    // create_colormap = 78,
    // free_colormap = 79,
    pub fn QueryExtension(sink: *RequestSink, name: Slice(u16, [*]const u8)) Writer.Error!void {
        const non_list_len = 8;
        const msg_len = non_list_len + std.mem.alignForward(u16, name.len, 4);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.query_extension),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u16, name.len);
        try writeAll(sink.writer, &offset, &[_]u8{
            0, // unused
            0, // unused
        });
        try writeAll(sink.writer, &offset, name.nativeSlice());
        try writePad4(sink.writer, &offset);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub fn GetKeyboardMapping(
        sink: *RequestSink,
        first_keycode: u8,
        count: u8,
    ) Writer.Error!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @intFromEnum(Opcode.get_keyboard_mapping),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeAll(sink.writer, &offset, &[_]u8{
            first_keycode,
            count,
            0, // unused
            0, // unused
        });
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }
};

const native_endian = builtin.target.cpu.arch.endian();

pub fn writeAll(writer: *Writer, offset: *usize, buf: []const u8) Writer.Error!void {
    try writer.writeAll(buf);
    offset.* += buf.len;
}
pub fn writeInt(writer: *Writer, offset: *usize, comptime T: type, int: T) Writer.Error!void {
    try writer.writeInt(T, int, native_endian);
    offset.* += @sizeOf(T);
}
pub fn writePad4(writer: *Writer, offset: *usize) Writer.Error!void {
    const pad_len = pad4Len(@truncate(offset.*));
    try writer.splatByteAll(0, pad_len);
    offset.* += pad_len;
}

pub fn flushConnectSetup(
    writer: *Writer,
    named: struct {
        version_major: u16 = 11,
        version_minor: u16 = 0,
        auth_name: Slice(u16, [*]const u8),
        auth_data: Slice(u16, [*]const u8),
    },
) Writer.Error!void {
    // TODO: how can we test this function?
    try writer.writeAll(&[_]u8{
        @as(u8, if (native_endian == .big) BigEndian else LittleEndian),
        0, // unused
    });
    try writer.writeInt(u16, named.version_major, native_endian);
    try writer.writeInt(u16, named.version_minor, native_endian);
    try writer.writeInt(u16, named.auth_name.len, native_endian);
    try writer.writeInt(u16, named.auth_data.len, native_endian);
    try writer.writeAll("\x00\x00"); // unused
    try writer.writeAll(named.auth_name.nativeSlice());
    try writer.splatByteAll(0, pad4Len(@truncate(named.auth_name.len)));
    try writer.writeAll(named.auth_data.nativeSlice());
    try writer.splatByteAll(0, pad4Len(@truncate(named.auth_data.len)));
    try writer.flush();
}

pub const ResourceBase = enum(u32) {
    _,

    pub fn add(r: ResourceBase, offset: u32) Resource {
        return @enumFromInt(@intFromEnum(r) + offset);
    }

    pub fn fromInt(i: u32) ResourceBase {
        return @enumFromInt(i);
    }

    pub const format = if (@import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) == .lt)
        formatLegacy
    else
        formatNew;
    fn formatLegacy(v: ResourceBase, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        try writer.print("ResourceBase({})", .{@intFromEnum(v)});
    }
    fn formatNew(v: ResourceBase, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("ResourceBase({})", .{@intFromEnum(v)});
    }
};

pub const Resource = enum(u32) {
    none = 0,
    _,

    pub fn window(r: Resource) Window {
        return @enumFromInt(@intFromEnum(r));
    }

    pub fn drawable(r: Resource) Drawable {
        return @enumFromInt(@intFromEnum(r));
    }

    pub fn font(r: Resource) Font {
        return @enumFromInt(@intFromEnum(r));
    }

    pub fn fontable(r: Resource) Fontable {
        return @enumFromInt(@intFromEnum(r));
    }

    pub fn graphicsContext(r: Resource) GraphicsContext {
        return @enumFromInt(@intFromEnum(r));
    }

    pub fn pixmap(r: Resource) Pixmap {
        return @enumFromInt(@intFromEnum(r));
    }

    pub fn picture(r: Resource) render.Picture {
        return @enumFromInt(@intFromEnum(r));
    }

    pub const format = if (@import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) == .lt)
        formatLegacy
    else
        formatNew;
    fn formatLegacy(v: Resource, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        if (v == .none) {
            try writer.writeAll("Resource(<none>)");
        } else {
            try writer.print("Resource({})", .{@intFromEnum(v)});
        }
    }
    fn formatNew(v: Resource, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (v == .none) {
            try writer.writeAll("Resource(<none>)");
        } else {
            try writer.print("Resource({})", .{@intFromEnum(v)});
        }
    }
};

/// Drawable
/// Both windows and pixmaps can be used as sources and destinations in graphics operations.
/// These windows and pixmaps are collectively known as drawables.
/// However, an InputOnly window cannot be used as a source or destination in a graphics operation.
pub const Drawable = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Drawable {
        return @enumFromInt(i);
    }

    pub fn format(v: Drawable, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        if (v == .none) {
            try writer.writeAll("Drawable(<none>)");
        } else {
            try writer.print("Drawable({})", .{@intFromEnum(v)});
        }
    }
};

pub const Window = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Window {
        return @enumFromInt(i);
    }

    pub fn resource(w: Window) Resource {
        return @enumFromInt(@intFromEnum(w));
    }
    pub fn drawable(w: Window) Drawable {
        return @enumFromInt(@intFromEnum(w));
    }

    pub fn format(v: Window, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        if (v == .none) {
            try writer.writeAll("Window(<none>)");
        } else {
            try writer.print("Window({})", .{@intFromEnum(v)});
        }
    }
};

pub const Cursor = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Cursor {
        return @enumFromInt(i);
    }

    pub fn format(v: Cursor, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        if (v == .none) {
            try writer.writeAll("Cursor(<none>)");
        } else {
            try writer.print("Cursor({})", .{@intFromEnum(v)});
        }
    }
};

pub const Font = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Font {
        return @enumFromInt(i);
    }

    pub fn fontable(f: Font) Fontable {
        return @enumFromInt(@intFromEnum(f));
    }

    pub fn format(v: Font, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        if (v == .none) {
            try writer.writeAll("Font(<none>)");
        } else {
            try writer.print("Font({})", .{@intFromEnum(v)});
        }
    }
};

pub const Fontable = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Fontable {
        return @enumFromInt(i);
    }

    pub fn graphicsContext(f: Fontable) GraphicsContext {
        return @enumFromInt(@intFromEnum(f));
    }

    pub fn font(f: Fontable) Font {
        return @enumFromInt(@intFromEnum(f));
    }

    pub fn format(v: Fontable, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        if (v == .none) {
            try writer.writeAll("Fontable(<none>)");
        } else {
            try writer.print("Fontable({})", .{@intFromEnum(v)});
        }
    }
};

pub const ColorMap = enum(u32) {
    copy_from_parent = 0,
    _,

    pub fn fromInt(i: u32) ColorMap {
        return @enumFromInt(i);
    }

    pub fn format(v: ColorMap, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        if (v == .copy_from_parent) {
            try writer.writeAll("ColorMap(<copy from parent>)");
        } else {
            try writer.print("ColorMap({})", .{@intFromEnum(v)});
        }
    }
};

pub const Visual = enum(u32) {
    pub fn fromInt(i: u32) Visual {
        return @enumFromInt(i);
    }

    copy_from_parent = 0,
    _,

    pub fn format(v: Visual, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        if (v == .copy_from_parent) {
            try writer.writeAll("Visual(<copy-from-parent>)");
        } else {
            try writer.print("Visual({})", .{@intFromEnum(v)});
        }
    }
};

pub const Pixmap = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Pixmap {
        return @enumFromInt(i);
    }

    pub fn drawable(p: Pixmap) Drawable {
        return @enumFromInt(@intFromEnum(p));
    }

    pub fn format(v: Pixmap, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        if (v == .none) {
            try writer.writeAll("Pixmap(<none>)");
        } else {
            try writer.print("Pixmap({})", .{@intFromEnum(v)});
        }
    }
};

/// Various information for graphics output is stored in a graphics context such as foreground pixel, background pixel, line width, clipping region, and so on.
/// A graphics context can only be used with drawables that have the same root and the same depth as the graphics context.
pub const GraphicsContext = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) GraphicsContext {
        return @enumFromInt(i);
    }

    pub fn fontable(g: GraphicsContext) Fontable {
        return @enumFromInt(@intFromEnum(g));
    }

    pub fn format(v: GraphicsContext, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        if (v == .none) {
            try writer.writeAll("GraphicsContext(<none>)");
        } else {
            try writer.print("GraphicsContext({})", .{@intFromEnum(v)});
        }
    }
};

/// A timestamp is a time value, expressed in milliseconds.
/// It typically is the time since the last server reset. Timestamp values wrap around (after about 49.7 days).
/// The server, given its current time is represented by timestamp T, always interprets timestamps from clients
/// by treating half of the timestamp space as being earlier in time than T and half of the timestamp space as
/// being later in time than T. One timestamp value (named CurrentTime) is never generated by the server. This
/// value is reserved for use in requests to represent the current server time.
pub const Timestamp = enum(u32) {
    pub fn fromInt(i: u32) GraphicsContext {
        return @enumFromInt(i);
    }

    /// X11 `CurrentTime`. Never generated by the server.
    current_time = 0,

    _,

    pub fn format(ts: Timestamp, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;

        if (ts == .current_time) {
            try writer.writeAll("Timestamp(<current time>)");
        } else {
            try writer.print("Timestamp({} ms)", .{@intFromEnum(ts)});
        }
    }
};

pub const Opcode = enum(u8) {
    create_window = 1,
    change_window_attributes = 2,
    destroy_window = 4,
    map_window = 8,
    configure_window = 12,
    query_tree = 15,
    intern_atom = 16,
    change_property = 18,
    get_property = 20,
    grab_pointer = 26,
    ungrab_pointer = 27,
    warp_pointer = 41,
    open_font = 45,
    close_font = 46,
    query_font = 47,
    query_text_extents = 48,
    list_fonts = 49,
    get_font_path = 52,
    create_pixmap = 53,
    free_pixmap = 54,
    create_gc = 55,
    change_gc = 56,
    free_gc = 60,
    clear_area = 61,
    copy_area = 62,
    poly_line = 65,
    poly_rectangle = 67,
    poly_fill_rectangle = 70,
    put_image = 72,
    get_image = 73,
    poly_text8 = 74,
    image_text8 = 76,
    create_colormap = 78,
    free_colormap = 79,
    query_extension = 98,
    get_keyboard_mapping = 101,
};

pub const BitGravity = enum(u4) {
    forget = 0,
    north_west = 1,
    north = 2,
    north_east = 3,
    west = 4,
    center = 5,
    east = 6,
    south_west = 7,
    south = 8,
    south_east = 9,
    static = 10,
};
pub const WinGravity = enum(u4) {
    unmap = 0,
    north_west = 1,
    north = 2,
    north_east = 3,
    west = 4,
    center = 5,
    east = 6,
    south_west = 7,
    south = 8,
    south_east = 9,
    static = 10,
};

pub fn isDefaultValue(s: anytype, comptime field: std.builtin.Type.StructField) bool {
    const default_value_ptr = @as(?*align(1) const field.type, @ptrCast(field.default_value_ptr)) orelse
        @compileError("isDefaultValue was called on field '" ++ field.name ++ "' which has no default value");
    switch (@typeInfo(field.type)) {
        .optional => {
            comptime std.debug.assert(default_value_ptr.* == null); // we're assuming all Optionals default to null
            return @field(s, field.name) == null;
        },
        else => {
            return @field(s, field.name) == default_value_ptr.*;
        },
    }
}

pub fn optionToU32(value: anytype) u32 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => return @intFromBool(value),
        .@"enum" => return @intFromEnum(value),
        .optional => |opt| {
            switch (@typeInfo(opt.child)) {
                .bool => return @intFromBool(value.?),
                .@"enum" => return @intFromEnum(value.?),
                else => {},
            }
        },
        else => {},
    }
    if (T == u32) return value;
    if (T == EventMask) return @bitCast(value);
    if (T == ?u32) return value.?;
    if (T == u16) return @intCast(value);
    if (T == ?u16) return @intCast(value.?);
    if (T == i16) return @intCast(@as(u16, @bitCast(value)));
    if (T == ?i16) return @intCast(@as(u16, @bitCast(value.?)));
    @compileError("TODO: implement optionToU32 for type: " ++ @typeName(T));
}

pub const EventMask = packed struct(u32) {
    KeyPress: u1 = 0,
    KeyRelease: u1 = 0,
    ButtonPress: u1 = 0,
    ButtonRelease: u1 = 0,
    EnterWindow: u1 = 0,
    LeaveWindow: u1 = 0,
    PointerMotion: u1 = 0,
    PointerMotionHint: u1 = 0,
    Button1Motion: u1 = 0,
    Button2Motion: u1 = 0,
    Button3Motion: u1 = 0,
    Button4Motion: u1 = 0,
    Button5Motion: u1 = 0,
    ButtonMotion: u1 = 0,
    SeymapState: u1 = 0,
    Exposure: u1 = 0,
    VisibilityChange: u1 = 0,
    StructureNotify: u1 = 0,
    ResizeRedirect: u1 = 0,
    /// Results in CreateNotify, DestroyNotify, MapNotify, UnmapNotify, ReparentNotify,
    /// ConfigureNotify, GravityNotify, CirculateNotify.
    SubstructureNotify: u1 = 0,
    SubstructureRedirect: u1 = 0,
    FocusChange: u1 = 0,
    PropertyChange: u1 = 0,
    ColormapChange: u1 = 0,
    OwnerGrabButton: u1 = 0,
    _reserved: u7 = 0,
};

pub const PointerEventMask = packed struct(u16) {
    _unused_key_press: u1 = 0,
    _unused_key_release: u1 = 0,
    button_press: u1 = 0,
    button_release: u1 = 0,
    enter_window: u1 = 0,
    leave_window: u1 = 0,
    pointer_motion: u1 = 0,
    pointer_motion_hint: u1 = 0,
    button1_motion: u1 = 0,
    button2_motion: u1 = 0,
    button3_motion: u1 = 0,
    button4_motion: u1 = 0,
    button5_motion: u1 = 0,
    button_motion: u1 = 0,
    keymap_state: u1 = 0,
    _unused_exposure: u1 = 0,
};

pub const window = struct {
    pub const Class = enum(u8) {
        copy_from_parent = 0,
        input_output = 1,
        input_only = 2,
    };

    pub const OptionMask = packed struct(u32) {
        bg_pixmap: u1 = 0,
        bg_pixel: u1 = 0,
        border_pixmap: u1 = 0,
        border_pixel: u1 = 0,
        bit_gravity: u1 = 0,
        win_gravity: u1 = 0,
        backing_store: u1 = 0,
        backing_planes: u1 = 0,
        backing_pixel: u1 = 0,
        override_redirect: u1 = 0,
        save_under: u1 = 0,
        event_mask: u1 = 0,
        dont_propagate: u1 = 0,
        colormap: u1 = 0,
        cursor: u1 = 0,
        _unused: u17 = 0,
    };

    pub const BgPixmap = enum(u32) { none = 0, copy_from_parent = 1 };
    pub const BorderPixmap = enum(u32) { copy_from_parent = 0 };
    pub const BackingStore = enum(u32) { not_useful = 0, when_mapped = 1, always = 2 };

    pub const Options = struct {
        bg_pixmap: BgPixmap = .none,
        bg_pixel: ?u32 = null,
        border_pixmap: BorderPixmap = .copy_from_parent,
        border_pixel: ?u32 = null,
        bit_gravity: BitGravity = .forget,
        win_gravity: WinGravity = .north_west,
        backing_store: BackingStore = .not_useful,
        backing_planes: u32 = 0xffffffff,
        backing_pixel: u32 = 0,
        override_redirect: bool = false,
        save_under: bool = false,
        event_mask: EventMask = .{},
        dont_propagate: u32 = 0,
        colormap: ColorMap = .copy_from_parent,
        cursor: Cursor = .none,
    };
};

pub const CreateWindowArgs = struct {
    window_id: Window,
    parent_window_id: Window,
    depth: u8,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    class: window.Class,
    visual_id: Visual,
};

fn inspectCreateWindow(options: *const window.Options) struct {
    len: u18,
    option_mask: window.OptionMask,
} {
    const non_option_len: u18 =
        2 // opcode and depth
        + 2 // request length
        + 4 // window id
        + 4 // parent window id
        + 10 // 2 bytes each for x, y, width, height and border-width
        + 2 // window class
        + 4 // visual id
        + 4 // window options value-mask
    ;
    var len: u18 = non_option_len;
    var option_mask: window.OptionMask = .{};
    inline for (std.meta.fields(window.Options)) |field| {
        if (!isDefaultValue(options, field)) {
            @field(option_mask, field.name) = 1;
            len += 4;
        }
    }
    return .{ .len = len, .option_mask = option_mask };
}

pub const change_window_attributes = struct {
    pub const non_option_len =
        2 // opcode and unused
        + 2 // request length
        + 4 // window id
        + 4 // window options value-mask
    ;
    pub const max_len = non_option_len + (15 * 4); // 15 possible 4-byte options
    pub fn serialize(buf: [*]u8, window_id: Window, options: window.Options) u16 {
        buf[0] = @intFromEnum(Opcode.change_window_attributes);
        buf[1] = 0; // unused

        // buf[2-3] is the len, set at the end of the function

        writeIntNative(u32, buf + 4, @intFromEnum(window_id));
        var request_len: u16 = non_option_len;
        var option_mask: window.OptionMask = .{};

        inline for (std.meta.fields(window.Options)) |field| {
            if (!isDefaultValue(options, field)) {
                writeIntNative(u32, buf + request_len, optionToU32(@field(options, field.name)));
                @field(option_mask, field.name) = 1;
                request_len += 4;
            }
        }

        writeIntNative(u32, buf + 8, @bitCast(option_mask));
        std.debug.assert((request_len & 0x3) == 0);
        writeIntNative(u16, buf + 2, request_len >> 2);
        return request_len;
    }
};

pub const destroy_window = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, window_id: Window) void {
        buf[0] = @intFromEnum(Opcode.destroy_window);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(window_id));
    }
};

pub const StackMode = enum(u8) {
    /// The window is placed at the top of the stack.
    ///
    /// When sibling is specified, the window is placed just above the sibling.
    above = 0,
    /// The window is placed at the bottom of the stack.
    ///
    /// When sibling is specified, the window is placed just below the sibling.
    below = 1,
    /// If any sibling occludes the window, then the window is placed at the top of the
    /// stack.
    ///
    /// When sibling is specified, if the sibling occludes the window, then the window
    /// is placed at the top of the stack.
    top_if = 2,
    /// If the window occludes any sibling, then the window is placed at the bottom of
    /// the stack.
    ///
    /// When sibling is specified, if the window occludes the sibling, then the window
    /// is placed at the bottom of the stack.
    bottom_if = 3,
    /// If any sibling occludes the window, then the window is placed at the top of the
    /// stack. Otherwise, if the window occludes any sibling, then the window is placed
    /// at the bottom of the stack.
    ///
    /// When sibling is specified, if the sibling occludes the window, then the window
    /// is placed at the top of the stack. Otherwise, if the window occludes the
    /// sibling, then the window is placed at the bottom of the stack.
    opposite = 4,
};

pub const configure_window = struct {
    pub const non_option_len =
        2 // opcode and unused
        + 2 // request length
        + 4 // window id
        + 2 // bitmask
        + 2 // unused
    ;
    pub const OptionMask = packed struct(u32) {
        x: u1 = 0,
        y: u1 = 0,
        width: u1 = 0,
        height: u1 = 0,
        border_width: u1 = 0,
        sibling: u1 = 0,
        stack_mode: u1 = 0,
        _unused: u25 = 0,
    };
    pub const Options = struct {
        x: ?i16 = null,
        y: ?i16 = null,
        width: ?u16 = null,
        height: ?u16 = null,
        border_width: ?u16 = null,
        sibling: ?u32 = null,
        stack_mode: ?StackMode = null,
    };
};

pub const query_tree = struct {
    pub const len = 8;
    pub const Reply = extern struct {
        response_type: ReplyKind,
        _unused_pad: u8,
        sequence: u16,
        word_len: u32,
        root_window_id: Window,
        parent_window_id: Window,
        num_windows: u16,
        _unused_pad2: [14]u8,
        _window_list_start: [0]Window,

        pub fn getWindowList(self: *@This()) []align(4) const Window {
            const window_ptr_list: [*]Window = @ptrCast(&self._window_list_start);
            return window_ptr_list[0..self.num_windows];
        }
    };
};

pub const intern_atom = struct {
    pub const non_list_len =
        2 // opcode and only-if-exists
        + 2 // request length
        + 2 // name length
        + 2 // unused
    ;
    pub fn getLen(name_len: u16) u16 {
        return non_list_len + std.mem.alignForward(u16, name_len, 4);
    }
    pub const Args = struct {
        only_if_exists: bool,
        name: Slice(u16, [*]const u8),
    };
};

pub const change_property = struct {
    pub const Mode = enum(u8) {
        replace = 0,
        prepend = 1,
        append = 2,
    };
};

pub const get_property = struct {
    pub const Reply = extern struct {
        response_type: ReplyKind,
        value_format: u8,
        sequence: u16,
        word_len: u32,
        type: Atom,
        bytes_after: u32,
        /// Length of the value in `value_format` units
        value_count: u32,
        unused: [12]u8,
        _values_list_start: [0]u8,

        pub fn getValueBytes(self: *@This()) !?[]align(4) const u8 {
            const num_bytes_in_value: u8 = switch (self.value_format) {
                0 => 0,
                8 => 1,
                16 => 2,
                32 => 4,
                else => return error.BadValueFormat,
            };

            // This will only be 0 if the property doesn't exist or there is a type mismatch
            if (num_bytes_in_value == 0) {
                return null;
            }

            const values_ptr_list: [*]align(4) u8 = @ptrFromInt(@intFromPtr(&self._values_list_start));
            return values_ptr_list[0..(self.value_count * num_bytes_in_value)];
        }
    };
    comptime {
        std.debug.assert(@sizeOf(Reply) == 32);
    }
};

pub const SyncMode = enum(u1) { synchronous = 0, asynchronous = 1 };

pub const get_font_path = struct {
    pub const len = 4;
    pub fn serialize(buf: [*]u8) void {
        buf[0] = @intFromEnum(Opcode.get_font_path);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
    }
};

pub const SubWindowMode = enum(u8) {
    clip_by_children = 0,
    include_inferiors = 1,
};
pub const gc_option_count = 23;
pub const GcOptionMask = packed struct(u32) {
    function: u1 = 0,
    plane_mask: u1 = 0,
    foreground: u1 = 0,
    background: u1 = 0,
    line_width: u1 = 0,
    line_style: u1 = 0,
    cap_style: u1 = 0,
    join_style: u1 = 0,
    fill_style: u1 = 0,
    fill_rule: u1 = 0,
    title: u1 = 0,
    stipple: u1 = 0,
    tile_stipple_x_origin: u1 = 0,
    tile_stipple_y_origin: u1 = 0,
    font: u1 = 0,
    subwindow_mode: u1 = 0,
    graphics_exposures: u1 = 0,
    clip_x_origin: u1 = 0,
    clip_y_origin: u1 = 0,
    clip_mask: u1 = 0,
    dash_offset: u1 = 0,
    dashes: u1 = 0,
    arc_mode: u1 = 0,
    _unused: u9 = 0,
};
pub const GcOptions = struct {
    // TODO: add all the options
    // Here are the defaults:
    // function copy
    // plane_mask all ones
    foreground: u32 = 0,
    background: u32 = 1,
    line_width: u16 = 0,
    // line_style solid
    // cap_style butt
    // join_style miter
    // fill_style solid
    // fill_rule even_odd
    // arc_mode pie_slice
    // tile: ?Pixmap = null,
    // stipple: ?Pixmap = null,
    // tile_stipple_x_origin 0
    // tile_stipple_y_origin 0
    font: ?Font = null,
    // font <server dependent>
    subwindow_mode: SubWindowMode = .clip_by_children,
    graphics_exposures: bool = true,
    // clip_x_origin 0
    // clip_y_origin 0
    // clip_mask: ?Font = null,
    // dash_offset 0
    // dashes the list 4, 4
};

const GcVariant = union(enum) {
    create: Drawable,
    change: void,
};

pub const create_colormap = struct {
    pub const len = 16;
    pub const Args = struct {
        id: ColorMap,
        window_id: Window,
        visual_id: Visual,
        alloc: enum(u8) { none, all },
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.create_colormap);
        buf[1] = @intFromEnum(args.alloc);
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, args.id);
        writeIntNative(u32, buf + 8, args.window_id);
        writeIntNative(u32, buf + 12, args.visual_id);
    }
};

pub const free_colormap = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, id: ColorMap) void {
        buf[0] = @intFromEnum(Opcode.free_colormap);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(id));
    }
};

fn inspectUpdateGc(variant: std.meta.Tag(GcVariant), options: *const GcOptions) struct {
    len: u18,
    option_mask: GcOptionMask,
} {
    const non_option_len: u18 = switch (variant) {
        .create => 2 // opcode and unused
        + 2 // request length
        + 4 // gc id
        + 4 // drawable id
        + 4 // option mask
        ,
        .change => 2 // opcode and unused
        + 2 // request length
        + 4 // gc id
        + 4 // option mask
        ,
    };

    var len: u18 = non_option_len;
    var option_mask: GcOptionMask = .{};
    inline for (std.meta.fields(GcOptions)) |field| {
        if (!isDefaultValue(options, field)) {
            @field(option_mask, field.name) = 1;
            len += 4;
        }
    }
    return .{ .len = len, .option_mask = option_mask };
}

pub const Rectangle = extern struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
};
comptime {
    std.debug.assert(@sizeOf(Rectangle) == 8);
}

pub const put_image = struct {
    pub const non_list_len =
        2 // opcode and format
        + 2 // request length
        + 4 // drawable id
        + 4 // gc id
        + 4 // width/height
        + 4 // x/y
        + 4 // left-pad, depth and 2 unused bytes
    ;
    pub fn getLen(data_len: u18) u18 {
        return non_list_len + std.mem.alignForward(u18, data_len, 4);
    }
    pub const Args = struct {
        format: enum(u8) {
            bitmap = 0,
            xy_pixmap = 1,
            z_pixmap = 2,
        },
        drawable: Drawable,
        gc_id: GraphicsContext,
        width: u16,
        height: u16,
        x: i16,
        y: i16,
        left_pad: u8,
        depth: u8,
    };
};

pub const get_image = struct {
    pub const Reply = extern struct {
        response_type: ReplyKind,
        depth: u8,
        sequence: u16,
        reply_len: u32,
        visual: Visual,
        unused: [20]u8, // padding
        _data_start: [0]u8,

        // From the X11 protocol docs:
        // (n+p)/4    reply length
        pub const scanline_pad_bytes = 4;

        pub fn getData(self: *@This()) []const u8 {
            const ptr: [*]const u8 = @ptrFromInt(@intFromPtr(&self._data_start));
            return ptr[0..(self.reply_len * scanline_pad_bytes)];
        }
    };
    comptime {
        std.debug.assert(@sizeOf(Reply) == 32);
    }
};

pub const TextItem8 = union(enum) {
    text_element: TextElement8,
    font_change: Font,
};
pub const TextElement8 = struct {
    delta: i8, // position offset along x-axis
    // 255 is reserved for font changes
    string: SliceWithMaxLen(u8, [*]const u8, 254),
};

pub fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}

pub const query_extension = struct {
    pub const non_list_len =
        2 // opcode and string_length
        + 2 // request length
        + 2 // name length
        + 2 // unused
    ;
    pub fn getLen(name_len: u16) u16 {
        return non_list_len + std.mem.alignForward(u16, name_len, 4);
    }
    pub const max_len = non_list_len + 0xffff;
    pub const name_offset = 8;
    pub fn serialize(buf: [*]u8, name: Slice(u16, [*]const u8)) void {
        serializeNoNameCopy(buf, name.len);
        @memcpy(buf[name_offset..][0..name.len], name.nativeSlice());
    }
    pub fn serializeNoNameCopy(buf: [*]u8, name_len: u16) void {
        buf[0] = @intFromEnum(Opcode.query_extension);
        buf[1] = 0; // unused
        const request_len = getLen(name_len);
        std.debug.assert(request_len & 0x3 == 0);
        writeIntNative(u16, buf + 2, request_len >> 2);
        writeIntNative(u32, buf + 4, name_len);
        buf[6] = 0; // unused
        buf[7] = 0; // unused
    }
};

pub fn writeIntNative(comptime T: type, buf: [*]u8, value: T) void {
    @as(*align(1) T, @ptrCast(buf)).* = value;
}
pub fn readIntNative(comptime T: type, buf: [*]const u8) T {
    return @as(*align(1) const T, @ptrCast(buf)).*;
}

const SocketReaderLegacy = std.io.Reader(std.posix.socket_t, std.posix.RecvFromError, readSocketLegacy);
pub fn readSocketLegacy(sock: std.posix.socket_t, buffer: []u8) !usize {
    return readSock(sock, buffer, 0);
}

const SocketReadFullError = if (zig_atleast_15) std.Io.Reader.Error else (error{EndOfStream} || std.posix.RecvFromError);

// pub const SocketReader = struct {
//     pub const Error = if (zig_atleast_15) (error{EndOfStream} || std.net.Stream.Reader.Error) else SocketReadFullError;

//     context: if (zig_atleast_15) std.net.Stream.Reader else std.posix.socket_t,
//     pub fn init(sock: std.posix.socket_t) SocketReader {
//         return if (zig_atleast_15)
//             .{ .context = (std.net.Stream{ .handle = sock }).reader(&.{}) }
//         else
//             .{ .context = sock };
//     }
//     pub fn interface(self: *SocketReader) if (zig_atleast_15) *std.Io.Reader else SocketReaderLegacy {
//         return if (zig_atleast_15) self.context.interface() else .{ .context = self.context };
//     }
//     pub fn read(self: SocketReader, buf: []u8) !usize {
//         if (zig_atleast_15) return self.context.read(buf);
//         return readSock(self.context, buf, 0);
//     }
//     pub fn getError(self: SocketReader, err: SocketReadFullError) ?Error {
//         return if (zig_atleast_15) switch (err) {
//             error.ReadFailed => self.context.getError(),
//             error.EndOfStream => error.EndOfStream,
//         } else err;
//     }
// };

pub fn recvFull(sock: posix.socket_t, buf: []u8) !void {
    std.debug.assert(buf.len > 0);
    var total_received: usize = 0;
    while (true) {
        const last_received = try posix.recv(sock, buf[total_received..], 0);
        if (last_received == 0)
            return error.ConnectionResetByPeer;
        total_received += last_received;
        if (total_received == buf.len)
            break;
    }
}

pub const Atom = enum(u32) {
    PRIMARY = 1,
    SECONDARY = 2,
    ARC = 3,
    ATOM = 4,
    BITMAP = 5,
    CARDINAL = 6,
    COLORMAP = 7,
    CURSOR = 8,
    CUT_BUFFER0 = 9,
    CUT_BUFFER1 = 10,
    CUT_BUFFER2 = 11,
    CUT_BUFFER3 = 12,
    CUT_BUFFER4 = 13,
    CUT_BUFFER5 = 14,
    CUT_BUFFER6 = 15,
    CUT_BUFFER7 = 16,
    DRAWABLE = 17,
    FONT = 18,
    INTEGER = 19,
    PIXMAP = 20,
    POINT = 21,
    RECTANGLE = 22,
    RESOURCE_MANAGER = 23,
    RGB_COLOR_MAP = 24,
    RGB_BEST_MAP = 25,
    RGB_BLUE_MAP = 26,
    RGB_DEFAULT_MAP = 27,
    RGB_GRAY_MAP = 28,
    RGB_GREEN_MAP = 29,
    RGB_RED_MAP = 30,
    STRING = 31,
    VISUALID = 32,
    WINDOW = 33,
    WM_COMMAND = 34,
    WM_HINTS = 35,
    WM_CLIENT_MACHINE = 36,
    WM_ICON_NAME = 37,
    WM_ICON_SIZE = 38,
    WM_NAME = 39,
    WM_NORMAL_HINTS = 40,
    WM_SIZE_HINTS = 41,
    WM_ZOOM_HINTS = 42,
    MIN_SPACE = 43,
    NORM_SPACE = 44,
    MAX_SPACE = 45,
    END_SPACE = 46,
    SUPERSCRIPT_X = 47,
    SUPERSCRIPT_Y = 48,
    SUBSCRIPT_X = 49,
    SUBSCRIPT_Y = 50,
    UNDERLINE_POSITION = 51,
    UNDERLINE_THICKNESS = 52,
    STRIKEOUT_ASCENT = 53,
    STRIKEOUT_DESCENT = 54,
    ITALIC_ANGLE = 55,
    X_HEIGHT = 56,
    QUAD_WIDTH = 57,
    WEIGHT = 58,
    POINT_SIZE = 59,
    RESOLUTION = 60,
    COPYRIGHT = 61,
    NOTICE = 62,
    FONT_NAME = 63,
    FAMILY_NAME = 64,
    FULL_NAME = 65,
    CAP_HEIGHT = 66,
    WM_CLASS = 67,
    WM_TRANSIENT_FOR = 68,
    _,
};

const ErrorCodeFont = enum(u8) {
    font = 7,
};
const ErrorCodeOpcode = enum(u8) {
    name = 15,
    length = 16,
};
pub const ErrorCode = enum(u8) {
    request = 1,
    value = 2,
    window = 3,
    pixmap = 4,
    atom = 5,
    cursor = 6,
    font = @intFromEnum(ErrorCodeFont.font),
    match = 8,
    drawable = 9,
    access = 10,
    alloc = 11,
    colormap = 12,
    gcontext = 13,
    id_choice = 14,
    name = @intFromEnum(ErrorCodeOpcode.name),
    length = @intFromEnum(ErrorCodeOpcode.length),
    implementation = 17,
};

pub const EventCode = enum(u8) {
    key_press = 2,
    key_release = 3,
    button_press = 4,
    button_release = 5,
    motion_notify = 6,
    enter_notify = 7,
    leave_notify = 8,
    focus_in = 9,
    focus_out = 10,
    keymap_notify = 11,
    expose = 12,
    graphics_exposure = 13,
    no_exposure = 14,
    visibility_notify = 15,
    create_notify = 16,
    destroy_notify = 17,
    unmap_notify = 18,
    map_notify = 19,
    map_request = 20,
    reparent_notify = 21,
    configure_notify = 22,
    configure_request = 23,
    gravity_notify = 24,
    resize_request = 25,
    circulate_notify = 26,
    circulate_request = 27,
    property_notify = 28,
    selection_clear = 29,
    selection_request = 30,
    selection_notify = 31,
    colormap_notify = 32,
    client_message = 33,
    mapping_notify = 34,
};

pub const ErrorKind = enum(u8) { err = 0 };
pub const ReplyKind = enum(u8) { reply = 1 };
// From the X Generic Event Extension
pub const GenericEventKind = enum(u8) { generic_extension_event = 35 };
pub const ServerMsgKind = enum(u8) {
    Error = @intFromEnum(ErrorKind.err),
    Reply = @intFromEnum(ReplyKind.reply),
    KeyPress = @intFromEnum(EventCode.key_press),
    KeyRelease = @intFromEnum(EventCode.key_release),
    ButtonPress = @intFromEnum(EventCode.button_press),
    ButtonRelease = @intFromEnum(EventCode.button_release),
    MotionNotify = @intFromEnum(EventCode.motion_notify),
    EnterNotify = @intFromEnum(EventCode.enter_notify),
    LeaveNotify = @intFromEnum(EventCode.leave_notify),
    FocusIn = @intFromEnum(EventCode.focus_in),
    FocusOut = @intFromEnum(EventCode.focus_out),
    KeymapNotify = @intFromEnum(EventCode.keymap_notify),
    Expose = @intFromEnum(EventCode.expose),
    GraphicsExposure = @intFromEnum(EventCode.graphics_exposure),
    NoExposure = @intFromEnum(EventCode.no_exposure),
    VisibilityNotify = @intFromEnum(EventCode.visibility_notify),
    CreateNotify = @intFromEnum(EventCode.create_notify),
    DestroyNotify = @intFromEnum(EventCode.destroy_notify),
    UnmapNotify = @intFromEnum(EventCode.unmap_notify),
    MapNotify = @intFromEnum(EventCode.map_notify),
    MapRequest = @intFromEnum(EventCode.map_request),
    ReparentNotify = @intFromEnum(EventCode.reparent_notify),
    ConfigureNotify = @intFromEnum(EventCode.configure_notify),
    ConfigureRequest = @intFromEnum(EventCode.configure_request),
    GravityNotify = @intFromEnum(EventCode.gravity_notify),
    ResizeRequest = @intFromEnum(EventCode.resize_request),
    CirculateNotify = @intFromEnum(EventCode.circulate_notify),
    CirculateRequest = @intFromEnum(EventCode.circulate_request),
    PropertyNotify = @intFromEnum(EventCode.property_notify),
    SelectionClear = @intFromEnum(EventCode.selection_clear),
    SelectionRequest = @intFromEnum(EventCode.selection_request),
    SelectionNotify = @intFromEnum(EventCode.selection_notify),
    ColormapNotify = @intFromEnum(EventCode.colormap_notify),
    ClientMessage = @intFromEnum(EventCode.client_message),
    MappingNotify = @intFromEnum(EventCode.mapping_notify),
    GenericExtensionEvent = @intFromEnum(GenericEventKind.generic_extension_event),
};

/// This type is equivalent to SETofKEYBUTMASK
pub const KeyButtonMask = packed struct(u16) {
    shift: bool, // #x0001     Shift
    lock: bool, // #x0002     Lock
    control: bool, // #x0004     Control
    mod1: bool, // #x0008     Mod1
    mod2: bool, // #x0010     Mod2
    mod3: bool, // #x0020     Mod3
    mod4: bool, // #x0040     Mod4
    mod5: bool, // #x0080     Mod5
    button1: bool, // #x0100     Button1
    button2: bool, // #x0200     Button2
    button3: bool, // #x0400     Button3
    button4: bool, // #x0800     Button4
    button5: bool, // #x1000     Button5
    _reserved: u3 = 0, // #xE000     unused but must be zero

    pub const all_5_mods: KeyButtonMask = .{
        .shift = false,
        .lock = false,
        .control = false,
        .mod1 = true,
        .mod2 = true,
        .mod3 = true,
        .mod4 = true,
        .mod5 = true,
        .button1 = false,
        .button2 = false,
        .button3 = false,
        .button4 = false,
        .button5 = false,
    };
    pub fn hasAnyModFlag(mask: KeyButtonMask) bool {
        return 0 != @as(u16, @bitCast(mask)) & @as(u16, @bitCast(KeyButtonMask.all_5_mods));
    }
    pub fn mod(mask: KeyButtonMask) KeycodeMod {
        var result: u2 = 0;
        if (mask.shift) result += 1;
        if (mask.hasAnyModFlag()) result += 2;
        return @enumFromInt(result);
    }

    pub fn format(kbm: KeyButtonMask, fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        var any = false;

        try writer.writeAll("KeyButtonMask{");
        inline for (std.meta.fields(KeyButtonMask)) |fld| {
            if (comptime std.mem.startsWith(u8, fld.name, "_"))
                continue;

            const value = @field(kbm, fld.name);

            if (value) {
                if (any) {
                    try writer.writeAll("|");
                }
                try writer.writeAll(fld.name);
                any = true;
            }
        }
        if (!any) {
            try writer.writeAll("<empty>");
        }
        try writer.writeAll("}");

        _ = fmt;
        _ = options;
    }
};

// Every Keycode has a standard mapping to 4 possible symbols:
//
//      Group 1       Group 2
//         |             |
//      |------|      |------|
//     Sym0   Sym1   Sym2   Sym3
//      |      |      |      |
//    lower  upper  lower  upper
//
// The presence of any modifier flag (Mod1 through Mod5) indicates
// Group 2 should be used instead of Group 1.
//
// The "shift/caps lock" flag indicates the second symbol in the group
// should be used instead of the first.
//
// The Keymap may include less or more than 4 symbols per code.  More than
// 4 entries are for non-standard mappings, less than 4 can be interpreted
// as 4 using the following mapping:
//
//      |  Sym0  |   Sym1   |  Sym2   |   Sym3   |
//   ---------------------------------------------
//    1 |  first | NoSymbol |  first  | NoSymbol |
//    2 |  first |  second  |  first  |  second  |
//    3 |  first |  second  |  third  | NoSymbol |
//
// NOTE: A group of the form
//    Keysym NoSymbol
// Is the same as:
//    lowercase(Keysym) uppercase(Keysym)
pub const KeycodeMod = enum(u2) {
    lower,
    upper,
    lower_mod,
    upper_mod,
};

pub const FontProp = extern struct {
    atom: Atom,
    value: u32,
};
comptime {
    std.debug.assert(@sizeOf(FontProp) == 8);
}

comptime {
    std.debug.assert(@sizeOf(CharInfo) == 12);
}
pub const CharInfo = extern struct {
    left_side_bearing: i16,
    right_side_bearing: i16,
    char_width: i16,
    ascent: i16,
    descent: i16,
    attributes: u16,
};

pub const StringListIterator = struct {
    mem: []const u8,
    left: u16,
    offset: usize = 0,
    pub fn next(self: *StringListIterator) !?Slice(u8, [*]const u8) {
        if (self.left == 0) return null;
        const len = self.mem[self.offset];
        const limit = self.offset + len + 1;
        if (limit > self.mem.len)
            return error.StringLenTooLarge;
        const ptr = self.mem.ptr + self.offset + 1;
        const str = Slice(u8, [*]const u8){ .ptr = ptr, .len = len };
        self.left -= 1;
        self.offset = limit;
        return str;
    }
};

/// Given the first 32 bytes of a given message coming across the wire,
/// parse out the given type and return the number of bytes that should be in the message
pub fn parseMsgLen(buf: [32]u8) u32 {
    switch (buf[0] & 0x7f) {
        @intFromEnum(ServerMsgKind.err) => return 32,
        @intFromEnum(ServerMsgKind.reply), @intFromEnum(ServerMsgKind.generic_extension_event) => {
            // Here is how those `4` and `8` magic numbers offsets are derived:
            // const start_offset = @offsetOf(ServerMsg.Reply, "word_len");
            // const end_offset = start_offset + @sizeOf(std.meta.FieldType(ServerMsg.Reply, .word_len));
            //
            // Or in the case of the generic extension event:
            // const start_offset = @offsetOf(ServerMsg.GenericExtensionEvent, "word_len");
            // const end_offset = start_offset + @sizeOf(std.meta.FieldType(ServerMsg.GenericExtensionEvent, .word_len));
            //
            const calculated_msg_length = 32 + (4 * readIntNative(u32, buf[4..8]));
            return calculated_msg_length;
        },
        2...34 => return 32,
        else => |t| std.debug.panic("We currently do not handle reply type {}", .{t}),
    }
}

pub const Format = extern struct {
    depth: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
    _: [5]u8,
};
comptime {
    if (@sizeOf(Format) != 8) @compileError("Format size is wrong");
}

comptime {
    std.debug.assert(@sizeOf(Screen) == 40);
}
pub const Screen = extern struct {
    root: Window,
    colormap: ColorMap,
    white_pixel: u32,
    black_pixel: u32,
    input_masks: u32,
    pixel_width: u16,
    pixel_height: u16,
    mm_width: u16,
    mm_height: u16,
    min_installed_maps: u16,
    max_installed_maps: u16,
    root_visual: Visual,
    backing_stores: u8,
    save_unders: u8,
    root_depth: u8,
    allowed_depth_count: u8,
    _allowed_depths_array_start: [0]ScreenDepth,

    pub fn getAllowedDepths(self: *@This(), allocator: std.mem.Allocator) ![]align(4) *ScreenDepth {
        var depths = try allocator.alloc(*ScreenDepth, self.allowed_depth_count);
        var pointer_offset: usize = 0;
        for (0..self.allowed_depth_count) |i| {
            const depth_ptr: *align(4) ScreenDepth = @ptrFromInt(@intFromPtr(&self._allowed_depths_array_start) + pointer_offset);

            depths[i] = depth_ptr;

            const depth_variable_size: usize = @as(usize, @sizeOf(ScreenDepth)) +
                (@as(usize, @sizeOf(VisualType)) * @as(usize, depth_ptr.visual_type_count));
            pointer_offset += depth_variable_size;
        }

        return depths;
    }

    pub fn findMatchingVisualType(self: *@This(), desired_depth: u8, desired_class: VisualType.Class, allocator: std.mem.Allocator) !VisualType {
        const depths = try self.getAllowedDepths(allocator);
        defer allocator.free(depths);

        for (depths) |depth| {
            if (depth.depth != desired_depth) continue;
            for (depth.getVisualTypes()) |visual_type| {
                if (visual_type.class != desired_class) continue;
                return visual_type;
            }
        }
        return error.VisualTypeNotFound;
    }
};

comptime {
    std.debug.assert(@sizeOf(ScreenDepth) == 8);
}
pub const ScreenDepth = extern struct {
    depth: u8,
    unused0: u8,
    visual_type_count: u16,
    unused1: u32,
    _visual_types_array_start: [0]VisualType,

    pub fn getVisualTypes(self: *@This()) []align(4) const VisualType {
        const visual_type_ptr_list: [*]align(4) VisualType = @ptrFromInt(@intFromPtr(&self._visual_types_array_start));
        return visual_type_ptr_list[0..self.visual_type_count];
    }
};

comptime {
    std.debug.assert(@sizeOf(VisualType) == 24);
}
pub const VisualType = extern struct {
    pub const Class = enum(u8) {
        static_gray = 0,
        gray_scale = 1,
        static_color = 2,
        psuedo_color = 3,
        true_color = 4,
        direct_color = 5,
    };

    id: Visual,
    class: Class,
    bits_per_rgb_value: u8,
    colormap_entries: u16,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    unused: u32,
};

// const SocketReadError = if (zig_atleast_15) std.Io.Reader.Error else std.posix.RecvFromError;
// pub fn readFullSock(sock: std.posix.socket_t, buf: []u8) SocketReadError!void {
//     std.debug.assert(buf.len > 0);

//     if (zig_atleast_15) {
//         var reader = (std.net.Stream{ .handle = sock }).reader();
//         return reader.readSliceAll(buf);
//     }

//     var total_received: usize = 0;
//     while (true) {
//         const last_received = try readSock(buf[total_received..]);
//         if (last_received == 0)
//             return error.EndOfStream;
//         total_received += last_received;
//         if (total_received == buf.len)
//             break;
//     }
// }

// pub const readFull = if (zig_atleast_15) readFullNew else readFullLegacy;
// fn readFullNew(reader: *std.Io.Reader, buf: []u8) std.Io.Reader.Error!void {
//     return reader.readSliceAll(buf);
// }
// fn readFullLegacy(reader: anytype, buf: []u8) ReadFullError(@TypeOf(reader))!void {
//     std.debug.assert(buf.len > 0);
//     var total_received: usize = 0;
//     while (true) {
//         const last_received = try reader.read(buf[total_received..]);
//         if (last_received == 0)
//             return error.EndOfStream;
//         total_received += last_received;
//         if (total_received == buf.len)
//             break;
//     }
// }

// pub const ReadConnectSetupHeaderOptions = struct {
//     read_timeout_ms: i32 = -1,
// };

// pub const readConnectSetupHeader = if (zig_atleast_15)
//     readConnectSetupHeaderNew
// else
//     readConnectSetupHeaderLegacy;

// fn readConnectSetupHeaderNew(
//     reader: *std.Io.Reader,
//     options: ReadConnectSetupHeaderOptions,
// ) !ConnectSetup.Header {
//     var header: ConnectSetup.Header = undefined;
//     if (options.read_timeout_ms == -1) {
//         try readFull(reader, header.asBuf());
//         return header;
//     }
//     @panic("read timeout not implemented");
// }
// fn readConnectSetupHeaderLegacy(
//     reader: anytype,
//     options: ReadConnectSetupHeaderOptions,
// ) !ConnectSetup.Header {
//     var header: ConnectSetup.Header = undefined;
//     if (options.read_timeout_ms == -1) {
//         try readFull(reader, header.asBuf());
//         return header;
//     }
//     @panic("read timeout not implemented");
// }

pub const AuthFailReason = struct {
    buf: [256]u8,
    len: u8,
    pub const format = if (zig_atleast_15) formatNew else formatLegacy;
    pub fn formatNew(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.buf[0..self.len]);
    }
    pub fn formatLegacy(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;
        try writer.writeAll(self.buf[0..self.len]);
    }
};

pub fn NonExhaustive(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .@"enum" => |info| info,
        else => |info| @compileError("expected an Enum type but got a(n) " ++ @tagName(info)),
    };
    std.debug.assert(info.is_exhaustive);
    return @Type(std.builtin.Type{ .@"enum" = .{
        .tag_type = info.tag_type,
        .fields = info.fields,
        .decls = &.{},
        .is_exhaustive = false,
    } });
}
pub const ImageByteOrder = enum(u8) {
    lsb_first = 0,
    msb_first = 1,
};

pub const ConnectSetup = struct {
    // because X makes an effort to align things to 4-byte bounaries, we
    // should get some better codegen by ensuring that our buffer is aligned
    // to 4-bytes
    buf: []align(4) u8,

    pub fn deinit(self: ConnectSetup, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    comptime {
        std.debug.assert(@sizeOf(Header) == 8);
    }
    pub const Header = extern struct {
        pub const Status = enum(u8) { failed = 0, success = 1, authenticate = 2, _ };

        status: Status,
        status_opt: u8, // length of 'reason' in Failed case
        proto_major_ver: u16,
        proto_minor_ver: u16,
        reply_u32_len: u16,

        pub fn asBuf(self: *@This()) []u8 {
            return @as([*]u8, @ptrCast(self))[0..@sizeOf(@This())];
        }

        pub fn getReplyLen(self: @This()) u16 {
            return 4 * self.reply_u32_len;
        }

        pub fn readFailReason(self: @This(), reader: *Reader) AuthFailReason {
            var result: AuthFailReason = undefined;
            if (reader.readSliceAll(result.buf[0..self.status_opt])) {
                result.len = self.status_opt;
            } else |read_err| {
                result.len = @intCast((std.fmt.bufPrint(&result.buf, "failed to read failure reason: {s}", .{@errorName(read_err)}) catch |err| switch (err) {
                    error.NoSpaceLeft => unreachable,
                }).len);
            }
            return result;
        }
    };

    comptime {
        std.debug.assert(@sizeOf(Fixed) == 32);
    }
    /// All the connect setup fields that are at fixed offsets
    pub const Fixed = extern struct {
        release_number: u32,
        resource_id_base: ResourceBase,
        resource_id_mask: u32,
        motion_buffer_size: u32,
        vendor_len: u16,
        max_request_len: u16,
        root_screen_count: u8,
        format_count: u8,
        image_byte_order: NonExhaustive(ImageByteOrder),
        bitmap_format_bit_order: u8,
        bitmap_format_scanline_unit: u8,
        bitmap_format_scanline_pad: u8,
        min_keycode: u8,
        max_keycode: u8,
        unused: u32,
    };
    pub fn fixed(self: @This()) *Fixed {
        return @ptrCast(self.buf.ptr);
    }

    pub const VendorOffset = 32;
    pub fn getVendorSlice(self: @This(), vendor_len: u16) ![]align(4) u8 {
        const vendor_limit = VendorOffset + vendor_len;
        if (vendor_limit > self.buf.len)
            return error.XMalformedReply_VendorLenTooBig;
        return self.buf[VendorOffset..vendor_limit];
    }

    pub fn getFormatListOffset(vendor_len: u16) u32 {
        return VendorOffset + std.mem.alignForward(u32, vendor_len, 4);
    }
    pub fn getFormatListLimit(format_list_offset: u32, format_count: u32) u32 {
        return format_list_offset + (@sizeOf(Format) * format_count);
    }
    pub fn getFormatListPtr(self: @This(), format_list_offset: u32) [*]align(4) Format {
        return @ptrCast(@alignCast(self.buf.ptr + format_list_offset));
    }
    pub fn getFormatList(self: @This(), format_list_offset: u32, format_list_limit: u32) ![]align(4) Format {
        if (format_list_limit > self.buf.len)
            return error.XMalformedReply_FormatCountTooBig;
        return self.getFormatListPtr(format_list_offset)[0..@divExact(format_list_limit - format_list_offset, @sizeOf(Format))];
    }

    pub fn getFirstScreenPtr(self: @This(), format_list_limit: u32) *align(4) Screen {
        return @ptrCast(@alignCast(self.buf.ptr + format_list_limit));
    }
    pub fn getScreensPtr(self: @This(), format_list_limit: u32) [*]align(4) Screen {
        return @ptrCast(@alignCast(self.buf.ptr + format_list_limit));
    }
    pub fn getScreens(self: @This(), allocator: std.mem.Allocator) ![]align(4) *Screen {
        const format_list_offset = ConnectSetup.getFormatListOffset(self.fixed().vendor_len);
        const format_list_limit = ConnectSetup.getFormatListLimit(format_list_offset, self.fixed().format_count);

        const screen_count = self.fixed().root_screen_count;
        var screens = try allocator.alloc(*Screen, screen_count);
        var pointer_offset = format_list_limit;
        for (0..screen_count) |screen_index| {
            var screen: *align(4) Screen = @ptrCast(@alignCast(self.buf.ptr + pointer_offset));
            screens[screen_index] = screen;
            const depths = try screen.getAllowedDepths(allocator);
            for (depths) |depth| {
                pointer_offset += @sizeOf(ScreenDepth) + (@sizeOf(VisualType) * depth.visual_type_count);
            }
            pointer_offset += @sizeOf(Screen);
        }

        return screens;
    }
};

pub fn rgb24To16(color: u24) u16 {
    const r: u16 = @intCast((color >> 19) & 0x1f);
    const g: u16 = @intCast((color >> 11) & 0x1f);
    const b: u16 = @intCast((color >> 3) & 0x1f);
    return (r << 11) | (g << 6) | b;
}

pub fn rgb24To(color: u24, depth_bits: u8) u32 {
    return switch (depth_bits) {
        16 => rgb24To16(color),
        24 => color,
        32 => {
            // Add an opaque alpha component (0xAARRGGBB)
            const alpha = 0xff;
            // Shift the alpha component all the way up to the top
            // 0x000000ff -> 0xff000000
            const alpha_shifted: u32 = alpha << 24;

            // Combine the color and alpha component
            return alpha_shifted | color;
        },
        else => @panic("todo"),
    };
}

pub const ReadFormatter = struct {
    reader: *Reader,

    msg1: union(enum) {
        none,
        already_read: struct {
            msg1: ServerMsg1,
            maybe_two: ?Part2,
        },
    },

    pub const Part2 = union {
        Error: ServerMsg1.Error,
        Reply: ServerMsg1.Reply,
        KeyPress: ServerMsg1.KeyPress,
        KeyRelease: ServerMsg1.KeyRelease,
        ButtonPress: ServerMsg1.ButtonPress,
        ButtonRelease: ServerMsg1.ButtonRelease,
        MotionNotify: ServerMsg1.MotionNotify,
        EnterNotify: ServerMsg1.EnterNotify,
        LeaveNotify: ServerMsg1.LeaveNotify,
        // FocusIn: ServerMsg1.FocusIn,
        // FocusOut: ServerMsg1.FocusOut,
        KeymapNotify: ServerMsg1.KeymapNotify,
        Expose: ServerMsg1.Expose,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
        // : ServerMsg1.,
    };

    pub const format = if (zig_atleast_15) formatNew else formatLegacy;
    pub fn formatNew(self: ReadFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        self.formatCommon(writer) catch |err| switch (err) {
            error.ReadFailed => return error.WriteFailed,
            error.EndOfStream => return error.WriteFailed,
            else => |e| return e,
        };
    }
    fn formatLegacy(
        self: ReadFormatter,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try self.formatCommon(writer);
    }
    fn formatCommon(self: ReadFormatter, writer: anytype) !void {
        std.debug.assert(self.reader.buffer.len > 0);
        const msg1: ServerMsg1, const maybe_two: ?ReadFormatter.Part2 = switch (self.msg1) {
            .none => .{ try read1(self.reader), null },
            .already_read => |already_read| .{ already_read.msg1, already_read.maybe_two },
        };
        try writer.print("{f}", .{fmtEnum(msg1.kind)});
        switch (msg1.kind) {
            .Error => { // 0
                const err: ServerMsg1.Error = if (maybe_two) |two| two.Error else try msg1.read2(.Error, self.reader);
                try writer.print(
                    " {f} sequence={} generic={} opcode={f}.{}",
                    .{ fmtEnum(err.code), err.sequence, err.generic, fmtEnum(err.major_opcode), err.minor_opcode },
                );
            },
            .Reply => { // 1
                const reply: ServerMsg1.Reply = if (maybe_two) |two| two.Reply else try msg1.read2(.Reply, self.reader);
                const remaining_size = reply.remainingSize();
                try writer.print(" sequence={} flex={} with {} bytes: ", .{ reply.sequence, reply.flexible, remaining_size });
                var remaining = remaining_size;
                while (remaining > 0) {
                    // note: we asserted reader has non 0-length buffer
                    const take_len = @min(self.reader.buffer.len, remaining);
                    const next = try self.reader.take(take_len);
                    try writer.print("{x}", .{next});
                    remaining -= @intCast(take_len);
                }
            },
            .FocusIn => @panic("todo"), // 9
            .FocusOut => @panic("todo"), // 10
            .GraphicsExposure => @panic("todo"), // 13
            .NoExposure => @panic("todo"), // 14
            .VisibilityNotify => @panic("todo"), // 15
            .CreateNotify => @panic("todo"), // 16
            .DestroyNotify => @panic("todo"), // 17
            .UnmapNotify => @panic("todo"), // 18
            .MapNotify => @panic("todo"), // 19
            .MapRequest => @panic("todo"), // 20
            .ReparentNotify => @panic("todo"), // 21
            .ConfigureNotify => @panic("todo"), // 22
            .ConfigureRequest => @panic("todo"), // 23
            .GravityNotify => @panic("todo"), // 24
            .ResizeRequest => @panic("todo"), // 25
            .CirculateNotify => @panic("todo"), // 26
            .CirculateRequest => @panic("todo"), // 27
            .PropertyNotify => @panic("todo"), // 28
            .SelectionClear => @panic("todo"), // 29
            .SelectionRequest => @panic("todo"), // 30
            .SelectionNotify => @panic("todo"), // 31
            .ColormapNotify => @panic("todo"), // 32
            .ClientMessage => @panic("todo"), // 33
            .MappingNotify => @panic("todo"), // 34
            .GenericExtensionEvent => @panic("todo"), // 35
            inline else => |tag| {
                // bitCast is ok, all non-exhaustive named values are valid exhaustive value
                const tag_named: ServerMsgKind = @enumFromInt(@intFromEnum(tag));
                // const msg: @field(ServerMsg1, @tagName(tag)) = if (maybe_two) |two| @field(two, @tagName(tag)) else try msg1.read2(tag_named, self.reader);
                const msg = if (maybe_two) |two| @field(two, @tagName(tag)) else try msg1.read2(tag_named, self.reader);
                try writer.print("{}", .{msg});
            },
        }
    }
};
fn readInt(reader: *Reader, comptime Int: type) Reader.Error!Int {
    var int: Int = undefined;
    try reader.readSliceAll(std.mem.asBytes(&int));
    return int;
}

pub fn read1(reader: *Reader) Reader.Error!ServerMsg1 {
    return .{ .kind = @enumFromInt(try reader.takeByte()) };
}

pub const ServerMsg1 = struct {
    kind: ServerMsgKind,

    pub fn discard2(msg1: ServerMsg1, reader: *Reader) Reader.Error!void {
        switch (msg1.kind) {
            inline else => |tag| _ = try msg1.read2(@enumFromInt(@intFromEnum(tag)), reader),
        }
    }

    pub fn readFmt(msg1: ServerMsg1, reader: *Reader) ReadFormatter {
        return .{
            .reader = reader,
            .msg1 = .{ .already_read = .{ .msg1 = msg1, .maybe_two = null } },
        };
    }

    // pub fn read2Reply(self: ServerMsg1, reader: *Reader) Reader.Error!Reply {
    //     std.debug.assert(self.kind == .Reply);
    //     return .{
    //         .flexible = try reader.takeByte(),
    //         .sequence = try readInt(reader, u16),
    //         .word_count = try readInt(reader, u32),
    //     };
    // }

    // fn Read2(kind: ServerMsgKind) type {
    //     return @field(Server
    //     return switch (kind) {
    //         .Error => Error2,
    //         .Reply => Reply2,
    //         .KeymapNotify => KeymapNotify2,
    //         .Expose => Expose2,
    //         // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    //         else => @panic(std.fmt.comptimePrint("todo: support {s}", .{@tagName(kind)})),
    //     };
    // }
    pub fn read2(
        self: ServerMsg1,
        comptime kind: ServerMsgKind,
        reader: *Reader,
    ) Reader.Error!@field(ServerMsg1, @tagName(kind)) {
        std.debug.assert(@intFromEnum(self.kind) == @intFromEnum(kind));
        var result: @field(ServerMsg1, @tagName(kind)) = undefined;
        result.kind = @enumFromInt(@intFromEnum(kind));
        try reader.readSliceAll(std.mem.asBytes(&result)[1..]);
        return result;
    }
    comptime {
        std.debug.assert(@sizeOf(Error) == 32);
    }
    pub const Error = extern struct {
        kind: enum(u8) { Error = @intFromEnum(ServerMsgKind.Error) },
        code: NonExhaustive(ErrorCode),
        sequence: u16,
        generic: u32,
        minor_opcode: u16,
        major_opcode: NonExhaustive(Opcode),
        data: [21]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(Reply) == 8);
    }
    pub const Reply = extern struct {
        kind: enum(u8) { Reply = @intFromEnum(ServerMsgKind.Reply) },
        flexible: u8 align(1),
        sequence: u16 align(1),
        word_count: u32 align(1),
        pub fn remainingSize(self: *const Reply) u35 {
            const body_size: u35 = @as(u35, self.word_count) * 4;
            return body_size + 24;
        }
        pub fn bodySize(self: *const Reply) u34 {
            return @as(u34, self.word_count) * 4;
        }
        pub fn readFmt(self: Reply, reader: *Reader) ReadFormatter {
            return .{
                .reader = reader,
                .msg1 = .{ .already_read = .{
                    .msg1 = .{ .kind = .Reply },
                    .maybe_two = .{ .Reply = self },
                } },
            };
        }
    };
    comptime {
        std.debug.assert(@sizeOf(KeyPress) == 32);
    }
    pub const KeyPress = extern struct {
        kind: enum(u8) { KeyPress = @intFromEnum(ServerMsgKind.KeyPress) },
        keycode: u8,
        sequence: u16,
        timestamp: Timestamp,
        root: Window,
        event: Window,
        child: Window,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: KeyButtonMask,
        same_screen: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        unused: u8,
    };
    comptime {
        std.debug.assert(@sizeOf(KeyRelease) == 32);
    }
    pub const KeyRelease = extern struct {
        kind: enum(u8) { KeyPress = @intFromEnum(ServerMsgKind.KeyRelease) },
        keycode: u8,
        sequence: u16,
        timestamp: Timestamp,
        root: Window,
        event: Window,
        child: Window,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: KeyButtonMask,
        same_screen: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        unused: u8,
    };
    comptime {
        std.debug.assert(@sizeOf(ButtonPress) == 32);
    }
    pub const ButtonPress = extern struct {
        kind: enum(u8) { ButtonPress = @intFromEnum(ServerMsgKind.ButtonPress) },
        button: u8,
        sequence: u16,
        timestamp: Timestamp,
        root: Window,
        event: Window,
        child: Window,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: KeyButtonMask,
        same_screen: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        unused: u8,
    };
    comptime {
        std.debug.assert(@sizeOf(ButtonRelease) == 32);
    }
    pub const ButtonRelease = extern struct {
        kind: enum(u8) { ButtonRelease = @intFromEnum(ServerMsgKind.ButtonRelease) },
        button: u8,
        sequence: u16,
        timestamp: Timestamp,
        root: Window,
        event: Window,
        child: Window,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: KeyButtonMask,
        same_screen: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        unused: u8,
    };
    comptime {
        std.debug.assert(@sizeOf(EnterNotify) == 32);
    }
    pub const MotionNotify = extern struct {
        kind: enum(u8) { MotionNotify = @intFromEnum(ServerMsgKind.MotionNotify) },
        detail: NonExhaustive(enum(u8) {
            normal = 0,
            hint = 1,
        }),
        sequence: u16,
        timestamp: Timestamp,
        root: Window,
        event: Window,
        child: Window,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: KeyButtonMask,
        same_screen: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        unused: u8,
    };
    comptime {
        std.debug.assert(@sizeOf(EnterNotify) == 32);
    }
    pub const EnterNotify = extern struct {
        kind: enum(u8) { EnterNotify = @intFromEnum(ServerMsgKind.EnterNotify) },
        detail: NonExhaustive(enum(u8) {
            ancestor = 0,
            virtual = 1,
            inferior = 2,
            nonlinear = 3,
            nonlinear_virtual = 4,
        }),
        sequence: u16,
        timestamp: Timestamp,
        root: Window,
        event: Window,
        child: Window,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: KeyButtonMask,
        mode: NonExhaustive(enum(u8) {
            normal = 0,
            grab = 1,
            ungrab = 2,
        }),
        flags: packed struct(u8) {
            focus: bool,
            same_screen: bool,
            unused: u6,
        },
    };
    comptime {
        std.debug.assert(@sizeOf(LeaveNotify) == 32);
    }
    pub const LeaveNotify = extern struct {
        kind: enum(u8) { LeaveNotify = @intFromEnum(ServerMsgKind.LeaveNotify) },
        detail: NonExhaustive(enum(u8) {
            ancestor = 0,
            virtual = 1,
            inferior = 2,
            nonlinear = 3,
            nonlinear_virtual = 4,
        }),
        sequence: u16,
        timestamp: Timestamp,
        root: Window,
        event: Window,
        child: Window,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: KeyButtonMask,
        mode: NonExhaustive(enum(u8) {
            normal = 0,
            grab = 1,
            ungrab = 2,
        }),
        flags: packed struct(u8) {
            focus: bool,
            same_screen: bool,
            unused: u6,
        },
    };

    comptime {
        std.debug.assert(@sizeOf(FocusIn) == 32);
    }
    pub const FocusIn = extern struct {
        kind: enum(u8) { FocusIn = @intFromEnum(ServerMsgKind.FocusIn) },
        todo: [31]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(FocusOut) == 32);
    }
    pub const FocusOut = extern struct {
        kind: enum(u8) { FocusOut = @intFromEnum(ServerMsgKind.FocusOut) },
        todo: [31]u8,
    };

    pub const KeymapNotify = extern struct {
        kind: enum(u8) { KeymapNotify = @intFromEnum(ServerMsgKind.KeymapNotify) },
        keys: [31]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(Expose) == 32);
    }
    pub const Expose = extern struct {
        kind: enum(u8) { Expose = @intFromEnum(ServerMsgKind.Expose) },
        unused: u8,
        sequence: u16,
        window: Window,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        count: u16,
        padding: [14]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(GraphicsExposure) == 32);
    }
    pub const GraphicsExposure = extern struct {
        kind: enum(u8) { GraphicsExposure = @intFromEnum(ServerMsgKind.GraphicsExposure) },
        unused: u8,
        sequence: u16,
        drawable: Drawable,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        minor_opcode: u16,
        count: u16,
        major_opcode: u8,
        unused2: [11]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(NoExposure) == 32);
    }
    pub const NoExposure = extern struct {
        kind: enum(u8) { NoExposure = @intFromEnum(ServerMsgKind.NoExposure) },
        unused: u8,
        sequence: u16,
        drawable: Drawable,
        minor_opcode: u16,
        major_opcode: u8,
        unused2: [21]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(VisibilityNotify) == 32);
    }
    pub const VisibilityNotify = extern struct {
        kind: enum(u8) { VisibilityNotify = @intFromEnum(ServerMsgKind.VisibilityNotify) },
        unused: u8,
        sequence: u16,
        window: Window,
        state: NonExhaustive(enum(u8) {
            unobscured = 0,
            partially_obscured = 1,
            fully_obscured = 2,
        }),
        unused2: [23]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(CreateNotify) == 32);
    }
    pub const CreateNotify = extern struct {
        kind: enum(u8) { CreateNotify = @intFromEnum(ServerMsgKind.CreateNotify) },
        unused: u8,
        sequence: u16,
        parent: Window,
        window: Window,
        x: i16,
        y: i16,
        width: u16,
        height: u16,
        border_width: u16,
        override_redirect: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        unused2: [9]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(DestroyNotify) == 32);
    }
    pub const DestroyNotify = extern struct {
        kind: enum(u8) { DestroyNotify = @intFromEnum(ServerMsgKind.DestroyNotify) },
        unused: u8,
        sequence: u16,
        event: Window,
        window: Window,
        unused2: [20]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(UnmapNotify) == 32);
    }
    pub const UnmapNotify = extern struct {
        kind: enum(u8) { UnmapNotify = @intFromEnum(ServerMsgKind.UnmapNotify) },
        unused: u8,
        sequence: u16,
        event: Window,
        window: Window,
        from_configure: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        unused2: [19]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(MapNotify) == 32);
    }
    pub const MapNotify = extern struct {
        kind: enum(u8) { MapNotify = @intFromEnum(ServerMsgKind.MapNotify) },
        unused: u8,
        sequence: u16,
        event: Window,
        window: Window,
        override_redirect: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        unused2: [19]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(MapRequest) == 32);
    }
    pub const MapRequest = extern struct {
        kind: enum(u8) { MapRequest = @intFromEnum(ServerMsgKind.MapRequest) },
        unused: u8,
        sequence: u16,
        parent: Window,
        window: Window,
        unused2: [20]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(ReparentNotify) == 32);
    }
    pub const ReparentNotify = extern struct {
        kind: enum(u8) { ReparentNotify = @intFromEnum(ServerMsgKind.ReparentNotify) },
        unused: u8,
        sequence: u16,
        event: Window,
        window: Window,
        parent: Window,
        x: i16,
        y: i16,
        override_redirect: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        unused2: [11]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(ConfigureNotify) == 32);
    }
    pub const ConfigureNotify = extern struct {
        kind: enum(u8) { ConfigureNotify = @intFromEnum(ServerMsgKind.ConfigureNotify) },
        unused: u8,
        sequence: u16,
        event: Window,
        window: Window,
        above_sibling: Window,
        x: i16,
        y: i16,
        width: u16,
        height: u16,
        border_width: u16,
        override_redirect: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        unused2: [5]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(ConfigureRequest) == 32);
    }
    pub const ConfigureRequest = extern struct {
        kind: enum(u8) { ConfigureRequest = @intFromEnum(ServerMsgKind.ConfigureRequest) },
        stack_mode: NonExhaustive(enum(u8) {
            above = 0,
            below = 1,
            top_if = 2,
            bottom_if = 3,
            opposite = 4,
        }),
        sequence: u16,
        parent: Window,
        window: Window,
        sibling: Window,
        x: i16,
        y: i16,
        width: u16,
        height: u16,
        border_width: u16,
        value_mask: packed struct(u16) {
            x: u1,
            y: u1,
            width: u1,
            height: u1,
            border_width: u1,
            sibling: u1,
            stack_mode: u1,
            unused: u9,
        },
        unused2: [4]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(GravityNotify) == 32);
    }
    pub const GravityNotify = extern struct {
        kind: enum(u8) { GravityNotify = @intFromEnum(ServerMsgKind.GravityNotify) },
        unused: u8,
        sequence: u16,
        event: Window,
        window: Window,
        x: i16,
        y: i16,
        unused2: [16]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(ResizeRequest) == 32);
    }
    pub const ResizeRequest = extern struct {
        kind: enum(u8) { ResizeRequest = @intFromEnum(ServerMsgKind.ResizeRequest) },
        unused: u8,
        sequence: u16,
        window: Window,
        width: u16,
        height: u16,
        unused2: [20]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(CirculateNotify) == 32);
    }
    pub const CirculateNotify = extern struct {
        kind: enum(u8) { CirculateNotify = @intFromEnum(ServerMsgKind.CirculateNotify) },
        unused: u8,
        sequence: u16,
        event: Window,
        window: Window,
        unused2: u32,
        place: NonExhaustive(enum(u8) {
            top = 0,
            bottom = 1,
        }),
        unused3: [15]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(CirculateRequest) == 32);
    }
    pub const CirculateRequest = extern struct {
        kind: enum(u8) { CirculateRequest = @intFromEnum(ServerMsgKind.CirculateRequest) },
        unused: u8,
        sequence: u16,
        parent: Window,
        window: Window,
        unused2: u32,
        place: NonExhaustive(enum(u8) {
            top = 0,
            bottom = 1,
        }),
        unused3: [15]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(PropertyNotify) == 32);
    }
    pub const PropertyNotify = extern struct {
        kind: enum(u8) { PropertyNotify = @intFromEnum(ServerMsgKind.PropertyNotify) },
        unused: u8,
        sequence: u16,
        window: Window,
        atom: Atom,
        time: Timestamp,
        state: NonExhaustive(enum(u8) {
            new_value = 0,
            deleted = 1,
        }),
        unused2: [15]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(SelectionClear) == 32);
    }
    pub const SelectionClear = extern struct {
        kind: enum(u8) { SelectionClear = @intFromEnum(ServerMsgKind.SelectionClear) },
        unused: u8,
        sequence: u16,
        time: Timestamp,
        owner: Window,
        selection: Atom,
        unused2: [16]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(SelectionRequest) == 32);
    }
    pub const SelectionRequest = extern struct {
        kind: enum(u8) { SelectionRequest = @intFromEnum(ServerMsgKind.SelectionRequest) },
        unused: u8,
        sequence: u16,
        time: Timestamp,
        owner: Window,
        requestor: Window,
        selection: Atom,
        target: Atom,
        property: Atom,
        unused2: [4]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(SelectionNotify) == 32);
    }
    pub const SelectionNotify = extern struct {
        kind: enum(u8) { SelectionNotify = @intFromEnum(ServerMsgKind.SelectionNotify) },
        unused: u8,
        sequence: u16,
        time: Timestamp,
        requestor: Window,
        selection: Atom,
        target: Atom,
        property: Atom,
        unused2: [8]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(ColormapNotify) == 32);
    }
    pub const ColormapNotify = extern struct {
        kind: enum(u8) { ColormapNotify = @intFromEnum(ServerMsgKind.ColormapNotify) },
        unused: u8,
        sequence: u16,
        window: Window,
        colormap: ColorMap,
        new: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        state: NonExhaustive(enum(u8) {
            uninstalled = 0,
            installed = 1,
        }),
        unused2: [18]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(ClientMessage) == 32);
    }
    pub const ClientMessage = extern struct {
        kind: enum(u8) { ClientMessage = @intFromEnum(ServerMsgKind.ClientMessage) },
        format: u8,
        sequence: u16,
        window: Window,
        type: Atom,
        data: [20]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(MappingNotify) == 32);
    }
    pub const MappingNotify = extern struct {
        kind: enum(u8) { MappingNotify = @intFromEnum(ServerMsgKind.MappingNotify) },
        unused: u8,
        sequence: u16,
        request: NonExhaustive(enum(u8) {
            modifier = 0,
            keyboard = 1,
            pointer = 2,
        }),
        first_keycode: u8,
        count: u8,
        unused2: [25]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(GenericExtensionEvent) == 32);
    }
    pub const GenericExtensionEvent = extern struct {
        kind: enum(u8) { GenericExtensionEvent = @intFromEnum(ServerMsgKind.GenericExtensionEvent) },
        extension: u8,
        sequence: u16,
        word_len: u32,
        event_type: u16,
        unused: [22]u8,

        pub fn remainingBodySize(self: *const GenericExtensionEvent) u34 {
            return @as(u34, self.word_len) * 4;
        }
    };
};

pub fn fmtRead2(reader: *Reader, kind: ServerMsgKind) FmtRead2 {
    std.debug.assert(reader.buffer.len > 0);
    return .{ .reader = reader, .kind = kind };
}
pub const FmtRead2 = struct {
    reader: *Reader,
    kind: ServerMsgKind,
    pub const format = if (zig_atleast_15) formatNew else formatLegacy;
    fn formatNew(self: FmtRead2, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        self.formatCommon(writer) catch |err| switch (err) {
            error.ReadFailed => return error.WriteFailed,
            error.EndOfStream => return error.WriteFailed,
            else => |e| return e,
        };
    }
    fn formatLegacy(
        self: FmtRead2,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try self.formatCommon(writer);
    }
    fn formatCommon(self: FmtRead2, writer: anytype) !void {
        std.debug.assert(self.reader.buffer.len > 0);

        try writer.print("{f}", .{fmtEnum(self.msg1.kind)});
        switch (self.msg1.kind) {
            .err => { // 0
                // Error format: 32 bytes total
                // Bytes 0-5 already read in msg1
                // Byte 6-9: bad value/resource ID (32-bit)
                // Byte 10-11: minor opcode (16-bit)
                // Byte 12: major opcode (8-bit)
                // Bytes 13-31: unused/specific error data
                const bad_value = try self.reader.takeInt(u32, native_endian);
                const minor_opcode = try self.reader.takeInt(u16, native_endian);
                const major_opcode: Opcode = @enumFromInt(try self.reader.takeInt(u8, native_endian));
                try writer.print(
                    " code={} bad_value=0x{x} major={} minor={}",
                    .{ self.msg1.flexible, bad_value, major_opcode, minor_opcode },
                );
                try self.reader.discardAll(21);
            },
            .reply => { // 1
                const size2 = self.msg1.size2();
                try writer.print(" with {} bytes: ", .{size2});
                var remaining = size2;
                while (remaining > 0) {
                    // note: we asserted reader has non 0-length buffer
                    const take_len = @min(self.reader.buffer.len, remaining);
                    const next = try self.reader.take(take_len);
                    try writer.print("{x}", .{next});
                    remaining -= @intCast(take_len);
                }
            },
            .key_press => @panic("todo"), // 2
            .key_release => @panic("todo"), // 3
            .button_press => @panic("todo"), // 4
            .button_release => @panic("todo"), // 5
            .motion_notify => @panic("todo"), // 6
            .enter_notify => @panic("todo"), // 7
            .leave_notify => @panic("todo"), // 8
            .focus_in => @panic("todo"), // 9
            .focus_out => @panic("todo"), // 10
            .keymap_notify => @panic("todo"), // 11
            .expose => {
                @panic("todo"); // 12
            },
            .graphics_exposure => @panic("todo"), // 13
            .no_exposure => @panic("todo"), // 14
            .visibility_notify => @panic("todo"), // 15
            .create_notify => @panic("todo"), // 16
            .destroy_notify => @panic("todo"), // 17
            .unmap_notify => @panic("todo"), // 18
            .map_notify => @panic("todo"), // 19
            .map_request => @panic("todo"), // 20
            .reparent_notify => @panic("todo"), // 21
            .configure_notify => @panic("todo"), // 22
            .configure_request => @panic("todo"), // 23
            .gravity_notify => @panic("todo"), // 24
            .resize_request => @panic("todo"), // 25
            .circulate_notify => @panic("todo"), // 26
            .circulate_request => @panic("todo"), // 27
            .property_notify => @panic("todo"), // 28
            .selection_clear => @panic("todo"), // 29
            .selection_request => @panic("todo"), // 30
            .selection_notify => @panic("todo"), // 31
            .colormap_notify => @panic("todo"), // 32
            .client_message => @panic("todo"), // 33
            .mapping_notify => @panic("todo"), // 34
            .generic_extension_event => @panic("todo"), // 35
            _ => @panic("todo"),
        }
    }
};

const Read3 = enum {
    QueryFont,
    QueryTextExtents,
    ListFonts,
    QueryExtension,
    pub fn Type(self: Read3) type {
        return switch (self) {
            inline else => |tag| @field(stage3, @tagName(tag)),
        };
    }
};

pub const stage3 = struct {
    comptime {
        std.debug.assert(@sizeOf(QueryFont) == 52);
    }
    pub const QueryFont = extern struct {
        min_bounds: CharInfo,
        unused1: u32,
        max_bounds: CharInfo,
        unused2: u32,
        min_char_or_byte2: u16,
        max_char_or_byte2: u16,
        default_char: u16,
        property_count: u16,
        draw_direction: u8, // 0 left to right, 1 right to left
        min_byte1: u8,
        max_byte1: u8,
        all_chars_exist: u8,
        font_ascent: i16,
        font_descent: i16,
        info_count: u32,
        pub fn remainingSize(word_count: u32) u34 {
            const body_size: u34 = @as(u34, word_count) * 4;
            return body_size - (@sizeOf(QueryFont) - 24);
        }
    };
    comptime {
        std.debug.assert(@sizeOf(QueryTextExtents) == 24);
    }
    pub const QueryTextExtents = extern struct {
        // draw_direction: u8, // 0=left-to-right, 1=right-to-left
        font_ascent: i16,
        font_descent: i16,
        overal_ascent: i16,
        overall_descent: i16,
        overall_width: i32,
        overall_left: i32,
        overall_right: i32,
        unused: [4]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(ListFonts) == 24);
    }
    pub const ListFonts = extern struct {
        count: u16,
        unused: [22]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(QueryExtension) == 24);
    }
    pub const QueryExtension = extern struct {
        present: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        major_opcode: u8,
        first_event: u8,
        first_error: u8,
        unused: [20]u8,
    };
};

pub fn read3(comptime kind: Read3, reader: *Reader) Reader.Error!kind.Type() {
    var value: kind.Type() = undefined;
    try reader.readSliceAll(std.mem.asBytes(&value));
    return value;
}

pub const Extension = struct {
    opcode: u8,
    first_event: u8,
    first_error: u8,
    pub fn init(reply: stage3.QueryExtension) ProtocolError!?Extension {
        switch (reply.present) {
            .no => return null,
            .yes => {},
            else => |v| {
                log.err("unexpected present value {}", .{v});
                return error.X11Protocol;
            },
        }
        return .{
            .opcode = reply.major_opcode,
            .first_event = reply.first_event,
            .first_error = reply.first_error,
        };
    }
};

// pub fn readHeader(reader: *Reader) Reader.Error!ServerMsgHeader {
//     var msg: ServerMsgHeader = undefined;
//     try reader.readSliceAll(std.mem.asBytes(&msg));
//     return msg;
// }

// fn ReadFullError(comptime Reader: type) type {
//     if (zig_atleast_15) return std.Io.Reader.Error;
//     return error{EndOfStream} || Reader.Error;
// }

// pub fn readOneMsgAlloc(allocator: std.mem.Allocator, reader: anytype) (error{OutOfMemory} || ReadFullError(@TypeOf(reader)))![]align(4) u8 {
//     var buf = try allocator.allocWithOptions(u8, 32, align4, null);
//     errdefer allocator.free(buf);
//     const len = try readOneMsg(reader, buf);
//     if (len > 32) {
//         buf = try allocator.realloc(buf, len);
//         try readOneMsgFinish(reader, buf);
//     }
//     return buf;
// }

// /// The caller must check whether the length returned is larger than the provided `buf`.
// /// If it is, then only the first 32-bytes have been read.  The caller can allocate a new
// /// buffer large enough to accomodate and finish reading the message by copying the first
// /// 32 bytes to the new buffer then calling `readOneMsgFinish`.
// pub const readOneMsg = if (zig_atleast_15) readOneMsgNew else readOneMsgLegacy;
// pub fn readOneMsgNew(reader: *std.Io.Reader, buf: []align(4) u8) std.Io.Reader.Error!u32 {
//     std.debug.assert(buf.len >= 32);
//     try readFull(reader, buf[0..32]);
//     const msg_len = parseMsgLen(buf[0..32].*);
//     if (msg_len > 32 and msg_len < buf.len) {
//         try readOneMsgFinish(reader, buf[0..msg_len]);
//     }
//     return msg_len;
// }
// pub fn readOneMsgLegacy(reader: anytype, buf: []align(4) u8) ReadFullError(@TypeOf(reader))!u32 {
//     std.debug.assert(buf.len >= 32);
//     try readFull(reader, buf[0..32]);
//     const msg_len = parseMsgLen(buf[0..32].*);
//     if (msg_len > 32 and msg_len < buf.len) {
//         try readOneMsgFinish(reader, buf[0..msg_len]);
//     }
//     return msg_len;
// }

// pub fn readOneMsgFinish(reader: anytype, buf: []align(4) u8) ReadFullError(@TypeOf(reader))!void {
//     //
//     // for now this is the only case where this should happen
//     // I've added this check to audit the code again if this every changes
//     //
//     std.debug.assert(buf[0] == @intFromEnum(ServerMsgKind.reply));
//     try readFull(reader, buf[32..]);
// }

pub fn charsetName(set: Charset) ?[]const u8 {
    return if (stdext.enums.hasName(set)) @tagName(set) else null;
}

// any application that supports windows can call this at
// the start of their program to setup WSA on Windows
pub fn wsaStartup() !void {
    if (builtin.os.tag == .windows) {
        _ = try windows.WSAStartup(2, 2);
    }
}

pub fn readSock(sock: posix.socket_t, buf: []u8, flags: u32) std.posix.RecvFromError!usize {
    if (builtin.os.tag == .windows) {
        const result = windows.recvfrom(sock, buf.ptr, buf.len, flags, null, null);
        if (result != windows.ws2_32.SOCKET_ERROR)
            return @intCast(result);
        switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEWOULDBLOCK => return error.WouldBlock,
            .WSAECONNRESET => return error.ConnectionResetByPeer,
            else => |err| return windows.unexpectedWSAError(err),
        }
    }
    return posix.recv(sock, buf, flags);
}

pub fn writeSock(sock: posix.socket_t, buf: []const u8, flags: u32) std.posix.SendError!usize {
    if (builtin.os.tag == .windows) {
        const result = windows.sendto(sock, buf.ptr, buf.len, flags, null, 0);
        if (result != windows.ws2_32.SOCKET_ERROR)
            return @intCast(result);
        switch (windows.ws2_32.WSAGetLastError()) {
            .WSAEWOULDBLOCK => return error.WouldBlock,
            .WSAECONNRESET => return error.ConnectionResetByPeer,
            else => |err| return windows.unexpectedWSAError(err),
        }
    }
    return posix.send(sock, buf, flags);
}

/// returns a formatter that will print the enum value name if it exists,
/// otherwise, it prints a question mark followed by the value, i.e. ?(123)
pub fn fmtEnum(enum_value: anytype) FmtEnum(@TypeOf(enum_value)) {
    return .{ .value = enum_value };
}
pub fn FmtEnum(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();
        pub const format = if (zig_atleast_15) formatNew else formatLegacy;
        fn formatNew(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (@typeInfo(T).@"enum".is_exhaustive) {
                try writer.print("{s}", .{@tagName(self.value)});
            } else if (std.enums.tagName(T, self.value)) |name| {
                try writer.print("{s}", .{name});
            } else {
                try writer.print("?({d})", .{@intFromEnum(self.value)});
            }
        }
        fn formatLegacy(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            if (@typeInfo(T).@"enum".is_exhaustive) {
                try writer.print("{s}", .{@tagName(self.value)});
            } else if (std.enums.tagName(T, self.value)) |name| {
                try writer.print("{s}", .{name});
            } else {
                try writer.print("?({d})", .{@intFromEnum(self.value)});
            }
        }
    };
}
