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

// Expose some helpful stuff
pub const MappedFile = @import("MappedFile.zig");
pub const charset = @import("charset.zig");
pub const Charset = charset.Charset;
pub const DoubleBuffer = @import("DoubleBuffer.zig");
pub const ContiguousReadBuffer = @import("ContiguousReadBuffer.zig");
pub const Slice = @import("x/slice.zig").Slice;
pub const keymap = @import("keymap.zig");

pub const TcpBasePort = 6000;

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

const ParsedDisplay = struct {
    protoLen: u16, // if not specified, then hostIndex will be 0 causing this to be empty
    hostLimit: u16,
    display_num: u32, // TODO: is there a maximum display number?
    preferredScreen: ?u32,

    pub fn asFilePath(self: @This(), ptr: [*]const u8) ?[]const u8 {
        if (ptr[0] != '/') return null;
        return ptr[0 .. self.hostLimit];
    }
    pub fn protoSlice(self: @This(), ptr: [*]const u8) []const u8 {
        return ptr[0..self.protoLen];
    }
    fn hostIndex(self: @This()) u16 {
        return if (self.protoLen == 0) 0 else (self.protoLen + 1);
    }
    pub fn hostSlice(self: @This(), ptr: [*]const u8) []const u8 {
        return ptr[self.hostIndex()..self.hostLimit];
    }
    pub fn equals(self: @This(), other: @This()) bool {
        return self.protoLen == other.protoLen
            and self.hostLimit == other.hostLimit
            and self.display_num == other.display_num
            and optEql(self.preferredScreen, other.preferredScreen);
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

// Return: display if set, otherwise the environment variable DISPLAY
//pub fn getDisplay(display: anytype) @TypeOf(display) {
//    if (display.length == 0) {
//        const env = posix.getenv("DISPLAY");
//        if (@TypeOf(display) == []const u8)
//            return env else "";
//        @compileError("display string type not implemented");
//    }
//}


pub const InvalidDisplayError = error {
    IsEmpty, // TODO: is this an error?
    HasMultipleProtocols,
    IsTooLarge,
    NoDisplayNumber,
    BadDisplayNumber,
    BadScreenNumber,
};

// display format: [PROTOCOL/]HOST:DISPLAYNUM[.SCREEN]
// assumption: display.len > 0
pub fn parseDisplay(display: []const u8) InvalidDisplayError!ParsedDisplay {
    if (display.len == 0) return InvalidDisplayError.IsEmpty;
    if (display.len >= std.math.maxInt(u16))
        return InvalidDisplayError.IsTooLarge;

    var parsed : ParsedDisplay = .{
        .protoLen = 0,
        .hostLimit = undefined,
        .display_num = undefined,
        .preferredScreen = undefined,
    };
    var index : u16 = 0;

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
                .protoLen = 0,
                .hostLimit = @intCast(display.len),
                .display_num = 0,
                .preferredScreen = null,
            };
            if (parsed.protoLen > 0)
                return InvalidDisplayError.HasMultipleProtocols;
            parsed.protoLen = index;
        }
        index += 1;
        if (index == display.len)
            return InvalidDisplayError.NoDisplayNumber;
    }

    parsed.hostLimit = index;
    index += 1;
    if (index == display.len)
        return InvalidDisplayError.NoDisplayNumber;

    while (true) {
        const c = display[index];
        if (c == '.')
            break;
        index += 1;
        if (index == display.len)
            break;
    }

    //std.debug.warn("num '{}'\n", .{display[parsed.hostLimit + 1..index]});
    parsed.display_num = std.fmt.parseInt(u32, display[parsed.hostLimit + 1..index], 10) catch
        return InvalidDisplayError.BadDisplayNumber;
    if (index == display.len) {
        parsed.preferredScreen = null;
    } else {
        index += 1;
        parsed.preferredScreen = std.fmt.parseInt(u32, display[index..], 10) catch
            return InvalidDisplayError.BadScreenNumber;
    }
    return parsed;
}

fn testParseDisplay(display: []const u8, proto: []const u8, host: []const u8, display_num: u32, screen: ?u32) !void {
    const parsed = try parseDisplay(display);
    try testing.expect(std.mem.eql(u8, proto, parsed.protoSlice(display.ptr)));
    try testing.expect(std.mem.eql(u8, host, parsed.hostSlice(display.ptr)));
    try testing.expectEqual(display_num, parsed.display_num);
    try testing.expectEqual(screen, parsed.preferredScreen);
}

test "parseDisplay" {
    // no need to test the empty string case, it triggers an assert and a client passing
    // one is a bug that needs to be fixed
    try testing.expectError(InvalidDisplayError.HasMultipleProtocols, parseDisplay("a//"));
    try testing.expectError(InvalidDisplayError.NoDisplayNumber, parseDisplay("0"));
    try testing.expectError(InvalidDisplayError.NoDisplayNumber, parseDisplay("0/"));
    try testing.expectError(InvalidDisplayError.NoDisplayNumber, parseDisplay("0/1"));
    try testing.expectError(InvalidDisplayError.NoDisplayNumber, parseDisplay(":"));

    try testing.expectError(InvalidDisplayError.BadDisplayNumber, parseDisplay(":a"));
    try testing.expectError(InvalidDisplayError.BadDisplayNumber, parseDisplay(":0a"));
    try testing.expectError(InvalidDisplayError.BadDisplayNumber, parseDisplay(":0a."));
    try testing.expectError(InvalidDisplayError.BadDisplayNumber, parseDisplay(":0a.0"));
    try testing.expectError(InvalidDisplayError.BadDisplayNumber, parseDisplay(":1x"));
    try testing.expectError(InvalidDisplayError.BadDisplayNumber, parseDisplay(":1x."));
    try testing.expectError(InvalidDisplayError.BadDisplayNumber, parseDisplay(":1x.10"));

    try testing.expectError(InvalidDisplayError.BadScreenNumber, parseDisplay(":1.x"));
    try testing.expectError(InvalidDisplayError.BadScreenNumber, parseDisplay(":1.0x"));
    // TODO: should this be an error or no????
    //try testing.expectError(InvalidDisplayError.BadScreenNumber, parseDisplay(":1."));

    try testParseDisplay("proto/host:123.456", "proto", "host", 123, 456);
    try testParseDisplay("host:123.456", "", "host", 123, 456);
    try testParseDisplay(":123.456", "", "", 123, 456);
    try testParseDisplay(":123", "", "", 123, null);
    try testParseDisplay("a/:43", "a", "", 43, null);
    try testParseDisplay("/", "", "/", 0, null);
    try testParseDisplay("/some/file/path/x0", "", "/some/file/path/x0", 0, null);
}

const ConnectError = error {
    UnsupportedProtocol,
};

pub fn isUnixProtocol(optionalProtocol: ?[]const u8) bool {
    if (optionalProtocol) |protocol| {
        return std.mem.eql(u8, "unix", protocol);
    }
    return false;
}

// The application should probably have access to the DISPLAY
// for logging purposes.  This might be too much abstraction.
//pub fn connect() !posix.socket_t {
//    const display = posix.getenv("DISPLAY") orelse
//        return connectExplicit(null, null, 0);
//    return connectDisplay(display);
//}

//pub const ConnectDisplayError = InvalidDisplayError;
pub fn connect(display: []const u8, parsed: ParsedDisplay) !posix.socket_t {
    const optional_host: ?[]const u8 = blk: {
        const host_slice = parsed.hostSlice(display.ptr);
        break :blk if (host_slice.len == 0) null else host_slice;
    };
    const optional_proto: ?[]const u8 = blk: {
        const proto_slice = parsed.protoSlice(display.ptr);
        break :blk if (proto_slice.len == 0) null else proto_slice;
    };
    return connectExplicit(optional_host, optional_proto, parsed.display_num);
}


fn defaultTcpHost(optional_host: ?[]const u8) []const u8 {
    return if (optional_host) |host| host else "localhost";
}
fn displayToTcpPort(display_num: u32) error{DisplayNumberOutOfRange}!u16 {
    const port = TcpBasePort + display_num;
    if (port > std.math.maxInt(u16))
        return error.DisplayNumberOutOfRange;
    return @intCast(port);
}

pub fn connectExplicit(optional_host: ?[]const u8, optional_protocol: ?[]const u8, display_num: u32) !posix.socket_t {

    if (optional_protocol) |proto| {
        if (std.mem.eql(u8, proto, "unix")) {
            if (optional_host) |_|
                @panic("TODO: DISPLAY is unix protocol with a host? Is this possible?");
            return connectUnixDisplayNum(display_num);
        }
        if (std.mem.eql(u8, proto, "tcp") or std.mem.eql(u8, proto, "inet"))
            return connectTcp(defaultTcpHost(optional_host), try displayToTcpPort(display_num), .{});
        if (std.mem.eql(u8, proto, "inet6"))
            return connectTcp(defaultTcpHost(optional_host), try displayToTcpPort(display_num), .{ .inet6 = true });
        return error.UnhandledDisplayProtocol;
    }

    if (optional_host) |host| {
        if (std.mem.eql(u8, host, "unix")) {
            // I don't want to carry this complexity if I don't have to, so for now I'll just make it an error
            std.log.err("host is 'unix' this might mean 'unix domain socket' but not sure, giving up for now", .{});
            return error.NotSureIWantToSupportAmbiguousUnixHost;
        }
        if (host[0] == '/')
            return connectUnixPath(host);
        return connectTcp(host, try displayToTcpPort(display_num), .{});
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

pub const ConnectTcpOptions = struct {
    inet6: bool = false,
};
pub fn connectTcp(name: []const u8, port: u16, options: ConnectTcpOptions) !posix.socket_t {
    if (options.inet6) return error.Inet6NotImplemented;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const list = try std.net.getAddressList(arena.allocator(), name, port);
    defer list.deinit();
    for (list.addrs) |addr| {
        return (std.net.tcpConnectToAddress(addr) catch |err| switch (err) {
            error.ConnectionRefused => {
                continue;
            },
            else => return err,
        }).handle;
    }
    if (list.addrs.len == 0) return error.UnknownHostName;
    return posix.ConnectError.ConnectionRefused;
}

pub fn disconnect(sock: posix.socket_t) void {
    posix.shutdown(sock, .both) catch {}; // ignore any error here
    posix.close(sock);
}

pub fn connectUnixDisplayNum(display_num: u32) !posix.socket_t {
    const path_prefix = "/tmp/.X11-unix/X";
    var addr = posix.sockaddr.un { .family = posix.AF.UNIX, .path = undefined };
    const path = std.fmt.bufPrintZ(
        &addr.path,
        "{s}{}",
        .{path_prefix, display_num},
    ) catch unreachable;
    return connectUnixAddr(&addr, path.len);
}

pub fn connectUnixPath(socket_path: []const u8) !posix.socket_t {
    var addr = posix.sockaddr.un { .family = posix.AF.UNIX, .path = undefined };
    const path = std.fmt.bufPrintZ(
        &addr.path,
        "{s}",
        .{socket_path},
    ) catch unreachable;
    return connectUnixAddr(&addr, path.len);
}

pub fn connectUnixAddr(addr: *const posix.sockaddr.un, path_len: usize) !posix.socket_t {
    const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(sock);

    // TODO: should we set any socket options?
    const addr_len: posix.socklen_t = @intCast(@offsetOf(posix.sockaddr.un, "path") + path_len + 1);
    posix.connect(sock, @ptrCast(addr), addr_len) catch |err| switch (err) {
        // TODO: handle some of these errors and translate them so we can "fall back" to tcp
        //       for example, we might handle error.FileNotFound, but I would probably
        //       translate most errors to custom ones so we only fallback when we get
        //       an error on the "connect" call itself
        else => |e| {
            std.debug.panic("TODO: connect failed with {}, need to implement fallback to TCP", .{e});
            return e;
        }
    };
    return sock;
}


//pub const ClientHello = extern struct {
//    byte_order : u8 = if (builtin.endian == .Big) BigEndian else LittleEndian,
//    proto_major_version : u16,
//    proto_minor_version : u16,
//};

pub fn ArrayPointer(comptime T: type) type {
    const err = "ArrayPointer not implemented for " ++ @typeName(T);
    switch (@typeInfo(T)) {
        .Pointer => |info| {
            switch (info.size) {
                .One => {
                    switch (@typeInfo(info.child)) {
                        .Array => |array_info| {
                            return @Type(std.builtin.Type { .Pointer = .{
                                .size = .Many,
                                .is_const = true,
                                .is_volatile = false,
                                .alignment = @alignOf(array_info.child),
                                .address_space = info.address_space,
                                .child = array_info.child,
                                .is_allowzero = false,
                                .sentinel = array_info.sentinel,
                            }});
                        },
                        else => @compileError("here"),
                    }
                },
                .Slice => {
                    return @Type(std.builtin.Type { .Pointer = .{
                        .size = .Many,
                        .is_const = info.is_const,
                        .is_volatile = info.is_volatile,
                        .alignment = info.alignment,
                        .address_space = info.address_space,
                        .child = info.child,
                        .is_allowzero = info.is_allowzero,
                        .sentinel = info.sentinel,
                    }});
                },
                else => @compileError(err),
            }
        },
        else => @compileError(err),
    }
}

pub fn slice(comptime LenType: type, s: anytype) Slice(LenType, ArrayPointer(@TypeOf(s)))  {
    switch (@typeInfo(@TypeOf(s))) {
        .Pointer => |info| {
            switch (info.size) {
                .One => {
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
                .Slice => return .{ .ptr = s.ptr, .len = @intCast(s.len) },
                else => @compileError("cannot slice"),
            }
        },
        else => @compileError("cannot slice"),
    }
}


// returns the number of padding bytes to add to `value` to get to a multiple of 4
// TODO: profile this? is % operator expensive?
// NOTE: using std.mem.alignForward instead
//fn pad4(comptime T: type, value: T) T {
//    return (4 - (value % 4)) % 4;
//}

pub const AuthFilename = struct {
    str: []const u8,
    owned: bool,

    pub fn deinit(self: AuthFilename, allocator: std.mem.Allocator) void {
        if (self.owned) {
            allocator.free(self.str);
        }
    }
};

// returns the auth filename only if it exists.
pub fn getAuthFilename(allocator: std.mem.Allocator) !?AuthFilename {
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "XAUTHORITY")) |filename| {
            return .{ .str = filename, .owned = true };
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => {},
            else => |e| return e,
        }
        // TODO: is there a default path on windows?
        return null;
    }

    if (posix.getenv("XAUTHORITY")) |e| {
        if (std.fs.cwd().accessZ(e, .{})) {
            return .{ .str = e, .owned = false };
        } else |err| switch (err) {
            error.FileNotFound => return error.BadXAuthorityEnv,
            else => return err,
        }
    }

    if (posix.getenv("HOME")) |e| {
        const path = try std.fs.path.joinZ(allocator, &.{ e, ".Xauthority" });
        errdefer allocator.free(path);
        if (std.fs.cwd().accessZ(path, .{})) {
            return .{ .str = path, .owned = true };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    return null;
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
                try writer.print("{}.{}.{}.{}", .{d[0], d[1], d[2], d[3]});
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
    display_num: ?u32,

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
    display_num: ?u32,
    name_end: usize,
    data_end: usize,
    pub fn addr(self: AuthIteratorEntry, mem: []const u8) []const u8 {
        return mem[self.addr_start..self.addr_end];
    }
    pub fn name(self: AuthIteratorEntry, mem: []const u8) []const u8 {
        return mem[self.name_start..self.name_end];
    }
    pub fn data(self: AuthIteratorEntry, mem: []const u8) []const u8 {
        return mem[self.name_end + 2..self.data_end];
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
        const addr_len = std.mem.readInt(u16, self.mem[self.idx + 2..][0..2], .big);
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
        const num: ?u32 = blk: {
            if (num_str.len == 0) break :blk null;
            break :blk std.fmt.parseInt(u32, num_str, 10) catch return error.InvalidAuthFile;
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
            + std.mem.alignForward(u32, auth_data_len, 4)
            ;
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
        const off : u16 = 12 + std.mem.alignForward(u16, auth_name.len, 4);
        @memcpy(buf[off..][0..auth_data.len], auth_data.nativeSlice());
        std.debug.assert(
            getLen(auth_name.len, auth_data.len) ==
            off + std.mem.alignForward(u16, auth_data.len, 4)
        );
    }
};

test "ConnectSetupMessage" {
    const auth_name = comptime slice(u16, @as([]const u8, "hello"));
    const auth_data = comptime slice(u16, @as([]const u8, "there"));
    const len = comptime connect_setup.getLen(auth_name.len, auth_data.len);
    var buf: [len]u8 = undefined;
    connect_setup.serialize(&buf, 1, 1, auth_name, auth_data);
}

pub const Opcode = enum(u8) {
    create_window = 1,
    change_window_attributes = 2,
    map_window = 8,
    intern_atom = 16,
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
    const default_value_ptr = @as(?*align(1) const field.type, @ptrCast(field.default_value)) orelse
        @compileError("isDefaultValue was called on field '" ++ field.name ++ "' which has no default value");
    switch (@typeInfo(field.type)) {
        .Optional => {
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
        .Bool => return @intFromBool(value),
        .Enum => return @intFromEnum(value),
        else => {},
    }
    if (T == u32) return value;
    if (T == ?u32) return value.?;
    if (T == u16) return @intCast(value);
    @compileError("TODO: implement optionToU32 for type: " ++ @typeName(T));
}

pub const event = struct {
    pub const key_press          = (1 <<  0);
    pub const key_release        = (1 <<  1);
    pub const button_press       = (1 <<  2);
    pub const button_release     = (1 <<  3);
    pub const enter_window       = (1 <<  4);
    pub const leave_window       = (1 <<  5);
    pub const pointer_motion     = (1 <<  6);
    pub const pointer_motion_hint= (1 <<  7);
    pub const button1_motion     = (1 <<  8);
    pub const button2_motion     = (1 <<  9);
    pub const button3_motion     = (1 << 10);
    pub const button4_motion     = (1 << 11);
    pub const button5_motion     = (1 << 12);
    pub const button_motion      = (1 << 13);
    pub const keymap_state       = (1 << 14);
    pub const exposure           = (1 << 15);
    pub const visibility_change  = (1 << 16);
    pub const structure_notify   = (1 << 17);
    pub const resize_redirect    = (1 << 18);
    pub const substructure_notify= (1 << 19);
    pub const substructure_redirect= (1 << 20);
    pub const focus_change       = (1 << 21);
    pub const property_change    = (1 << 22);
    pub const colormap_change    = (1 << 23);
    pub const owner_grab_button  = (1 << 24);
    pub const unused_mask: u32   = (0x7f << 25);
};

pub const pointer_event = struct {
    pub const button_press       = event.button_press;
    pub const button_release     = event.button_release;
    pub const enter_window       = event.enter_window;
    pub const leave_window       = event.leave_window;
    pub const pointer_motion     = event.pointer_motion;
    pub const pointer_motion_hint= event.pointer_motion_hint;
    pub const button1_motion     = event.button1_motion;
    pub const button2_motion     = event.button2_motion;
    pub const button3_motion     = event.button3_motion;
    pub const button4_motion     = event.button4_motion;
    pub const button5_motion     = event.button5_motion;
    pub const button_motion      = event.button_motion;
    pub const keymap_state       = event.keymap_state;
    pub const unused_mask: u32   = 0xFFFF8003;
};

pub const window = struct {
    pub const option_flags = struct {
        pub const bg_pixmap         : u32 = (1 <<  0);
        pub const bg_pixel          : u32 = (1 <<  1);
        pub const border_pixmap     : u32 = (1 <<  2);
        pub const border_pixel      : u32 = (1 <<  3);
        pub const bit_gravity       : u32 = (1 <<  4);
        pub const win_gravity       : u32 = (1 <<  5);
        pub const backing_store     : u32 = (1 <<  6);
        pub const backing_planes    : u32 = (1 <<  7);
        pub const backing_pixel     : u32 = (1 <<  8);
        pub const override_redirect : u32 = (1 <<  9);
        pub const save_under        : u32 = (1 << 10);
        pub const event_mask        : u32 = (1 << 11);
        pub const dont_propagate    : u32 = (1 << 12);
        pub const colormap          : u32 = (1 << 13);
        pub const cursor            : u32 = (1 << 14);
    };

    pub const BgPixmap = enum(u32) { none = 0, copy_from_parent = 1 };
    pub const BorderPixmap = enum(u32) { copy_from_parent = 0 };
    pub const BackingStore = enum(u32) { not_useful = 0, when_mapped = 1, always = 2 };
    pub const Colormap = enum(u32) { copy_from_parent = 0 };
    pub const Cursor = enum(u32) { none = 0 };
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
        event_mask: u32 = 0,
        dont_propagate: u32 = 0,
        colormap: NonExhaustive(Colormap) = .copy_from_parent,
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
    pub const max_len = non_option_len + (15 * 4);  // 15 possible 4-byte options

    pub const Class = enum(u8) {
        copy_from_parent = 0,
        input_output = 1,
        input_only = 2,
    };
    pub const Args = struct {
        window_id: u32,
        parent_window_id: u32,
        depth: u8,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        border_width: u16,
        class: Class,
        visual_id: u32,
    };

    pub fn serialize(buf: [*]u8, args: Args, options: window.Options) u16 {
        buf[0] = @intFromEnum(Opcode.create_window);
        buf[1] = args.depth;

        // buf[2-3] is the len, set at the end of the function

        writeIntNative(u32, buf + 4, args.window_id);
        writeIntNative(u32, buf + 8, args.parent_window_id);
        writeIntNative(u16, buf + 12, args.x);
        writeIntNative(u16, buf + 14, args.y);
        writeIntNative(u16, buf + 16, args.width);
        writeIntNative(u16, buf + 18, args.height);
        writeIntNative(u16, buf + 20, args.border_width);
        writeIntNative(u16, buf + 22, @intFromEnum(args.class));
        writeIntNative(u32, buf + 24, args.visual_id);

        var request_len: u16 = non_option_len;
        var option_mask: u32 = 0;

        inline for (std.meta.fields(window.Options)) |field| {
            if (!isDefaultValue(options, field)) {
                writeIntNative(u32, buf + request_len, optionToU32(@field(options, field.name)));
                option_mask |= @field(window.option_flags, field.name);
                request_len += 4;
            }
        }

        writeIntNative(u32, buf + 28, option_mask);
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
    pub const max_len = non_option_len + (15 * 4);  // 15 possible 4-byte options
    pub fn serialize(buf: [*]u8, window_id: u32, options: window.Options) u16 {
        buf[0] = @intFromEnum(Opcode.change_window_attributes);
        buf[1] = 0; // unused

        // buf[2-3] is the len, set at the end of the function

        writeIntNative(u32, buf + 4, window_id);
        var request_len: u16 = non_option_len;
        var option_mask: u32 = 0;

        inline for (std.meta.fields(window.Options)) |field| {
            if (!isDefaultValue(options, field)) {
                writeIntNative(u32, buf + request_len, optionToU32(@field(options, field.name)));
                option_mask |= @field(window.option_flags, field.name);
                request_len += 4;
            }
        }

        writeIntNative(u32, buf + 8, option_mask);
        std.debug.assert((request_len & 0x3) == 0);
        writeIntNative(u16, buf + 2, request_len >> 2);
        return request_len;
    }
};

pub const map_window = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, window_id: u32) void {
        buf[0] = @intFromEnum(Opcode.map_window);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, window_id);
    }
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

pub const SyncMode = enum(u1) { synchronous = 0, asynchronous = 1 };

pub const grab_pointer = struct {
    pub const len = 24;
    pub const Args = struct {
        owner_events: bool,
        grab_window: u32,
        event_mask: u16,
        pointer_mode: SyncMode,
        keyboard_mode: SyncMode,
        confine_to: u32, // 0 is none
        cursor: u32, // 0 is none
        time: u32, // 0 is CurrentTime
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.grab_pointer);
        buf[1] = if (args.owner_events) 1 else 0;
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, args.grab_window);
        writeIntNative(u16, buf + 8, args.event_mask);
        buf[10] = @intFromEnum(args.pointer_mode);
        buf[11] = @intFromEnum(args.keyboard_mode);
        writeIntNative(u32, buf + 12, args.confine_to);
        writeIntNative(u32, buf + 16, args.cursor);
        writeIntNative(u32, buf + 20, args.time);
    }
};

pub const ungrab_pointer = struct {
    pub const len = 8;
    pub const Args = struct {
        time: u32, // 0 is CurrentTime
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.ungrab_pointer);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, args.time);
    }
};

pub const warp_pointer = struct {
    pub const len = 24;
    pub const Args = struct {
        src_window: u32, // 0 means none
        dst_window: u32, // 0 means none
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
        writeIntNative(u32, buf + 4, args.src_window);
        writeIntNative(u32, buf + 8, args.dst_window);
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
    pub fn serialize(buf: [*]u8, font_id: u32, name: Slice(u16, [*]const u8)) void {
        buf[0] = @intFromEnum(Opcode.open_font);
        buf[1] = 0; // unused
        const len = getLen(name.len);
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, font_id);
        writeIntNative(u16, buf + 8, name.len);
        buf[10] = 0; // unused
        buf[11] = 0; // unused
        @memcpy(buf[12..][0..name.len], name.nativeSlice());
    }
};

pub const close_font = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, font_id: u32) void {
        buf[0] = @intFromEnum(Opcode.close_font);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, font_id);
    }
};

pub const query_font = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, font: u32) void {
        buf[0] = @intFromEnum(Opcode.query_font);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, font);
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
    pub fn serialize(buf: [*]u8, font_id: u32, text: Slice(u16, [*]const u16)) void {
        buf[0] = @intFromEnum(Opcode.query_text_extents);
        buf[1] = @intCast(text.len % 2); // odd_length
        const len = getLen(text.len);
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, font_id);
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
pub const gc_option_flag = struct {
    pub const function           : u32 = (1 <<  0);
    pub const plane_mask         : u32 = (1 <<  1);
    pub const foreground         : u32 = (1 <<  2);
    pub const background         : u32 = (1 <<  3);
    pub const line_width         : u32 = (1 <<  4);
    pub const line_style         : u32 = (1 <<  5);
    pub const cap_style          : u32 = (1 <<  6);
    pub const join_style         : u32 = (1 <<  7);
    pub const fill_style         : u32 = (1 <<  8);
    pub const fill_rule          : u32 = (1 <<  9);
    pub const title              : u32 = (1 << 10);
    pub const stipple            : u32 = (1 << 11);
    pub const tile_stipple_x_origin : u32 = (1 << 12);
    pub const tile_stipple_y_origin : u32 = (1 << 13);
    pub const font               : u32 = (1 << 14);
    pub const subwindow_mode     : u32 = (1 << 15);
    pub const graphics_exposures : u32 = (1 << 16);
    pub const clip_x_origin      : u32 = (1 << 17);
    pub const clip_y_origin      : u32 = (1 << 18);
    pub const clip_mask          : u32 = (1 << 19);
    pub const dash_offset        : u32 = (1 << 20);
    pub const dashes             : u32 = (1 << 21);
    pub const arc_mode           : u32 = (1 << 22);
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
    // tile ?
    // stipple ?
    // tile_stipple_x_origin 0
    // tile_stipple_y_origin 0
    font: ?u32 = null,
    // font <server dependent>
    // subwindow_mode clip_by_children
    graphics_exposures: bool = true,
    // clip_x_origin 0
    // clip_y_origin 0
    // clip_mask none
    // dash_offset 0
    // dashes the list 4, 4
};

const GcVariant = union(enum) {
    create: u32,
    change: void,
};
pub fn createOrChangeGcSerialize(buf: [*]u8, gc_id: u32, variant: GcVariant, options: GcOptions) u16 {
    buf[0] = switch (variant) { .create => @intFromEnum(Opcode.create_gc), .change => @intFromEnum(Opcode.change_gc) };
    buf[1] = 0; // unused
    // buf[2-3] is the len, set at the end of the function

    writeIntNative(u32, buf + 4, gc_id);
    const non_option_len: u16 = blk: {
        switch (variant) {
            .create => |drawable_id| {
                writeIntNative(u32, buf + 8, drawable_id);
                break :blk create_gc.non_option_len;
            },
            .change => break :blk change_gc.non_option_len,
        }
    };
    var option_mask: u32 = 0;
    var request_len: u16 = non_option_len;

    inline for (std.meta.fields(GcOptions)) |field| {
        if (!isDefaultValue(options, field)) {
            writeIntNative(u32, buf + request_len, optionToU32(@field(options, field.name)));
            option_mask |= @field(gc_option_flag, field.name);
            request_len += 4;
        }
    }

    writeIntNative(u32, buf + non_option_len - 4, option_mask);
    std.debug.assert((request_len & 0x3) == 0);
    writeIntNative(u16, buf + 2, request_len >> 2);
    return request_len;
}

pub const create_pixmap = struct {
    pub const len = 16;
    pub const Args = struct {
        id: u32,
        drawable_id: u32,
        depth: u8,
        width: u16,
        height: u16,
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @intFromEnum(Opcode.create_pixmap);
        buf[1] = args.depth;
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, args.id);
        writeIntNative(u32, buf + 8, args.drawable_id);
        writeIntNative(u16, buf + 12, args.width);
        writeIntNative(u16, buf + 14, args.height);
    }
};

pub const free_pixmap = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, id: u32) void {
        buf[0] = @intFromEnum(Opcode.free_pixmap);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, id);
    }
};

pub const create_colormap = struct {
    pub const len = 16;
    pub const Args = struct {
        id: u32,
        window_id: u32,
        visual_id: u32,
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
    pub fn serialize(buf: [*]u8, id: u32) void {
        buf[0] = @intFromEnum(Opcode.free_colormap);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, id);
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
    pub fn serialize(buf: [*]u8, arg: struct { gc_id: u32, drawable_id: u32 }, options: GcOptions) u16 {
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

    pub fn serialize(buf: [*]u8, gc_id: u32, options: GcOptions) u16 {
        return createOrChangeGcSerialize(buf, gc_id, .change, options);
    }
};

pub const clear_area = struct {
    pub const len = 16;
    pub fn serialize(buf: [*]u8, exposures: bool, window_id: u32, area: Rectangle) void {
        buf[0] = @intFromEnum(Opcode.clear_area);
        buf[1] = if (exposures) 1 else 0;
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, window_id);
        writeIntNative(i16, buf + 8, area.x);
        writeIntNative(i16, buf + 10, area.y);
        writeIntNative(u16, buf + 12, area.width);
        writeIntNative(u16, buf + 14, area.height);
    }
};

pub const copy_area = struct {
    pub const len = 28;
    pub const Args = struct {
        src_drawable_id: u32,
        dst_drawable_id: u32,
        gc_id: u32,
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
        writeIntNative(u32, buf + 4, args.src_drawable_id);
        writeIntNative(u32, buf + 8, args.dst_drawable_id);
        writeIntNative(u32, buf + 12, args.gc_id);
        writeIntNative(i16, buf + 16, args.src_x);
        writeIntNative(i16, buf + 18, args.src_y);
        writeIntNative(i16, buf + 20, args.dst_x);
        writeIntNative(i16, buf + 22, args.dst_y);
        writeIntNative(u16, buf + 24, args.width);
        writeIntNative(u16, buf + 26, args.height);
    }
};

pub const Point = struct {
    x: i16, y: i16,
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
        drawable_id: u32,
        gc_id: u32,
    };
    pub fn serialize(buf: [*]u8, args: Args, points: []const Point) void {
        buf[0] = @intFromEnum(Opcode.poly_line);
        buf[1] = @intFromEnum(args.coordinate_mode);
        // buf[2-3] is the len, set at the end of the function
        writeIntNative(u32, buf + 4, args.drawable_id);
        writeIntNative(u32, buf + 8, args.gc_id);
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

pub const Rectangle = struct {
    x: i16, y: i16, width: u16, height: u16,
};
comptime { std.debug.assert(@sizeOf(Rectangle) == 8); }

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
        drawable_id: u32,
        gc_id: u32,
    };
    pub fn serialize(buf: [*]u8, args: Args, rectangles: []const Rectangle, opcode: u8) void {
        buf[0] = opcode;
        buf[1] = 0; // unused
        // buf[2-3] is the len, set at the end of the function
        writeIntNative(u32, buf + 4, args.drawable_id);
        writeIntNative(u32, buf + 8, args.gc_id);
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
        drawable_id: u32,
        gc_id: u32,
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
        writeIntNative(u32, buf + 4, args.drawable_id);
        writeIntNative(u32, buf + 8, args.gc_id);
        writeIntNative(u16, buf + 12, args.width);
        writeIntNative(u16, buf + 14, args.height);
        writeIntNative(i16, buf + 16, args.x);
        writeIntNative(i16, buf + 18, args.y);
        buf[20] = args.left_pad;
        buf[21] = args.depth;
        buf[22] = 0; // unused
        buf[23] = 0; // unused
        comptime { std.debug.assert(24 == data_offset); }
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
        drawable_id: u32,
        gc_id: u32,
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
        writeIntNative(u32, buf + 4, args.drawable_id);
        writeIntNative(u32, buf + 8, args.gc_id);
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
    return @as(*const align(1) T, @ptrCast(buf)).*;
}


pub fn recvFull(sock: posix.socket_t, buf: []u8) !void {
    std.debug.assert(buf.len > 0);
    var total_received : usize = 0;
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
    key_press         = @intFromEnum(EventCode.key_press),
    key_release       = @intFromEnum(EventCode.key_release),
    button_press      = @intFromEnum(EventCode.button_press),
    button_release    = @intFromEnum(EventCode.button_release),
    motion_notify     = @intFromEnum(EventCode.motion_notify),
    enter_notify      = @intFromEnum(EventCode.enter_notify),
    leave_notify      = @intFromEnum(EventCode.leave_notify),
    focus_in          = @intFromEnum(EventCode.focus_in),
    focus_out         = @intFromEnum(EventCode.focus_out),
    keymap_notify     = @intFromEnum(EventCode.keymap_notify),
    expose            = @intFromEnum(EventCode.expose),
    graphics_exposure = @intFromEnum(EventCode.graphics_exposure),
    no_exposure       = @intFromEnum(EventCode.no_exposure),
    visibility_notify = @intFromEnum(EventCode.visibility_notify),
    create_notify     = @intFromEnum(EventCode.create_notify),
    destroy_notify    = @intFromEnum(EventCode.destroy_notify),
    unmap_notify      = @intFromEnum(EventCode.unmap_notify),
    map_notify        = @intFromEnum(EventCode.map_notify),
    map_request       = @intFromEnum(EventCode.map_request),
    reparent_notify   = @intFromEnum(EventCode.reparent_notify),
    configure_notify  = @intFromEnum(EventCode.configure_notify),
    configure_request = @intFromEnum(EventCode.configure_request),
    gravity_notify    = @intFromEnum(EventCode.gravity_notify),
    resize_request    = @intFromEnum(EventCode.resize_request),
    circulate_notify  = @intFromEnum(EventCode.circulate_notify),
    ciculate_request  = @intFromEnum(EventCode.ciculate_request),
    property_notify   = @intFromEnum(EventCode.property_notify),
    selection_clear   = @intFromEnum(EventCode.selection_clear),
    selection_request = @intFromEnum(EventCode.selection_request),
    selection_notify  = @intFromEnum(EventCode.selection_notify),
    colormap_notify   = @intFromEnum(EventCode.colormap_notify),
    client_message    = @intFromEnum(EventCode.client_message),
    mapping_notify    = @intFromEnum(EventCode.mapping_notify),
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
    comptime { std.debug.assert(@sizeOf(Generic) == 32); }
    pub const Reply = extern struct {
        response_type: ReplyKind,
        flexible: u8,
        sequence: u16,
        word_len: u32, // length in 4-byte words
        reserve_min: [24]u8,
    };
    comptime { std.debug.assert(@sizeOf(Reply) == 32); }

    comptime { std.debug.assert(@sizeOf(Error) == 32); }
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
        pub const OpenFont = Font;

        comptime { std.debug.assert(@sizeOf(Font) == 32); }
        pub const Font = extern struct {
            reponse_type: ErrorKind,
            code: ErrorCodeFont,
            sequence: u16,
            bad_resource_id: u32,
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
            return StringListIterator { .mem = ptr[0 .. self.string_list_word_size * 4], .left = self.string_count, .offset = 0 };
        }
    };
    comptime { std.debug.assert(@sizeOf(StringList) == 32); }

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
            return ptr[0 .. self.property_count];
        }
        pub fn lists(self: QueryFont) Lists {
            return Lists { .property_list_byte_len = self.property_count * @sizeOf(FontProp) };
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
                return ptr[0 .. msg.info_count];
            }
        };
    };

    comptime { std.debug.assert(@sizeOf(QueryTextExtents) == 32); }
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
        comptime { std.debug.assert(@sizeOf(GetKeyboardMapping) == sym_list_offset); }

        pub fn syms(self: *const GetKeyboardMapping) []u32 {
            const ptr: [*]u32 = @ptrFromInt(@intFromPtr(self) + sym_list_offset);
            return ptr[0 .. self.reply_word_size];
        }
    };

    comptime { std.debug.assert(@sizeOf(QueryExtension) == 32); }
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
    comptime { std.debug.assert(@sizeOf(Generic) == 32); }

    pub const Key = extern struct {
        code: u8,
        keycode: u8,
        sequence: u16,
        time: u32,
        root: u32,
        event: u32,
        child: u32,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: u16,
        same_screen: u8,
        unused: u8,
    };
    comptime { std.debug.assert(@sizeOf(Key) == 32); }

    pub const KeyOrButtonOrMotion = extern struct {
        code: u8,
        detail: u8,
        sequence: u16,
        time: u32,
        root: u32,
        event: u32,
        child: u32,
        root_x: i16,
        root_y: i16,
        event_x: i16,
        event_y: i16,
        state: u16,
        same_screen: u8,
        unused: u8,
    };
    comptime { std.debug.assert(@sizeOf(KeyOrButtonOrMotion) == 32); }

    pub const Expose = extern struct {
        code: u8,
        unused: u8,
        sequence: u16,
        window: u32,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
        count: u16,
        unused_pad: [14]u8,
    };
    comptime { std.debug.assert(@sizeOf(Expose) == 32); }

    comptime { std.debug.assert(@sizeOf(MappingNotify) == 32); }
    pub const MappingNotify = extern struct {
        code: u8,
        unused: u8,
        sequence: u16,
        request: MappingNotifyRequest,
        first_keycode: u8,
        count: u8,
        _: [25]u8,
    };

    comptime { std.debug.assert(@sizeOf(NoExposure) == 32); }
    pub const NoExposure = extern struct {
        code: u8,
        unused: u8,
        sequence: u16,
        drawable: u32,
        minor_opcode: u16,
        major_opcode: u8,
        _: [21]u8,
    };

    comptime { std.debug.assert(@sizeOf(MapNotify) == 32); }
    pub const MapNotify = extern struct {
        code: u8,
        unused: u8,
        sequence: u16,
        parent: u32,
        window: u32,
        _: [20]u8,
    };

    comptime { std.debug.assert(@sizeOf(ReparentNotify) == 32); }
    pub const ReparentNotify = extern struct {
        code: u8,
        unused: u8,
        sequence: u16,
        event: u32,
        window: u32,
        parent: u32,
        x: i16,
        y: i16,
        override_redirect: u8,
        _: [11]u8,
    };

    comptime { std.debug.assert(@sizeOf(ConfigureNotify) == 32); }
    pub const ConfigureNotify = extern struct {
        code: u8,
        unused: u8,
        sequence: u16,
        event: u32,
        window: u32,
        above_sibling: u32,
        x: i16,
        y: i16,
        width: u16,
        height: u16,
        border_width: u16,
        override_redirect: u8,
        _: [5]u8,
    };
};
comptime { std.debug.assert(@sizeOf(Event) == 32); }

const FontProp = extern struct {
    atom: Atom,
    value: u32,
};
comptime { std.debug.assert(@sizeOf(FontProp) == 8); }

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
        const str = Slice(u8, [*]const u8) { .ptr = ptr, .len = len };
        self.left -= 1;
        self.offset = limit;
        return str;
    }
};

pub fn parseMsgLen(buf: [32]u8) u32 {
    switch (buf[0] & 0x7f) {
        @intFromEnum(ServerMsgKind.err) => return 32,
        @intFromEnum(ServerMsgKind.reply) =>
            return 32 + (4 * readIntNative(u32, buf[4..8])),
        2 ... 34 => return 32,
        else => |t| std.debug.panic("handle reply type {}", .{t}),
    }
}

pub const Format = extern struct {
    depth: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
    _: [5]u8,
};
comptime { if (@sizeOf(Format) != 8) @compileError("Format size is wrong"); }

comptime { std.debug.assert(@sizeOf(Screen) == 40); }
pub const Screen = extern struct {
    root: u32,
    colormap: u32,
    white_pixel: u32,
    black_pixel: u32,
    input_masks: u32,
    pixel_width: u16,
    pixel_height: u16,
    mm_width: u16,
    mm_height: u16,
    min_installed_maps: u16,
    max_installed_maps: u16,
    root_visual: u32,
    backing_stores: u8,
    save_unders: u8,
    root_depth: u8,
    allowed_depth_count: u8,
};

comptime { std.debug.assert(@sizeOf(ScreenDepth) == 8); }
pub const ScreenDepth = extern struct {
    depth: u8,
    unused0: u8,
    visual_type_count: u16,
    unused1: u32,
};

comptime { std.debug.assert(@sizeOf(VisualType) == 24); }
pub const VisualType = extern struct {
    pub const Class = enum(u8) {
        static_gray = 0,
        gray_scale = 1,
        static_color = 2,
        psuedo_color = 3,
        true_color = 4,
        direct_color = 5,
    };

    id: u32,
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
    var total_received : usize = 0;
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
    var header : ConnectSetup.Header = undefined;
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
        _ = fmt; _ = options;
        try writer.writeAll(self.buf[0 .. self.len]);
    }
};

pub fn NonExhaustive(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .Enum => |info| info,
        else => |info| @compileError("expected an Enum type but got a(n) " ++ @tagName(info)),
    };
    std.debug.assert(info.is_exhaustive);
    return @Type(std.builtin.Type{ .Enum = .{
        .tag_type = info.tag_type,
        .fields = info.fields,
        .decls = info.decls,
        .is_exhaustive = false,
    }});
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

    comptime { std.debug.assert(@sizeOf(Header) == 8); }
    pub const Header = extern struct {
        pub const Status = enum(u8) {
            failed = 0,
            success = 1,
            authenticate = 2,
            _
        };

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
            result.len = @intCast(reader.readAll(result.buf[0 .. self.status_opt]) catch |read_err|
                (std.fmt.bufPrint(&result.buf, "failed to read failure reason: {s}", .{@errorName(read_err)}) catch |err| switch (err) {
                    error.NoSpaceLeft => unreachable,
                }).len);
            return result;
        }
    };

    comptime { std.debug.assert(@sizeOf(Fixed) == 32); }
    /// All the connect setup fields that are at fixed offsets
    pub const Fixed = extern struct {
        release_number: u32,
        resource_id_base: u32,
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
        32 => color,
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
    try readFull(reader, buf[0 .. 32]);
    const msg_len = parseMsgLen(buf[0 .. 32].*);
    if (msg_len > 32 and msg_len < buf.len) {
        try readOneMsgFinish(reader, buf[0 .. msg_len]);
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
