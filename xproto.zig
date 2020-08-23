const std = @import("std");
const zog = @import("zog");

const net = @import("./net.zig");

pub const TcpBasePort = 6000;

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
    displayNum: u32, // TODO: is there a maximum display number?
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
            and self.displayNum == other.displayNum
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
         .displayNum = undefined,
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
     parsed.displayNum = std.fmt.parseInt(u32, display[parsed.hostLimit + 1..index], 10) catch |err|
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

fn testParseDisplay(display: []const u8, proto: []const u8, host: []const u8, displayNum: u32, screen: ?u32) !void {
    const parsed = try parseDisplay(display);
    std.testing.expect(std.mem.eql(u8, proto, parsed.protoSlice(display.ptr)));
    std.testing.expect(std.mem.eql(u8, host, parsed.hostSlice(display.ptr)));
    std.testing.expectEqual(displayNum, parsed.displayNum);
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
//pub fn isUnixProtocol(optionalProtocol: ?[]const u8) bool {
//    if (optionalProtocol) |protocol| {
//        return std.mem.eql(u8, "unix", protocol);
//    }
//    return false;
//}
//
//const ConnectError = error {
//    UnsupportedProtocol,
//};
//
//pub fn connect(allocator: *std.mem.Allocator, optionalHost: ?[]const u8, optionalProtocol: ?[]const u8, displayNum: u32) !net.Socket {
//    if (optionalHost) |host| {
//        if (!std.mem.eql(u8, host, "unix") and !isUnixProtocol(optionalProtocol)) {
//            const port = TcpBasePort + displayNum;
//            if (port > std.math.maxInt(u16))
//                return error.DisplayNumberOutOfRange;
//            return connectTcp(allocator, host, optionalProtocol, @intCast(u16, port));
//        }
//    }
//    return error.NotImplemented;
//}
//
//pub fn connectTcp(allocator: *std.mem.Allocator, optionalHost: ?[]const u8, optionalProtocol: ?[]const u8, port: u16) !net.Socket {
//
//    var forceIpv6 = false;
//    if (optionalProtocol) |protocol| {
//        if (std.mem.eql(u8, protocol, "tcp")) { }
//        else if (std.mem.eql(u8, protocol, "inet")) { }
//        else if (std.mem.eql(u8, protocol, "inet6")) {
//            forceIpv6 = true;
//        } else {
//            return ConnectError.UnsupportedProtocol;
//        }
//    }
//    const host = if (optionalHost) |host| host else "localhost";
//    var sock = net.tcpConnect(allocator, host, port, net.addressOrderIpv4First);
//
//    return error.NotImplemented;
//}
//
//
//test "connect" {
//    var arena = std.heap.ArenaAllocator.init(std.heap.direct_allocator);
//    std.debug.warn("\n", .{});
//    const display = 0;
//    //const display = 10;
//    const sock = connect(&arena.allocator, "localhost", null, display);
//}
//
