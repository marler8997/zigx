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
// Error Format
// ...todo...
//
// Event Format
// ...todo...
//

const std = @import("std");
const builtin = std.builtin;
const os = std.os;

const zog = @import("zog");

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
        if (optRight) |right| {
            return false;
        } else return true;
    }
}

const ParsedDisplay = struct {
    protoLen: u16, // if not specified, then hostIndex will be 0 causing this to be empty
    hostLimit: u16,
    display_num: u32, // TODO: is there a maximum display number?
    preferredScreen: ?u32,

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

// Return: display if set, otherwise the environment variable DISPLAY
pub fn getDisplay(display: anytype) @TypeOf(display) {
    if (display.length == 0) {
        const env = std.os.getenv("DISPLAY");
        if (@TypeOf(display) == []const u8)
            return env else "";
        @compileError("display string type not implemented");
    }
}


const ParseDisplayError = error {
    MultipleProtocols,
    EmptyProtocol,
    DisplayStringTooLarge,
    NoDisplayNumber,
    BadDisplayNumber,
    BadScreenNumber,
};

// display format: [PROTOCOL/]HOST:DISPLAYNUM[.SCREEN]
// assumption: display.len > 0
pub fn parseDisplay(display: []const u8) !ParsedDisplay {
     std.debug.assert(display.len > 0);
     if (display.len >= std.math.maxInt(u16))
             return ParseDisplayError.DisplayStringTooLarge;

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
             if (parsed.protoLen > 0)
                 return ParseDisplayError.MultipleProtocols;
             if (index == 0)
                 return ParseDisplayError.EmptyProtocol;
             parsed.protoLen = index;
         }
         index += 1;
         if (index == display.len)
             return ParseDisplayError.NoDisplayNumber;
     }

     parsed.hostLimit = index;
     index += 1;
     if (index == display.len)
         return ParseDisplayError.NoDisplayNumber;

     while (true) {
         const c = display[index];
         if (c == '.')
             break;
         index += 1;
         if (index == display.len)
             break;
     }

     //std.debug.warn("num '{}'\n", .{display[parsed.hostLimit + 1..index]});
     parsed.display_num = std.fmt.parseInt(u32, display[parsed.hostLimit + 1..index], 10) catch |err|
         return ParseDisplayError.BadDisplayNumber;
     if (index == display.len) {
         parsed.preferredScreen = null;
     } else {
         index += 1;
         parsed.preferredScreen = std.fmt.parseInt(u32, display[index..], 10) catch |err|
             return ParseDisplayError.BadScreenNumber;
     }
     return parsed;
}

fn testParseDisplay(display: []const u8, proto: []const u8, host: []const u8, display_num: u32, screen: ?u32) !void {
    const parsed = try parseDisplay(display);
    std.testing.expect(std.mem.eql(u8, proto, parsed.protoSlice(display.ptr)));
    std.testing.expect(std.mem.eql(u8, host, parsed.hostSlice(display.ptr)));
    std.testing.expectEqual(display_num, parsed.display_num);
    std.testing.expectEqual(screen, parsed.preferredScreen);
}

test "parseDisplay" {
    // no need to test the empty string case, it triggers an assert and a client passing
    // one is a bug that needs to be fixed
    std.testing.expectError(ParseDisplayError.EmptyProtocol, parseDisplay("/"));
    std.testing.expectError(ParseDisplayError.MultipleProtocols, parseDisplay("a//"));
    std.testing.expectError(ParseDisplayError.NoDisplayNumber, parseDisplay("0"));
    std.testing.expectError(ParseDisplayError.NoDisplayNumber, parseDisplay("0/"));
    std.testing.expectError(ParseDisplayError.NoDisplayNumber, parseDisplay("0/1"));
    std.testing.expectError(ParseDisplayError.NoDisplayNumber, parseDisplay(":"));

    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":a"));
    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":0a"));
    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":0a."));
    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":0a.0"));
    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":1x"));
    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":1x."));
    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":1x.10"));

    std.testing.expectError(ParseDisplayError.BadScreenNumber, parseDisplay(":1.x"));
    std.testing.expectError(ParseDisplayError.BadScreenNumber, parseDisplay(":1.0x"));
    // TODO: should this be an error or no????
    //std.testing.expectError(ParseDisplayError.BadScreenNumber, parseDisplay(":1."));

    try testParseDisplay("proto/host:123.456", "proto", "host", 123, 456);
    try testParseDisplay("host:123.456", "", "host", 123, 456);
    try testParseDisplay(":123.456", "", "", 123, 456);
    try testParseDisplay(":123", "", "", 123, null);
    try testParseDisplay("a/:43", "a", "", 43, null);
}

//
//
//const Connection = struct {
//    pub fn init(display: *const Display([]const u8)) !@This() {
//
//    }
//};
//
//
//
const ConnectError = error {
    UnsupportedProtocol,
};

pub fn isUnixProtocol(optionalProtocol: ?[]const u8) bool {
    if (optionalProtocol) |protocol| {
        return std.mem.eql(u8, "unix", protocol);
    }
    return false;
}

pub fn connect(allocator: *std.mem.Allocator, optionalHost: ?[]const u8, optionalProtocol: ?[]const u8, display_num: u32) !std.os.socket_t {
    if (optionalHost) |host| {
        if (!std.mem.eql(u8, host, "unix") and !isUnixProtocol(optionalProtocol)) {
            const port = TcpBasePort + display_num;
            if (port > std.math.maxInt(u16))
                return error.DisplayNumberOutOfRange;
            return connectTcp(allocator, host, optionalProtocol, @intCast(u16, port));
        }
    }
    return error.NotImplemented;
}

pub fn connectTcp(allocator: *std.mem.Allocator, optionalHost: ?[]const u8, optionalProtocol: ?[]const u8, port: u16) !std.os.socket_t {
    var forceIpv6 = false;
    if (optionalProtocol) |protocol| {
        if (std.mem.eql(u8, protocol, "tcp")) { }
        else if (std.mem.eql(u8, protocol, "inet")) { }
        else if (std.mem.eql(u8, protocol, "inet6")) {
            forceIpv6 = true;
        } else {
            return ConnectError.UnsupportedProtocol;
        }
    }
    const host = if (optionalHost) |host| host else "localhost";
    return try tcpConnectToHost(allocator, host, port);
}

pub fn tcpConnectToHost(allocator: *std.mem.Allocator, name: []const u8, port: u16) !std.os.socket_t {
    const list = try std.net.getAddressList(allocator, name, port);
    defer list.deinit();

    if (list.addrs.len == 0) return error.UnknownHostName;

    for (list.addrs) |addr| {
        return tcpConnectToAddress(addr) catch |err| switch (err) {
            error.ConnectionRefused => {
                continue;
            },
            else => return err,
        };
    }
    return std.os.ConnectError.ConnectionRefused;
}

pub fn tcpConnectToAddress(address: std.net.Address) !std.os.socket_t {
    const nonblock = if (std.io.is_async) os.SOCK_NONBLOCK else 0;
    const sock_flags = os.SOCK_STREAM | nonblock |
        (if (builtin.os.tag == .windows) 0 else os.SOCK_CLOEXEC);
    const sockfd = try os.socket(address.any.family, sock_flags, os.IPPROTO_TCP);
    errdefer os.closeSocket(sockfd);

    if (std.io.is_async) {
        const loop = std.event.Loop.instance orelse return error.WouldBlock;
        try loop.connect(sockfd, &address.any, address.getOsSockLen());
    } else {
        try os.connect(sockfd, &address.any, address.getOsSockLen());
    }

    return sockfd;
}

//pub const ClientHello = packed struct {
//    byte_order : u8 = if (builtin.endian == .Big) BigEndian else LittleEndian,
//    proto_major_version : u16,
//    proto_minor_version : u16,
//};

pub fn Slice(comptime LenType: type, comptime Ptr: type) type { return struct {
    ptr: Ptr,
    len: LenType,
};}

pub fn ArrayPointer(comptime T: type) type {
    const err = "ArrayPointer not implemented for " ++ @typeName(T);
    switch (@typeInfo(T)) {
        .Pointer => |info| {
            switch (info.size) {
                .One => {
                    switch (@typeInfo(info.child)) {
                        .Array => |array_info| {
                            return @Type(std.builtin.TypeInfo { .Pointer = .{
                                .size = .Many,
                                .is_const = true,
                                .is_volatile = false,
                                .alignment = @alignOf(array_info.child),
                                .child = array_info.child,
                                .is_allowzero = false,
                                .sentinel = array_info.sentinel,
                            }});
                        },
                        else => @compileError("here"),
                    }
                },
                .Slice => {
                    return @Type(std.builtin.TypeInfo { .Pointer = .{
                        .size = .Many,
                        .is_const = info.is_const,
                        .is_volatile = info.is_volatile,
                        .alignment = info.alignment,
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
                            @compileError("here");
//                            return @Type(std.builtin.TypeInfo { .Pointer = .{
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
                .Slice => return .{ .ptr = s.ptr, .len = @intCast(LenType, s.len) },
                else => @compileError(err),
            }
        },
        else => @compileError(err),
    }
}


// returns the number of padding bytes to add to `value` to get to a multiple of 4
// TODO: profile this? is % operator expensive?
fn pad4(comptime T: type, value: T) T {
    return (4 - (value % 4)) % 4;
}

pub fn getConnectSetupMessageLen(auth_proto_name_len: u16, auth_proto_data_len: u16) u16 {
    return
          1 // byte-order
        + 1 // unused
        + 2 // proto_major_ver
        + 2 // proto_minor_ver
        + 2 // auth_proto_name_len
        + 2 // auth_proto_data_len
        + 2 // unused
        + auth_proto_name_len
        + pad4(u16, auth_proto_name_len)
        + auth_proto_data_len
        + pad4(u16, auth_proto_data_len)
        ;
}

pub fn makeConnectSetupMessage(buf: []u8, proto_major_ver: u16, proto_minor_ver: u16, auth_proto_name: Slice(u16, [*]const u8), auth_proto_data: Slice(u16, [*]const u8)) u16 {
    buf[0] = @as(u8, if (builtin.endian == .Big) BigEndian else LittleEndian);
    buf[1] = 0; // unused
    writeIntNative(u16, buf.ptr + 2, proto_major_ver);
    writeIntNative(u16, buf.ptr + 4, proto_minor_ver);
    writeIntNative(u16, buf.ptr + 6, auth_proto_name.len);
    writeIntNative(u16, buf.ptr + 8, auth_proto_data.len);
    writeIntNative(u16, buf.ptr + 10, 0); // unused
    @memcpy(buf.ptr + 12, auth_proto_name.ptr, auth_proto_name.len);
    const off = 12 + pad4(u16, auth_proto_name.len);
    @memcpy(buf.ptr + off, auth_proto_data.ptr, auth_proto_data.len);
    return off + auth_proto_data.len + pad4(u16, auth_proto_data.len);
}

test "a" {
    var buf : [100]u8 = undefined;
    const len = makeConnectSetupMessage(&buf, 1, 1, slice(u16, @as([]const u8, "hello")), slice(u16, @as([]const u8, "there")));
}

pub fn writeIntNative(comptime T: type, buf: [*]u8, value: T) void {
    @ptrCast(*align(1) T, buf).* = value;
}
pub fn readIntNative(comptime T: type, buf: [*]u8) T {
    return @ptrCast(*align(1) T, buf).*;
}
