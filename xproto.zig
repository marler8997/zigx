const std = @import("std");
const zog = @import("zog");

const net = @import("./net.zig");

pub const TcpBasePort = 6000;

pub fn Display(comptime StringType: type) type {
    return struct {
        host: StringType,
        proto: StringType,
        displayNum: u32,
        preferredScreen: u32,
        pub fn equals(self: *const @This(), other: *const @This()) bool {
            return std.mem.eql(u8, self.host, other.host) and
                std.mem.eql(u8, self.proto, other.proto) and
                self.displayNum == other.displayNum and
                self.preferredScreen == other.preferredScreen;
        }
        pub fn print(self: *const @This()) void {
            std.debug.warn("host='{}' proto='{}' display={} preferred={}",
                self.host, self.proto, self.displayNum, self.preferredScreen);
        }
    };
}

// Return: display if set, otherwise the environment variable DISPLAY
pub fn getDisplay(display: var) @typeOf(display) {
    if (display.length == 0) {
        const env = std.os.getenv("DISPLAY");
        if (@typeOf(display) == []const u8)
            return env else "";
        @compileError("display string type not implemented");
    }
}

const ParseDisplayError = error {
    NoDisplayNumber,
    BadDisplayNumber,
    BadScreenNumber,
};

// [PROTOCOL/]HOST:DISPLAYNUM[.SCREEN]
pub fn parseDisplay(display: var) !Display(@typeOf(display)) {
     const StringType = @typeOf(display);
     var next = display;

     // TODO: if launchd supported, check for <path to socket>[.<screen>]

     var protocol : StringType = undefined;
     {
         const optionalSlashIndex = std.mem.indexOfScalar(u8, next, '/');
         if (optionalSlashIndex) |slashIndex |{
             protocol = next[0..slashIndex];
             next = next[slashIndex + 1..];
         } else {
             protocol = next[0..0];
         }
     }
     var host : StringType = undefined;
     {
         const colonIndex = std.mem.indexOfScalar(u8, next, ':') orelse {
             return ParseDisplayError.NoDisplayNumber;
         };
         host = next[0..colonIndex];
         next = next[colonIndex + 1..];
     }
     if (next.len == 0)
         return ParseDisplayError.NoDisplayNumber;

     var preferredScreen : u32 = 0;
     {
         const optionalDotIndex = std.mem.indexOfScalar(u8, next, '.');
         if (optionalDotIndex) |dotIndex| {
             preferredScreen = std.fmt.parseInt(u32, next[dotIndex + 1..], 10) catch |err| {
                 return ParseDisplayError.BadScreenNumber;
             };
             next = next[0..dotIndex];
         }
     }
     const displayNum = std.fmt.parseInt(u32, next, 10) catch |err| {
         return ParseDisplayError.BadDisplayNumber;
     };

     return Display(StringType) {
         .host = host,
         .proto = protocol,
         .displayNum = displayNum,
         .preferredScreen = preferredScreen,
     };
}

test "parseDisplay" {
    std.testing.expectError(ParseDisplayError.NoDisplayNumber, parseDisplay(""[0..]));
    std.testing.expectError(ParseDisplayError.NoDisplayNumber, parseDisplay("0"[0..]));
    std.testing.expectError(ParseDisplayError.NoDisplayNumber, parseDisplay("0/"[0..]));
    std.testing.expectError(ParseDisplayError.NoDisplayNumber, parseDisplay("0/1"[0..]));
    std.testing.expectError(ParseDisplayError.NoDisplayNumber, parseDisplay(":"[0..]));

    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":a"[0..]));
    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":0a"[0..]));
    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":0a."[0..]));
    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":0a.0"[0..]));
    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":1x"[0..]));
    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":1x."[0..]));
    std.testing.expectError(ParseDisplayError.BadDisplayNumber, parseDisplay(":1x.10"[0..]));

    std.testing.expectError(ParseDisplayError.BadScreenNumber, parseDisplay(":1.x"[0..]));
    std.testing.expectError(ParseDisplayError.BadScreenNumber, parseDisplay(":1.0x"[0..]));
    // TODO: should this be an error or no????
    //std.testing.expectError(ParseDisplayError.BadScreenNumber, parseDisplay(":1."[0..]));

    std.testing.expect((try parseDisplay("proto/host:123.456"[0..])).equals(&Display([]const u8) {
        .host = "host",
        .proto = "proto",
        .displayNum = 123,
        .preferredScreen = 456,
    }));
    std.testing.expect((try parseDisplay("host:123.456"[0..])).equals(&Display([]const u8) {
        .host = "host",
        .proto = "",
        .displayNum = 123,
        .preferredScreen = 456,
    }));
    std.testing.expect((try parseDisplay(":123.456"[0..])).equals(&Display([]const u8) {
        .host = "",
        .proto = "",
        .displayNum = 123,
        .preferredScreen = 456,
    }));
    std.testing.expect((try parseDisplay(":123"[0..])).equals(&Display([]const u8) {
        .host = "",
        .proto = "",
        .displayNum = 123,
        .preferredScreen = 0,
    }));
    std.testing.expect((try parseDisplay("/:10"[0..])).equals(&Display([]const u8) {
        .host = "",
        .proto = "",
        .displayNum = 10,
        .preferredScreen = 0,
    }));
    std.testing.expect((try parseDisplay("a/:43"[0..])).equals(&Display([]const u8) {
        .host = "",
        .proto = "a",
        .displayNum = 43,
        .preferredScreen = 0,
    }));
}



const Connection = struct {
    pub fn init(display: *const Display([]const u8)) !@This() {

    }
};



pub fn isUnixProtocol(optionalProtocol: ?[]const u8) bool {
    if (optionalProtocol) |protocol| {
        return std.mem.eql(u8, "unix", protocol);
    }
    return false;
}

const ConnectError = error {
    UnsupportedProtocol,
};

pub fn connect(allocator: *std.mem.Allocator, optionalHost: ?[]const u8, optionalProtocol: ?[]const u8, displayNum: u32) !net.Socket {
    if (optionalHost) |host| {
        if (!std.mem.eql(u8, host, "unix") and !isUnixProtocol(optionalProtocol)) {
            const port = TcpBasePort + displayNum;
            if (port > std.math.maxInt(u16))
                return error.DisplayNumberOutOfRange;
            return connectTcp(allocator, host, optionalProtocol, @intCast(u16, port));
        }
    }
    return error.NotImplemented;
}

pub fn connectTcp(allocator: *std.mem.Allocator, optionalHost: ?[]const u8, optionalProtocol: ?[]const u8, port: u16) !net.Socket {

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
    var sock = net.tcpConnect(allocator, host, port, net.addressOrderIpv4First);

    return error.NotImplemented;
}


test "connect" {
    var arena = std.heap.ArenaAllocator.init(std.heap.direct_allocator);
    std.debug.warn("\n");
    const display = 0;
    //const display = 10;
    const sock = connect(&arena.allocator, "localhost", null, display);
}
