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

pub const inputext = @import("xinputext.zig");
pub const render = @import("xrender.zig");
pub const dbe = @import("xdbe.zig");
pub const shape = @import("xshape.zig");
pub const testext = @import("xtest.zig");

// Expose some helpful stuff
pub const MappedFile = @import("MappedFile.zig");
pub const charset = @import("charset.zig");
pub const Charset = charset.Charset;
pub const DoubleBuffer = @import("DoubleBuffer.zig");
pub const ContiguousReadBuffer = @import("ContiguousReadBuffer.zig");
pub const Slice = @import("x/slice.zig").Slice;
pub const keymap = @import("keymap.zig");

pub const TcpBasePort = 6000;

pub const max_port = 65535;
pub const max_display_num = max_port - TcpBasePort;

pub const BigEndian = 'B';
pub const LittleEndian = 'l';

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
    if (std.mem.eql(u8, display, "w32")) return .{
        .proto = .w32,
        .hostStart = 0,
        .hostLimit = undefined,
        .display_num = undefined,
        .preferredScreen = undefined,
    };

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

fn testParseDisplay(display: []const u8, proto: ?Protocol, host: []const u8, display_num: u16, screen: ?u32) !void {
    const parsed = try parseDisplay(display);
    try testing.expectEqual(proto, parsed.proto);
    try testing.expect(std.mem.eql(u8, host, parsed.hostSlice(display.ptr)));
    try testing.expectEqual(DisplayNum.fromInt(display_num), parsed.display_num);
    try testing.expectEqual(screen, parsed.preferredScreen);
}

test "parseDisplay" {
    // no need to test the empty string case, it triggers an assert and a client passing
    // one is a bug that needs to be fixed
    try testing.expectError(error.HasMultipleProtocols, parseDisplay("tcp//"));
    try testing.expectError(error.NoDisplayNumber, parseDisplay("0"));
    try testing.expectError(error.NoDisplayNumber, parseDisplay("unix/"));
    try testing.expectError(error.NoDisplayNumber, parseDisplay("inet/1"));
    try testing.expectError(error.NoDisplayNumber, parseDisplay(":"));

    try testing.expectError(error.BadDisplayNumber, parseDisplay(":a"));
    try testing.expectError(error.BadDisplayNumber, parseDisplay(":0a"));
    try testing.expectError(error.BadDisplayNumber, parseDisplay(":0a."));
    try testing.expectError(error.BadDisplayNumber, parseDisplay(":0a.0"));
    try testing.expectError(error.BadDisplayNumber, parseDisplay(":1x"));
    try testing.expectError(error.BadDisplayNumber, parseDisplay(":1x."));
    try testing.expectError(error.BadDisplayNumber, parseDisplay(":1x.10"));
    try testing.expectError(error.BadDisplayNumber, parseDisplay(":70000"));

    try testing.expectError(error.BadScreenNumber, parseDisplay(":1.x"));
    try testing.expectError(error.BadScreenNumber, parseDisplay(":1.0x"));
    // TODO: should this be an error or no????
    //try testing.expectError(error.BadScreenNumber, parseDisplay(":1."));

    try testParseDisplay("tcp/host:123.456", .tcp, "host", 123, 456);
    try testParseDisplay("host:123.456", null, "host", 123, 456);
    try testParseDisplay(":123.456", null, "", 123, 456);
    try testParseDisplay(":123", null, "", 123, null);
    try testParseDisplay("inet6/:43", .inet6, "", 43, null);
    try testParseDisplay("/", null, "/", 0, null);
    try testParseDisplay("/some/file/path/x0", null, "/some/file/path/x0", 0, null);
    try testParseDisplay("w32", .w32, "", 0, null);
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
pub fn connect(display: []const u8, parsed: ParsedDisplay) !posix.socket_t {
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

    pub fn format(
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

pub fn connectExplicit(optional_host: ?[]const u8, optional_protocol: ?Protocol, display_num: DisplayNum) ConnectError!posix.socket_t {
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
                .{display_num},
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
pub fn connectTcp(name: []const u8, port: u16, options: ConnectTcpOptions) ConnectError!posix.socket_t {
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
fn tcpConnect(addr: std.net.Address) TcpConnectError!posix.socket_t {
    return (std.net.tcpConnectToAddress(addr) catch |err| switch (err) {
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
    }).handle;
}

pub fn disconnect(sock: posix.socket_t) void {
    posix.shutdown(sock, .both) catch {}; // ignore any error here
    posix.close(sock);
}

pub fn connectUnixDisplayNum(display_num: DisplayNum) ConnectError!posix.socket_t {
    const path_prefix = "/tmp/.X11-unix/X";
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    const path = std.fmt.bufPrintZ(
        &addr.path,
        "{s}{}",
        .{ path_prefix, display_num },
    ) catch unreachable;
    return connectUnixAddr(&addr, path.len);
}

pub fn connectUnixPath(socket_path: []const u8) ConnectError!posix.socket_t {
    var addr = posix.sockaddr.un{ .family = posix.AF.UNIX, .path = undefined };
    const path = std.fmt.bufPrintZ(
        &addr.path,
        "{s}",
        .{socket_path},
    ) catch unreachable;
    return connectUnixAddr(&addr, path.len);
}

pub fn connectUnixAddr(addr: *const posix.sockaddr.un, path_len: usize) ConnectError!posix.socket_t {
    const sock = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch |err| switch (err) {
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
    return sock;
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
    } else |err| switch (err) {
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

    pub fn format(
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
        pub fn format(
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

pub const connect_setup = struct {
    pub const max_auth_name_len = std.math.maxInt(u16);
    pub const max_auth_data_len = std.math.maxInt(u16);
    pub const max_len = getLen(max_auth_name_len, max_auth_data_len);

    pub const auth_offset =
        1 // byte-order
        + 1 // unused
        + 2 // proto_major_ver
        + 2 // proto_minor_ver
        + 2 // auth_name_len
        + 2 // auth_data_len
        + 2 // unused
    ;
    pub fn getLen(auth_name_len: u16, auth_data_len: u16) u32 {
        return auth_offset
        //+ auth_name_len
        //+ pad4(u16, auth_name_len)
        + std.mem.alignForward(u32, auth_name_len, 4)
            //+ auth_data_len
            //+ pad4(u16, auth_data_len)
        + std.mem.alignForward(u32, auth_data_len, 4);
    }

    pub fn serialize(
        buf: [*]u8,
        proto_major_ver: u16,
        proto_minor_ver: u16,
        auth_name: Slice(u16, [*]const u8),
        auth_data: Slice(u16, [*]const u8),
    ) void {
        buf[0] = @as(u8, if (builtin.target.cpu.arch.endian() == .big) BigEndian else LittleEndian);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, proto_major_ver);
        writeIntNative(u16, buf + 4, proto_minor_ver);
        writeIntNative(u16, buf + 6, auth_name.len);
        writeIntNative(u16, buf + 8, auth_data.len);
        writeIntNative(u16, buf + 10, 0); // unused
        @memcpy(buf[12..][0..auth_name.len], auth_name.nativeSlice());
        //const off = 12 + pad4(u16, auth_name.len);
        const off: u16 = 12 + std.mem.alignForward(u16, auth_name.len, 4);
        @memcpy(buf[off..][0..auth_data.len], auth_data.nativeSlice());
        std.debug.assert(getLen(auth_name.len, auth_data.len) ==
            off + std.mem.alignForward(u16, auth_data.len, 4));
    }
};

test "ConnectSetupMessage" {
    const auth_name = comptime slice(u16, @as([]const u8, "hello"));
    const auth_data = comptime slice(u16, @as([]const u8, "there"));
    const len = comptime connect_setup.getLen(auth_name.len, auth_data.len);
    var buf: [len]u8 = undefined;
    connect_setup.serialize(&buf, 1, 1, auth_name, auth_data);
}

pub const ResourceBase = enum(u32) {
    _,

    pub fn add(r: ResourceBase, offset: u32) Resource {
        return @enumFromInt(@intFromEnum(r) + offset);
    }

    pub fn format(v: ResourceBase, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
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

    pub fn format(v: Resource, fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
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
    clear_area = 61,
    copy_area = 62,
    poly_line = 65,
    poly_rectangle = 67,
    poly_fill_rectangle = 70,
    put_image = 72,
    get_image = 73,
    image_text8 = 76,
    create_colormap = 78,
    free_colormap = 79,
    query_extension = 98,
    get_keyboard_mapping = 101,
    _,
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

fn isDefaultValue(s: anytype, comptime field: std.builtin.Type.StructField) bool {
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

fn optionToU32(value: anytype) u32 {
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
    key_press: u1 = 0,
    key_release: u1 = 0,
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
    exposure: u1 = 0,
    visibility_change: u1 = 0,
    structure_notify: u1 = 0,
    resize_redirect: u1 = 0,
    substructure_notify: u1 = 0,
    substructure_redirect: u1 = 0,
    focus_change: u1 = 0,
    property_change: u1 = 0,
    colormap_change: u1 = 0,
    owner_grab_button: u1 = 0,
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

pub const create_window = struct {
    pub const non_option_len =
        2 // opcode and depth
        + 2 // request length
        + 4 // window id
        + 4 // parent window id
        + 10 // 2 bytes each for x, y, width, height and border-width
        + 2 // window class
        + 4 // visual id
        + 4 // window options value-mask
    ;
    pub const max_len = non_option_len + (15 * 4); // 15 possible 4-byte options

    pub const Class = enum(u8) {
        copy_from_parent = 0,
        input_output = 1,
        input_only = 2,
    };
    pub const Args = struct {
        window_id: Window,
        parent_window_id: Window,
        depth: u8,
        x: i16,
        y: i16,
        width: u16,
        height: u16,
        border_width: u16,
        class: Class,
        visual_id: Visual,
    };

    pub fn serialize(buf: [*]u8, args: Args, options: window.Options) u16 {
        buf[0] = @intFromEnum(Opcode.create_window);
        buf[1] = args.depth;

        // buf[2-3] is the len, set at the end of the function

        writeIntNative(u32, buf + 4, @intFromEnum(args.window_id));
        writeIntNative(u32, buf + 8, @intFromEnum(args.parent_window_id));
        writeIntNative(i16, buf + 12, args.x);
        writeIntNative(i16, buf + 14, args.y);
        writeIntNative(u16, buf + 16, args.width);
        writeIntNative(u16, buf + 18, args.height);
        writeIntNative(u16, buf + 20, args.border_width);
        writeIntNative(u16, buf + 22, @intFromEnum(args.class));
        writeIntNative(u32, buf + 24, @intFromEnum(args.visual_id));

        var request_len: u16 = non_option_len;
        var option_mask: window.OptionMask = .{};

        inline for (std.meta.fields(window.Options)) |field| {
            if (!isDefaultValue(options, field)) {
                writeIntNative(u32, buf + request_len, optionToU32(@field(options, field.name)));
                @field(option_mask, field.name) = 1;
                request_len += 4;
            }
        }

        writeIntNative(u32, buf + 28, @bitCast(option_mask));
        std.debug.assert((request_len & 0x3) == 0);
        writeIntNative(u16, buf + 2, request_len >> 2);
        return request_len;
    }
};

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

pub const map_window = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, window_id: Window) void {
        buf[0] = @intFromEnum(Opcode.map_window);
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
    pub const max_len = non_option_len + (std.meta.fields(Options).len * 4);
    // 7 possible 4-byte options
    comptime {
        std.debug.assert(7 == std.meta.fields(Options).len);
    }

    pub const Args = struct {
        window_id: Window,
    };

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

    pub fn serialize(buf: [*]u8, args: Args, options: Options) u16 {
        buf[0] = @intFromEnum(Opcode.configure_window);
        buf[1] = 0; // unused
        // buf[2-3] is the len, set at the end of the function
        writeIntNative(u32, buf + 4, @intFromEnum(args.window_id));
        // buf[8-9] is the option_mask, set at the end of the function

        var request_len: u16 = non_option_len;
        var option_mask: OptionMask = .{};

        inline for (std.meta.fields(Options)) |field| {
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

pub const query_tree = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, window_id: Window) void {
        buf[0] = @intFromEnum(Opcode.query_tree);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(window_id));
    }

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
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.intern_atom);
        buf[1] = @intFromBool(args.only_if_exists);
        const len = getLen(args.name.len);
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u16, buf + 4, args.name.len);
        @memcpy(buf[8..][0..args.name.len], args.name.nativeSlice());
    }
};

pub const change_property = struct {
    pub const non_list_len =
        2 // opcode and mode
        + 2 // request length
        + 4 // window ID
        + 4 // property atom
        + 4 // type
        + 1 // value format
        + 3 // unused
        + 4 // value length
    ;
    pub const Mode = enum(u8) {
        replace = 0,
        prepend = 1,
        append = 2,
    };
    pub fn withFormat(comptime T: type) type {
        switch (T) {
            u8, u16, u32 => {},
            else => @compileError("change_property is only compatible with u8, u16, u32 value formats but saw " ++ @typeName(T)),
        }

        return struct {
            pub fn getLen(value_count: u16) u16 {
                return non_list_len + std.mem.alignForward(u16, value_count * @sizeOf(T), 4);
            }
            pub const Args = struct {
                mode: Mode,
                window_id: Window,
                property: Atom, // atom
                /// atom
                ///
                /// This value isn't interpreted by the X server. It's just passed back
                /// to the client application when using the `get_property` request.
                type: Atom,
                values: Slice(u16, [*]const T),
            };
            pub fn serialize(buf: [*]u8, args: Args) void {
                buf[0] = @intFromEnum(Opcode.change_property);
                buf[1] = @intFromEnum(args.mode);
                const request_len = getLen(args.values.len);
                std.debug.assert(request_len & 0x3 == 0);
                writeIntNative(u16, buf + 2, request_len >> 2);
                writeIntNative(u32, buf + 4, @intFromEnum(args.window_id));
                writeIntNative(u32, buf + 8, @intFromEnum(args.property));
                writeIntNative(u32, buf + 12, @intFromEnum(args.type));
                writeIntNative(u32, buf + 16, @sizeOf(T) * 8);
                buf[17] = 0; // unused
                buf[18] = 0; // unused
                buf[19] = 0; // unused
                writeIntNative(u32, buf + 20, args.values.len);
                @memcpy(
                    @as([*]align(1) T, @ptrCast(buf + 24))[0..args.values.len],
                    args.values.nativeSlice(),
                );
            }
        };
    }
};

pub const get_property = struct {
    pub const len = 24;
    pub const Args = struct {
        window_id: Window,
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
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.get_property);
        buf[1] = @intFromBool(args.delete);
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(args.window_id));
        writeIntNative(u32, buf + 8, @intFromEnum(args.property));
        writeIntNative(u32, buf + 12, @intFromEnum(args.type));
        writeIntNative(u32, buf + 16, args.offset);
        writeIntNative(u32, buf + 20, args.len);
    }
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

pub const grab_pointer = struct {
    pub const len = 24;
    pub const Args = struct {
        owner_events: bool,
        grab_window: Window,
        event_mask: PointerEventMask,
        pointer_mode: SyncMode,
        keyboard_mode: SyncMode,
        confine_to: Window,
        cursor: Cursor,
        time: Timestamp,
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.grab_pointer);
        buf[1] = if (args.owner_events) 1 else 0;
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(args.grab_window));
        writeIntNative(u16, buf + 8, @bitCast(args.event_mask));
        buf[10] = @intFromEnum(args.pointer_mode);
        buf[11] = @intFromEnum(args.keyboard_mode);
        writeIntNative(u32, buf + 12, @intFromEnum(args.confine_to));
        writeIntNative(u32, buf + 16, @intFromEnum(args.cursor));
        writeIntNative(u32, buf + 20, @intFromEnum(args.time));
    }
};

pub const ungrab_pointer = struct {
    pub const len = 8;
    pub const Args = struct {
        time: Timestamp, // 0 is CurrentTime
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.ungrab_pointer);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(args.time));
    }
};

pub const warp_pointer = struct {
    pub const len = 24;
    pub const Args = struct {
        src_window: Window,
        dst_window: Window,
        src_x: i16,
        src_y: i16,
        src_width: u16,
        src_height: u16,
        dst_x: i16,
        dst_y: i16,
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.warp_pointer);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(args.src_window));
        writeIntNative(u32, buf + 8, @intFromEnum(args.dst_window));
        writeIntNative(i16, buf + 12, args.src_x);
        writeIntNative(i16, buf + 14, args.src_y);
        writeIntNative(u16, buf + 16, args.src_width);
        writeIntNative(u16, buf + 18, args.src_height);
        writeIntNative(i16, buf + 20, args.dst_x);
        writeIntNative(i16, buf + 22, args.dst_y);
    }
};

pub const open_font = struct {
    pub const non_list_len =
        2 // opcode and unused
        + 2 // request length
        + 4 // font id
        + 4 // name length (2 bytes) and 2 unused bytes
    ;
    pub fn getLen(name_len: u16) u16 {
        return non_list_len + std.mem.alignForward(u16, name_len, 4);
    }
    pub fn serialize(buf: [*]u8, font_id: Font, name: Slice(u16, [*]const u8)) void {
        buf[0] = @intFromEnum(Opcode.open_font);
        buf[1] = 0; // unused
        const len = getLen(name.len);
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(font_id));
        writeIntNative(u16, buf + 8, name.len);
        buf[10] = 0; // unused
        buf[11] = 0; // unused
        @memcpy(buf[12..][0..name.len], name.nativeSlice());
    }
};

pub const close_font = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, font_id: Font) void {
        buf[0] = @intFromEnum(Opcode.close_font);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(font_id));
    }
};

pub const query_font = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, font: Fontable) void {
        buf[0] = @intFromEnum(Opcode.query_font);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(font));
    }
};

pub const query_text_extents = struct {
    pub const non_list_len =
        2 // opcode and odd_length
        + 2 // request length
        + 4 // font_id
    ;
    pub fn getLen(u16_char_count: u16) u16 {
        return non_list_len + std.mem.alignForward(u16, u16_char_count * 2, 4);
    }
    pub fn serialize(buf: [*]u8, font_id: Fontable, text: Slice(u16, [*]const u16)) void {
        buf[0] = @intFromEnum(Opcode.query_text_extents);
        buf[1] = @intCast(text.len % 2); // odd_length
        const len = getLen(text.len);
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(font_id));
        var off: usize = 8;
        for (text.ptr[0..text.len]) |c| {
            std.mem.writeInt(u16, (buf + off)[0..2], c, .big);
            off += 2;
        }
        std.debug.assert(len == std.mem.alignForward(usize, off, 4));
    }
};

pub const list_fonts = struct {
    pub const non_list_len =
        2 // opcode and unused
        + 2 // request length
        + 2 // max names
        + 2 // pattern length
    ;
    pub fn getLen(pattern_len: u16) u16 {
        return non_list_len + std.mem.alignForward(u16, pattern_len, 4);
    }
    pub fn serialize(buf: [*]u8, max_names: u16, pattern: Slice(u16, [*]const u8)) void {
        buf[0] = @intFromEnum(Opcode.list_fonts);
        buf[1] = 0; // unused
        const len = getLen(pattern.len);
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u16, buf + 4, max_names);
        writeIntNative(u16, buf + 6, pattern.len);
        @memcpy(buf[8..][0..pattern.len], pattern.nativeSlice());
    }
};

pub const get_font_path = struct {
    pub const len = 4;
    pub fn serialize(buf: [*]u8) void {
        buf[0] = @intFromEnum(Opcode.get_font_path);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
    }
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
    // subwindow_mode clip_by_children
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
pub fn createOrChangeGcSerialize(buf: [*]u8, gc_id: GraphicsContext, variant: GcVariant, options: GcOptions) u16 {
    buf[0] = switch (variant) {
        .create => @intFromEnum(Opcode.create_gc),
        .change => @intFromEnum(Opcode.change_gc),
    };
    buf[1] = 0; // unused
    // buf[2-3] is the len, set at the end of the function

    writeIntNative(u32, buf + 4, @intFromEnum(gc_id));
    const non_option_len: u16 = blk: {
        switch (variant) {
            .create => |drawable_id| {
                writeIntNative(u32, buf + 8, @intFromEnum(drawable_id));
                break :blk create_gc.non_option_len;
            },
            .change => break :blk change_gc.non_option_len,
        }
    };
    var option_mask: GcOptionMask = .{};
    var request_len: u16 = non_option_len;

    inline for (std.meta.fields(GcOptions)) |field| {
        if (!isDefaultValue(options, field)) {
            writeIntNative(u32, buf + request_len, optionToU32(@field(options, field.name)));
            @field(option_mask, field.name) = 1;
            request_len += 4;
        }
    }

    writeIntNative(u32, buf + non_option_len - 4, @bitCast(option_mask));
    std.debug.assert((request_len & 0x3) == 0);
    writeIntNative(u16, buf + 2, request_len >> 2);
    return request_len;
}

pub const create_pixmap = struct {
    pub const len = 16;
    pub const Args = struct {
        id: Pixmap,
        drawable_id: Drawable,
        depth: u8,
        width: u16,
        height: u16,
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.create_pixmap);
        buf[1] = args.depth;
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(args.id));
        writeIntNative(u32, buf + 8, @intFromEnum(args.drawable_id));
        writeIntNative(u16, buf + 12, args.width);
        writeIntNative(u16, buf + 14, args.height);
    }
};

pub const free_pixmap = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, id: Pixmap) void {
        buf[0] = @intFromEnum(Opcode.free_pixmap);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(id));
    }
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

pub const create_gc = struct {
    pub const non_option_len =
        2 // opcode and unused
        + 2 // request length
        + 4 // gc id
        + 4 // drawable id
        + 4 // option mask
    ;
    pub const max_len = non_option_len + (gc_option_count * 4);
    pub fn serialize(buf: [*]u8, arg: struct { gc_id: GraphicsContext, drawable_id: Drawable }, options: GcOptions) u16 {
        return createOrChangeGcSerialize(buf, arg.gc_id, .{ .create = arg.drawable_id }, options);
    }
};

pub const change_gc = struct {
    pub const non_option_len =
        2 // opcode and unused
        + 2 // request length
        + 4 // gc id
        + 4 // option mask
    ;
    pub const max_len = non_option_len + (gc_option_count * 4);

    pub fn serialize(buf: [*]u8, gc_id: GraphicsContext, options: GcOptions) u16 {
        return createOrChangeGcSerialize(buf, gc_id, .change, options);
    }
};

pub const clear_area = struct {
    pub const len = 16;
    pub fn serialize(buf: [*]u8, exposures: bool, window_id: Window, area: Rectangle) void {
        buf[0] = @intFromEnum(Opcode.clear_area);
        buf[1] = if (exposures) 1 else 0;
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(window_id));
        writeIntNative(i16, buf + 8, area.x);
        writeIntNative(i16, buf + 10, area.y);
        writeIntNative(u16, buf + 12, area.width);
        writeIntNative(u16, buf + 14, area.height);
    }
};

pub const copy_area = struct {
    pub const len = 28;
    pub const Args = struct {
        src_drawable_id: Drawable,
        dst_drawable_id: Drawable,
        gc_id: GraphicsContext,
        src_x: i16,
        src_y: i16,
        dst_x: i16,
        dst_y: i16,
        width: u16,
        height: u16,
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.copy_area);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(args.src_drawable_id));
        writeIntNative(u32, buf + 8, @intFromEnum(args.dst_drawable_id));
        writeIntNative(u32, buf + 12, @intFromEnum(args.gc_id));
        writeIntNative(i16, buf + 16, args.src_x);
        writeIntNative(i16, buf + 18, args.src_y);
        writeIntNative(i16, buf + 20, args.dst_x);
        writeIntNative(i16, buf + 22, args.dst_y);
        writeIntNative(u16, buf + 24, args.width);
        writeIntNative(u16, buf + 26, args.height);
    }
};

pub const Point = struct {
    x: i16,
    y: i16,
};

pub const poly_line = struct {
    pub const non_list_len =
        2 // opcode and coordinate-mode
        + 2 // request length
        + 4 // drawable id
        + 4 // gc id
    ;
    pub fn getLen(point_count: u16) u16 {
        return non_list_len + (point_count * 4);
    }
    pub const Args = struct {
        coordinate_mode: enum(u8) { origin = 0, previous = 1 },
        drawable_id: Drawable,
        gc_id: GraphicsContext,
    };
    pub fn serialize(buf: [*]u8, args: Args, points: []const Point) void {
        buf[0] = @intFromEnum(Opcode.poly_line);
        buf[1] = @intFromEnum(args.coordinate_mode);
        // buf[2-3] is the len, set at the end of the function
        writeIntNative(u32, buf + 4, @intFromEnum(args.drawable_id));
        writeIntNative(u32, buf + 8, @intFromEnum(args.gc_id));
        var request_len: u16 = non_list_len;
        for (points) |point| {
            writeIntNative(i16, buf + request_len + 0, point.x);
            writeIntNative(i16, buf + request_len + 2, point.y);
            request_len += 4;
        }
        std.debug.assert((request_len & 0x3) == 0);
        writeIntNative(u16, buf + 2, request_len >> 2);
        std.debug.assert(getLen(@intCast(points.len)) == request_len);
    }
};

pub const Rectangle = extern struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
};
comptime {
    std.debug.assert(@sizeOf(Rectangle) == 8);
}

const poly_rectangle_common = struct {
    pub const non_list_len =
        2 // opcode and unused
        + 2 // request length
        + 4 // drawable id
        + 4 // gc id
    ;
    pub fn getLen(rectangle_count: u16) u16 {
        return non_list_len + (rectangle_count * 8);
    }
    pub const Args = struct {
        drawable_id: Drawable,
        gc_id: GraphicsContext,
    };
    pub fn serialize(buf: [*]u8, args: Args, rectangles: []const Rectangle, opcode: u8) void {
        buf[0] = opcode;
        buf[1] = 0; // unused
        // buf[2-3] is the len, set at the end of the function
        writeIntNative(u32, buf + 4, @intFromEnum(args.drawable_id));
        writeIntNative(u32, buf + 8, @intFromEnum(args.gc_id));
        var request_len: u16 = non_list_len;
        for (rectangles) |rectangle| {
            writeIntNative(i16, buf + request_len + 0, rectangle.x);
            writeIntNative(i16, buf + request_len + 2, rectangle.y);
            writeIntNative(u16, buf + request_len + 4, rectangle.width);
            writeIntNative(u16, buf + request_len + 6, rectangle.height);
            request_len += 8;
        }
        std.debug.assert((request_len & 0x3) == 0);
        writeIntNative(u16, buf + 2, request_len >> 2);
        std.debug.assert(getLen(@intCast(rectangles.len)) == request_len);
    }
};

pub const poly_rectangle = struct {
    pub const non_list_len = poly_rectangle_common.non_list_len;
    pub const getLen = poly_rectangle_common.getLen;
    pub const Args = poly_rectangle_common.Args;
    pub fn serialize(buf: [*]u8, args: Args, rectangles: []const Rectangle) void {
        poly_rectangle_common.serialize(buf, args, rectangles, @intFromEnum(Opcode.poly_rectangle));
    }
};

pub const poly_fill_rectangle = struct {
    pub const non_list_len = poly_rectangle_common.non_list_len;
    pub const getLen = poly_rectangle_common.getLen;
    pub const Args = poly_rectangle_common.Args;
    pub fn serialize(buf: [*]u8, args: Args, rectangles: []const Rectangle) void {
        poly_rectangle_common.serialize(buf, args, rectangles, @intFromEnum(Opcode.poly_fill_rectangle));
    }
};

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
        drawable_id: Drawable,
        gc_id: GraphicsContext,
        width: u16,
        height: u16,
        x: i16,
        y: i16,
        left_pad: u8,
        depth: u8,
    };
    pub const data_offset = non_list_len;
    pub fn serialize(buf: [*]u8, data: Slice(u18, [*]const u8), args: Args) void {
        serializeNoDataCopy(buf, data.len, args);
        @memcpy(buf[data_offset..], data);
    }
    pub fn serializeNoDataCopy(buf: [*]u8, data_len: u18, args: Args) void {
        buf[0] = @intFromEnum(Opcode.put_image);
        buf[1] = @intFromEnum(args.format);
        const request_len = getLen(data_len);
        std.debug.assert((request_len & 0x3) == 0);
        writeIntNative(u16, buf + 2, @as(u16, @intCast(request_len >> 2)));
        writeIntNative(u32, buf + 4, @intFromEnum(args.drawable_id));
        writeIntNative(u32, buf + 8, @intFromEnum(args.gc_id));
        writeIntNative(u16, buf + 12, args.width);
        writeIntNative(u16, buf + 14, args.height);
        writeIntNative(i16, buf + 16, args.x);
        writeIntNative(i16, buf + 18, args.y);
        buf[20] = args.left_pad;
        buf[21] = args.depth;
        buf[22] = 0; // unused
        buf[23] = 0; // unused
        comptime {
            std.debug.assert(24 == data_offset);
        }
    }
};

pub const get_image = struct {
    pub const len =
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
    pub const Args = struct {
        format: enum(u8) {
            xy_pixmap = 1,
            z_pixmap = 2,
        },
        drawable_id: Drawable,
        x: i16,
        y: i16,
        width: u16,
        height: u16,
        plane_mask: u32,
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.get_image);
        buf[1] = @intFromEnum(args.format);
        writeIntNative(u16, buf + 2, @as(u16, @intCast(len >> 2)));
        writeIntNative(u32, buf + 4, @intFromEnum(args.drawable_id));
        writeIntNative(i16, buf + 8, args.x);
        writeIntNative(i16, buf + 10, args.y);
        writeIntNative(u16, buf + 12, args.width);
        writeIntNative(u16, buf + 14, args.height);
        writeIntNative(u32, buf + 16, args.plane_mask);
    }

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

pub const image_text8 = struct {
    pub const non_list_len =
        2 // opcode and string_length
        + 2 // request length
        + 4 // drawable id
        + 4 // gc id
        + 4 // x, y coordinates
    ;
    pub fn getLen(text_len: u8) u16 {
        return non_list_len + std.mem.alignForward(u16, text_len, 4);
    }
    pub const max_len = getLen(255);
    pub const Args = struct {
        drawable_id: Drawable,
        gc_id: GraphicsContext,
        x: i16,
        y: i16,
    };
    pub const text_offset = non_list_len;
    pub fn serialize(buf: [*]u8, text: Slice(u8, [*]const u8), args: Args) void {
        serializeNoTextCopy(buf, text.len, args);
        @memcpy(buf[text_offset..][0..text.len], text.nativeSlice());
    }
    pub fn serializeNoTextCopy(buf: [*]u8, text_len: u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.image_text8);
        buf[1] = text_len;
        const request_len = getLen(text_len);
        std.debug.assert(request_len & 0x3 == 0);
        writeIntNative(u16, buf + 2, request_len >> 2);
        writeIntNative(u32, buf + 4, @intFromEnum(args.drawable_id));
        writeIntNative(u32, buf + 8, @intFromEnum(args.gc_id));
        writeIntNative(i16, buf + 12, args.x);
        writeIntNative(i16, buf + 14, args.y);
    }
};

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

pub const get_keyboard_mapping = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, first_keycode: u8, count: u8) void {
        buf[0] = @intFromEnum(Opcode.get_keyboard_mapping);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        buf[4] = first_keycode;
        buf[5] = count;
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
    _, // allow unknown errors
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
    ciculate_request = 27,
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
pub const ServerMsgKind = enum(u8) {
    err = @intFromEnum(ErrorKind.err),
    reply = @intFromEnum(ReplyKind.reply),
    key_press = @intFromEnum(EventCode.key_press),
    key_release = @intFromEnum(EventCode.key_release),
    button_press = @intFromEnum(EventCode.button_press),
    button_release = @intFromEnum(EventCode.button_release),
    motion_notify = @intFromEnum(EventCode.motion_notify),
    enter_notify = @intFromEnum(EventCode.enter_notify),
    leave_notify = @intFromEnum(EventCode.leave_notify),
    focus_in = @intFromEnum(EventCode.focus_in),
    focus_out = @intFromEnum(EventCode.focus_out),
    keymap_notify = @intFromEnum(EventCode.keymap_notify),
    expose = @intFromEnum(EventCode.expose),
    graphics_exposure = @intFromEnum(EventCode.graphics_exposure),
    no_exposure = @intFromEnum(EventCode.no_exposure),
    visibility_notify = @intFromEnum(EventCode.visibility_notify),
    create_notify = @intFromEnum(EventCode.create_notify),
    destroy_notify = @intFromEnum(EventCode.destroy_notify),
    unmap_notify = @intFromEnum(EventCode.unmap_notify),
    map_notify = @intFromEnum(EventCode.map_notify),
    map_request = @intFromEnum(EventCode.map_request),
    reparent_notify = @intFromEnum(EventCode.reparent_notify),
    configure_notify = @intFromEnum(EventCode.configure_notify),
    configure_request = @intFromEnum(EventCode.configure_request),
    gravity_notify = @intFromEnum(EventCode.gravity_notify),
    resize_request = @intFromEnum(EventCode.resize_request),
    circulate_notify = @intFromEnum(EventCode.circulate_notify),
    ciculate_request = @intFromEnum(EventCode.ciculate_request),
    property_notify = @intFromEnum(EventCode.property_notify),
    selection_clear = @intFromEnum(EventCode.selection_clear),
    selection_request = @intFromEnum(EventCode.selection_request),
    selection_notify = @intFromEnum(EventCode.selection_notify),
    colormap_notify = @intFromEnum(EventCode.colormap_notify),
    client_message = @intFromEnum(EventCode.client_message),
    mapping_notify = @intFromEnum(EventCode.mapping_notify),
    _,
};

pub const ServerMsgTaggedUnion = union(enum) {
    unhandled: *align(4) ServerMsg.Generic,
    err: *align(4) ServerMsg.Error,
    reply: *align(4) ServerMsg.Reply,
    key_press: *align(4) Event.KeyPress,
    key_release: *align(4) Event.KeyRelease,
    button_press: *align(4) Event.ButtonPress,
    button_release: *align(4) Event.ButtonRelease,
    enter_notify: *align(4) Event.EnterNotify,
    leave_notify: *align(4) Event.LeaveNotify,
    motion_notify: *align(4) Event.MotionNotify,
    keymap_notify: *align(4) Event.KeymapNotify,
    expose: *align(4) Event.Expose,
    no_exposure: *align(4) Event.NoExposure,
    map_notify: *align(4) Event.MapNotify,
    reparent_notify: *align(4) Event.ReparentNotify,
    configure_notify: *align(4) Event.ConfigureNotify,
    mapping_notify: *align(4) Event.MappingNotify,
};
pub fn serverMsgTaggedUnion(msg_ptr: [*]align(4) u8) ServerMsgTaggedUnion {
    switch (@as(ServerMsgKind, @enumFromInt(0x7f & msg_ptr[0]))) {
        .err => return .{ .err = @ptrCast(msg_ptr) },
        .reply => return .{ .reply = @ptrCast(msg_ptr) },
        .key_press => return .{ .key_press = @ptrCast(msg_ptr) },
        .key_release => return .{ .key_release = @ptrCast(msg_ptr) },
        .button_press => return .{ .button_press = @ptrCast(msg_ptr) },
        .button_release => return .{ .button_release = @ptrCast(msg_ptr) },
        .enter_notify => return .{ .enter_notify = @ptrCast(msg_ptr) },
        .leave_notify => return .{ .leave_notify = @ptrCast(msg_ptr) },
        .motion_notify => return .{ .motion_notify = @ptrCast(msg_ptr) },
        .keymap_notify => return .{ .keymap_notify = @ptrCast(msg_ptr) },
        .expose => return .{ .expose = @ptrCast(msg_ptr) },
        .no_exposure => return .{ .no_exposure = @ptrCast(msg_ptr) },
        .map_notify => return .{ .map_notify = @ptrCast(msg_ptr) },
        .reparent_notify => return .{ .reparent_notify = @ptrCast(msg_ptr) },
        .configure_notify => return .{ .configure_notify = @ptrCast(msg_ptr) },
        .mapping_notify => return .{ .mapping_notify = @ptrCast(msg_ptr) },
        else => return .{ .unhandled = @ptrCast(msg_ptr) },
    }
}

pub const ServerMsg = extern union {
    generic: Generic,
    err: Error,
    reply: Reply,
    query_font: QueryFont,
    query_text_extents: QueryTextExtents,
    list_fonts: ListFonts,
    get_font_path: GetFontPath,
    get_keyboard_mapping: GetKeyboardMapping,
    query_extension: QueryExtension,

    pub const Generic = extern struct {
        kind: ServerMsgKind,
        reserve_min: [31]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(Generic) == 32);
    }
    pub const Reply = extern struct {
        response_type: ReplyKind,
        flexible: u8,
        sequence: u16,
        word_len: u32, // length in 4-byte words
        reserve_min: [24]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(Reply) == 32);
    }

    comptime {
        std.debug.assert(@sizeOf(Error) == 32);
    }
    pub const Error = extern struct {
        reponse_type: ErrorKind,
        code: ErrorCode,
        sequence: u16,
        generic: u32,
        minor_opcode: u16,
        major_opcode: Opcode,
        data: [21]u8,

        pub const Length = Error;
        pub const Name = Error;
        pub const OpenFont = FontError;

        comptime {
            std.debug.assert(@sizeOf(FontError) == 32);
        }
        pub const FontError = extern struct {
            reponse_type: ErrorKind,
            code: ErrorCodeFont,
            sequence: u16,
            bad_resource_id: Resource,
            minor_opcode: u16,
            major_opcode: Opcode,
            unused2: [21]u8,
        };
    };

    pub const GetFontPath = StringList;
    pub const ListFonts = StringList;
    pub const StringList = extern struct {
        kind: ReplyKind,
        unused: u8,
        sequence: u16,
        string_list_word_size: u32,
        string_count: u16,
        unused_pad: [22]u8,
        string_list: [0]u8,
        pub fn iterator(self: *const StringList) StringListIterator {
            const ptr: [*]u8 = @ptrFromInt(@intFromPtr(self) + 32);
            return StringListIterator{ .mem = ptr[0 .. self.string_list_word_size * 4], .left = self.string_count, .offset = 0 };
        }
    };
    comptime {
        std.debug.assert(@sizeOf(StringList) == 32);
    }

    pub const QueryFont = extern struct {
        kind: ReplyKind,
        unused: u8,
        sequence: u16,
        reply_word_size: u32,
        min_bounds: CharInfo,
        unused2: u32,
        max_bounds: CharInfo,
        unused3: u32,
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
        property_list: [0]FontProp,

        // workaround @offsetOf not working on 0-sized fields
        //const property_list_offset = @offsetOf(QueryFont, "property_list");
        const property_list_offset = 60;

        pub fn properties(self: *const QueryFont) []FontProp {
            const ptr: [*]FontProp = @ptrFromInt(@intFromPtr(self) + property_list_offset);
            return ptr[0..self.property_count];
        }
        pub fn lists(self: QueryFont) Lists {
            return Lists{ .property_list_byte_len = self.property_count * @sizeOf(FontProp) };
        }
        pub const Lists = struct {
            property_list_byte_len: usize,
            pub fn inBounds(self: Lists, msg: QueryFont) bool {
                const msg_len = 32 + (4 * msg.reply_word_size);
                const msg_list_capacity = msg_len - property_list_offset;
                const actual_list_len = self.property_list_byte_len + (msg.info_count * @sizeOf(CharInfo));
                return actual_list_len <= msg_list_capacity;
            }
            pub fn charInfos(self: Lists, msg: *const QueryFont) []CharInfo {
                const ptr: [*]CharInfo = @ptrFromInt(@intFromPtr(msg) + property_list_offset + self.property_list_byte_len);
                return ptr[0..msg.info_count];
            }
        };
    };

    comptime {
        std.debug.assert(@sizeOf(QueryTextExtents) == 32);
    }
    pub const QueryTextExtents = extern struct {
        kind: ReplyKind,
        draw_direction: u8, // 0=left-to-right, 1=right-to-left
        sequence: u16,
        reply_word_size: u32, // should be 0
        font_ascent: i16,
        font_descent: i16,
        overal_ascent: i16,
        overall_descent: i16,
        overall_width: i32,
        overall_left: i32,
        overall_right: i32,
        unused: [4]u8,
    };

    pub const GetKeyboardMapping = extern struct {
        kind: ReplyKind,
        syms_per_code: u8,
        sequence: u16,
        reply_word_size: u32,
        unused: [24]u8,
        sym_list: [0]u32,

        const sym_list_offset = 32;
        // this isn't working because of a compiler bug
        //comptime { std.debug.assert(@offsetOf(GetKeyboardMapping, "sym_list") == sym_list_offset); }
        comptime {
            std.debug.assert(@sizeOf(GetKeyboardMapping) == sym_list_offset);
        }

        pub fn syms(self: *const GetKeyboardMapping) []u32 {
            const ptr: [*]u32 = @ptrFromInt(@intFromPtr(self) + sym_list_offset);
            return ptr[0..self.reply_word_size];
        }
    };

    comptime {
        std.debug.assert(@sizeOf(QueryExtension) == 32);
    }
    pub const QueryExtension = extern struct {
        kind: ReplyKind,
        unused: u8,
        sequence: u16,
        reply_word_size: u32, // should be 0
        present: u8,
        major_opcode: u8,
        first_event: u8,
        first_error: u8,
        unused_pad: [20]u8,
    };

    pub const EventKind = enum(u8) {
        key_press = 2,
        _,
    };
};

pub const MappingNotifyRequest = enum(u8) {
    modifier = 0,
    keyboard = 1,
    pointer = 2,
    _,
};

pub const Event = extern union {
    generic: Generic,
    key_press: KeyPress,
    key_release: KeyRelease,
    button_press: ButtonPress,
    button_release: ButtonRelease,
    exposure: Expose,
    mapping_notify: MappingNotify,
    no_exposure: Generic,

    pub const KeyPress = Key;
    pub const KeyRelease = Key;
    pub const ButtonPress = KeyOrButtonOrMotion;
    pub const ButtonRelease = KeyOrButtonOrMotion;
    pub const EnterNotify = Generic; // TODO
    pub const LeaveNotify = Generic; // TODO
    pub const MotionNotify = KeyOrButtonOrMotion; // TODO
    pub const KeymapNotify = Generic; // TODO

    pub const Generic = extern struct {
        code: EventCode,
        detail: u8,
        sequence: u16,
        data: [28]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(Generic) == 32);
    }

    pub const Key = extern struct {
        code: u8,
        keycode: u8,
        sequence: u16,
        time: Timestamp,
        root: Window,
        event: Window,
        child: Window,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: KeyButtonMask,
        same_screen: u8,
        unused: u8,
    };
    comptime {
        std.debug.assert(@sizeOf(Key) == 32);
    }

    pub const KeyOrButtonOrMotion = extern struct {
        code: u8,
        detail: u8,
        sequence: u16,
        time: Timestamp,
        root: Window,
        event: Window,
        child: Window,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: KeyButtonMask,
        same_screen: u8,
        unused: u8,
    };
    comptime {
        std.debug.assert(@sizeOf(KeyOrButtonOrMotion) == 32);
    }

    pub const Expose = extern struct {
        code: u8,
        unused: u8,
        sequence: u16,
        window: Window,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        count: u16,
        unused_pad: [14]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(Expose) == 32);
    }

    comptime {
        std.debug.assert(@sizeOf(MappingNotify) == 32);
    }
    pub const MappingNotify = extern struct {
        code: u8,
        unused: u8,
        sequence: u16,
        request: MappingNotifyRequest,
        first_keycode: u8,
        count: u8,
        _: [25]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(NoExposure) == 32);
    }
    pub const NoExposure = extern struct {
        code: u8,
        unused: u8,
        sequence: u16,
        drawable: Drawable,
        minor_opcode: u16,
        major_opcode: u8,
        _: [21]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(MapNotify) == 32);
    }
    pub const MapNotify = extern struct {
        code: u8,
        unused: u8,
        sequence: u16,
        parent: Window,
        window: Window,
        _: [20]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(ReparentNotify) == 32);
    }
    pub const ReparentNotify = extern struct {
        code: u8,
        unused: u8,
        sequence: u16,
        event: Window,
        window: Window,
        parent: Window,
        x: i16,
        y: i16,
        override_redirect: u8,
        _: [11]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(ConfigureNotify) == 32);
    }
    pub const ConfigureNotify = extern struct {
        code: u8,
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
        override_redirect: u8,
        _: [5]u8,
    };
};
comptime {
    std.debug.assert(@sizeOf(Event) == 32);
}

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

const FontProp = extern struct {
    atom: Atom,
    value: u32,
};
comptime {
    std.debug.assert(@sizeOf(FontProp) == 8);
}

const CharInfo = extern struct {
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

pub fn parseMsgLen(buf: [32]u8) u32 {
    switch (buf[0] & 0x7f) {
        @intFromEnum(ServerMsgKind.err) => return 32,
        @intFromEnum(ServerMsgKind.reply) => return 32 + (4 * readIntNative(u32, buf[4..8])),
        2...34 => return 32,
        else => |t| std.debug.panic("handle reply type {}", .{t}),
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
};

comptime {
    std.debug.assert(@sizeOf(ScreenDepth) == 8);
}
pub const ScreenDepth = extern struct {
    depth: u8,
    unused0: u8,
    visual_type_count: u16,
    unused1: u32,
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

pub fn readFull(reader: anytype, buf: []u8) (@TypeOf(reader).Error || error{EndOfStream})!void {
    std.debug.assert(buf.len > 0);
    var total_received: usize = 0;
    while (true) {
        const last_received = try reader.read(buf[total_received..]);
        if (last_received == 0)
            return error.EndOfStream;
        total_received += last_received;
        if (total_received == buf.len)
            break;
    }
}

pub const ReadConnectSetupHeaderOptions = struct {
    read_timeout_ms: i32 = -1,
};

pub fn readConnectSetupHeader(reader: anytype, options: ReadConnectSetupHeaderOptions) !ConnectSetup.Header {
    var header: ConnectSetup.Header = undefined;
    if (options.read_timeout_ms == -1) {
        try readFull(reader, header.asBuf());
        return header;
    }
    @panic("read timeout not implemented");
}

pub const FailReason = struct {
    buf: [256]u8,
    len: u8,
    pub fn format(
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
        .decls = info.decls,
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

        pub fn readFailReason(self: @This(), reader: anytype) FailReason {
            var result: FailReason = undefined;
            result.len = @intCast(reader.readAll(result.buf[0..self.status_opt]) catch |read_err|
                (std.fmt.bufPrint(&result.buf, "failed to read failure reason: {s}", .{@errorName(read_err)}) catch |err| switch (err) {
                    error.NoSpaceLeft => unreachable,
                }).len);
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
        return @alignCast(@ptrCast(self.buf.ptr + format_list_offset));
    }
    pub fn getFormatList(self: @This(), format_list_offset: u32, format_list_limit: u32) ![]align(4) Format {
        if (format_list_limit > self.buf.len)
            return error.XMalformedReply_FormatCountTooBig;
        return self.getFormatListPtr(format_list_offset)[0..@divExact(format_list_limit - format_list_offset, @sizeOf(Format))];
    }

    pub fn getFirstScreenPtr(self: @This(), format_list_limit: u32) *align(4) Screen {
        return @alignCast(@ptrCast(self.buf.ptr + format_list_limit));
    }
    pub fn getScreensPtr(self: @This(), format_list_limit: u32) [*]align(4) Screen {
        return @alignCast(@ptrCast(self.buf.ptr + format_list_limit));
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

pub fn readOneMsgAlloc(allocator: std.mem.Allocator, reader: anytype) ![]align(4) u8 {
    var buf = try allocator.allocWithOptions(u8, 32, 4, null);
    errdefer allocator.free(buf);
    const len = try readOneMsg(reader, buf);
    if (len > 32) {
        buf = try allocator.realloc(buf, len);
        try readOneMsgFinish(reader, buf);
    }
    return buf;
}

/// The caller must check whether the length returned is larger than the provided `buf`.
/// If it is, then only the first 32-bytes have been read.  The caller can allocate a new
/// buffer large enough to accomodate and finish reading the message by copying the first
/// 32 bytes to the new buffer then calling `readOneMsgFinish`.
pub fn readOneMsg(reader: anytype, buf: []align(4) u8) !u32 {
    std.debug.assert(buf.len >= 32);
    try readFull(reader, buf[0..32]);
    const msg_len = parseMsgLen(buf[0..32].*);
    if (msg_len > 32 and msg_len < buf.len) {
        try readOneMsgFinish(reader, buf[0..msg_len]);
    }
    return msg_len;
}

pub fn readOneMsgFinish(reader: anytype, buf: []align(4) u8) !void {
    //
    // for now this is the only case where this should happen
    // I've added this check to audit the code again if this every changes
    //
    std.debug.assert(buf[0] == @intFromEnum(ServerMsgKind.reply));
    try readFull(reader, buf[32..]);
}

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
