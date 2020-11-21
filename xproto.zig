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
// NOTE: using std.mem.alignForward instead
//fn pad4(comptime T: type, value: T) T {
//    return (4 - (value % 4)) % 4;
//}

pub fn getConnectSetupMessageLen(auth_proto_name_len: u16, auth_proto_data_len: u16) u16 {
    return
          1 // byte-order
        + 1 // unused
        + 2 // proto_major_ver
        + 2 // proto_minor_ver
        + 2 // auth_proto_name_len
        + 2 // auth_proto_data_len
        + 2 // unused
        //+ auth_proto_name_len
        //+ pad4(u16, auth_proto_name_len)
        + std.mem.alignForward(auth_proto_name_len, 4)
        //+ auth_proto_data_len
        //+ pad4(u16, auth_proto_data_len)
        + std.mem.alignForward(auth_proto_data_len, 4)
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
    //const off = 12 + pad4(u16, auth_proto_name.len);
    const off : u16 = 12 + @intCast(u16, std.mem.alignForward(auth_proto_name.len, 4));
    @memcpy(buf.ptr + off, auth_proto_data.ptr, auth_proto_data.len);
    //return off + auth_proto_data.len + pad4(u16, auth_proto_data.len);
    return off + @intCast(u16, std.mem.alignForward(auth_proto_data.len, 4));
}

test "a" {
    var buf : [100]u8 = undefined;
    const len = makeConnectSetupMessage(&buf, 1, 1, slice(u16, @as([]const u8, "hello")), slice(u16, @as([]const u8, "there")));
}

pub fn writeIntNative(comptime T: type, buf: [*]u8, value: T) void {
    @ptrCast(*align(1) T, buf).* = value;
}
pub fn readIntNative(comptime T: type, buf: [*]const u8) T {
    return @ptrCast(*const align(1) T, buf).*;
}


pub const RecvMsgResult = struct {
    msg_len: usize,
    total_received: usize,
};

const MsgKind = enum { initial_setup, normal };

pub fn getMsgLen(buf: []const u8, kind: MsgKind) usize {
    if (buf.len < 8) return 32;
    return getMsgLenHaveAtLeast8(buf.ptr, kind);
}

pub fn recvFull(sock: std.os.socket_t, buf: []u8) !void {
    std.debug.assert(buf.len > 0);
    var total_received : usize = 0;
    while (true) {
        const last_received = try std.os.recv(sock, buf[total_received..], 0);
        if (last_received == 0)
            return error.ConnectionResetByPeer;
        total_received += last_received;
        if (total_received == buf.len)
            break;
    }
}

// Returns the minimum amount needed to complete this message.  It is assumed that buf
// has been completely filled with a partial message.
// buf_ptr must have at least 8 bytes
fn getMsgLenHaveAtLeast8(buf_ptr: [*]const u8, kind: MsgKind) usize {
    if (kind == .initial_setup)
        return 8 + (4 * readIntNative(u16, buf_ptr + 6));
    return 32 + readIntNative(u32, buf_ptr + 4);
}

// on error.ParitalXMsg, buf will be completely filled with a partial message
pub fn recvMsg(sock: std.os.socket_t, buf: []u8, total_received: usize, kind: MsgKind) !RecvMsgResult {
    std.debug.assert(buf.len >= 32);

    var total_received : usize = 0;
    while (true) {
        if (total_received == buf.len)
            return error.PartialXMsg;

        const last_received = try std.os.recv(sock, buf[total_received..], 0);
        if (last_received == 0)
            return error.ConnectionResetByPeer;

        total_received += last_received;
        if (buf[0] == 1) {
            if (total_received < 8)
                continue;

            const msg_len = getMsgLenHaveAtLeast8(buf.ptr, kind);
            if (total_received < msg_len)
                continue;
            return RecvMsgResult{ .msg_len = msg_len, .total_received = total_received };
        } else {
            std.debug.warn("Error: received non-success reply '{}' (not implemented)\n", .{buf[0]});
            return error.NotImplemented;
        }
    }
}

pub const Format = packed struct {
    depth: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
    // can't do [5]u8 because of https://github.com/ziglang/zig/issues/2627
    _: u8,
    __: [4]u8,
};
comptime { if (@sizeOf(Format) != 8) @compileError("Format size is wrong"); }

pub const Screen = packed struct {
    window: u32,
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

pub const ScreenDepth = packed struct {
    depth: u8,
    unused0: u8,
    visual_type_count: u16,
    unused1: u32,
};

pub const VisualType = packed struct {
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

pub const ConnectSetup = struct {
    buf: []align(HeaderAlign) u8,

    pub const Header = packed struct {
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
            return @ptrCast([*]u8, self)[0..@sizeOf(@This())];
        }
    };
    // because X makes an effort to align things to 4-byte bounaries, we
    // make sure the header is aligned to at least 4-bytes so the rest
    // of the sub-structures can also leverage this 4-byte alignment
    pub const HeaderAlign = std.math.max(4, @alignOf(Header));
    pub fn header(self: @This()) *align(HeaderAlign) Header {
        return @ptrCast(*align(HeaderAlign) Header, self.buf.ptr);
    }
    pub fn failReason(self: @This()) ![]u8 {
        const reason_offset = 8;
        const reason_limit = reason_offset + self.buf[1];
        if (reason_limit > self.buf.len)
            return error.XMalformedReply;
        return self.buf[reason_offset..reason_limit];
    }

    /// All the connect setup fields that are at fixed offsets
    pub const Fixed = packed struct {
        release_number: u32,
        resource_id_base: u32,
        resource_id_mask: u32,
        motion_buffer_size: u32,
        vendor_len: u16,
        max_request_len: u16,
        root_screen_count: u8,
        format_count: u8,
        image_byte_order: u8,
        bitmap_format_bit_order: u8,
        bitmap_format_scanline_unit: u8,
        bitmap_format_scanline_pad: u8,
        min_keycode: u8,
        max_keycode: u8,
        unused: u32,
    };
    pub const FixedAlign = std.math.min(8, HeaderAlign);
    pub fn fixed(self: @This()) *align(FixedAlign) Fixed {
        return @ptrCast(*align(FixedAlign) Fixed, self.buf.ptr + 8);
    }


    pub const VendorOffset = 40;
    pub fn getVendorSlice(self: @This(), vendor_len: u16) ![]align(4) u8 {
        const vendor_limit = VendorOffset + vendor_len;
        if (vendor_limit > self.buf.len)
            return error.XMalformedReply_VendorLenTooBig;
        return self.buf[VendorOffset..vendor_limit];
    }

    pub fn getFormatListOffset(vendor_len: u16) u32 {
        //return VendorOffset + vendor_len + pad4(u16, vendor_len);
        return VendorOffset + @intCast(u32, std.mem.alignForward(vendor_len, 4));
    }
    pub fn getFormatListLimit(format_list_offset: u32, format_count: u32) u32 {
        return format_list_offset + (@sizeOf(Format) * format_count);
    }
    pub fn getFormatListPtr(self: @This(), format_list_offset: u32) [*]align(4) Format {
        return @ptrCast([*]align(4) Format, @alignCast(4, self.buf.ptr + format_list_offset));
    }
    pub fn getFormatList(self: @This(), format_list_offset: u32, format_list_limit: u32) ![]align(4) Format {
        if (format_list_limit > self.buf.len)
            return error.XMalformedReply_FormatCountTooBig;
        return self.getFormatListPtr(format_list_offset)[0..@divExact(format_list_limit - format_list_offset, @sizeOf(Format))];
    }

    pub fn getFirstScreenPtr(self: @This(), format_list_limit: u32) *align(4) Screen {
        return @ptrCast(*align(4) Screen, @alignCast(4, self.buf.ptr + format_list_limit));
    }
};

pub const ReadConnectSetupOpt = struct {
    read_timeout_ms: i32 = -1,
    max_reply: i32 = -1,
};

// TODO: replace sock with a generic reader kind of type (one that supports timeouts?)
pub fn readConnectSetup(allocator: *std.mem.Allocator, reader: anytype, options: ReadConnectSetupOpt) !ConnectSetup {
    var header : ConnectSetup.Header = undefined;

    if (options.read_timeout_ms == -1) {
        try readFull(reader, header.asBuf());
    } else {
        @panic("read timeout not implemented");
    }

    const reply_len = 8 + 4 * header.reply_u32_len;
    if (options.max_reply != -1 and reply_len > options.max_reply)
        return error.ReplyTooLarge; // TODO: would be nice to have some way to report the length

    const reply_buf = try allocator.allocWithOptions(u8, reply_len, ConnectSetup.HeaderAlign, null);
    errdefer allocator.free(reply_buf);
    @ptrCast(*ConnectSetup.Header, reply_buf.ptr).* = header;

    if (options.read_timeout_ms == -1) {
        try readFull(reader, reply_buf[8..]);
    } else {
        @panic("read timeout not implemented");
    }
    return ConnectSetup { .buf = reply_buf };
}

fn readFull(reader: anytype, buf: []u8) !void {
    std.debug.assert(buf.len > 0);
    var total_received : usize = 0;
    while (true) {
        const last_received = try reader.read(buf[total_received..]);
        if (last_received == 0)
            return error.ReaderClosed;
        total_received += last_received;
        if (total_received == buf.len)
            break;
    }
}
