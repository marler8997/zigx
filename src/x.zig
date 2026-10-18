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
const testing = std.testing;
const builtin = @import("builtin");

pub const draft = @import("x/draft.zig");

// ================================================================================
// Extensions
// ================================================================================
pub const input = @import("x/input.zig");
pub const render = @import("x/render.zig");
/// Double Buffer Extension. Consider using the Present extension instead,
/// which supersedes DBE by providing both off-screen rendering (via Pixmaps)
/// and frame synchronization (via CompleteNotify events).
pub const dbe = @import("x/dbe.zig");
pub const shape = @import("x/shape.zig");
pub const tst = @import("x/tst.zig");
pub const composite = @import("x/composite.zig");
pub const randr = @compileError("todo");
pub const fixes = @import("x/fixes.zig");
pub const damage = @compileError("todo");
pub const shm = @compileError("todo");
pub const sync = @compileError("todo");
pub const video = @compileError("todo");
pub const vmc = @compileError("todo");
pub const dri = @compileError("todo");
pub const present = @import("x/present.zig");
pub const res = @compileError("todo");
pub const record = @compileError("todo");

// Expose some helpful stuff
pub const BoundedArray = @import("bounded_array.zig").BoundedArray;
pub const charset = @import("charset.zig");
pub const Charset = charset.Charset;
pub const Slice = @import("slice.zig").Slice;
pub const SliceWithMaxLen = @import("slice.zig").SliceWithMaxLen;
pub const keymap = @import("keymap.zig");

pub const log = std.log.scoped(.x11);

const x_test = @import("test/x_test.zig");

test {
    // Perhaps we can use `testing.refAllDecls(@This());` instead but that requires
    // us to make the `x_test` import public.
    _ = x_test;
    _ = IdRange;
}

pub const TcpBasePort = 6000;

pub const max_port = 65535;
pub const max_display_num = max_port - TcpBasePort;

pub const BigEndian = 'B';
pub const LittleEndian = 'l';

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
    try testing.expectEqual(0, pad4Len(0));
    try testing.expectEqual(0, pad4Len(@truncate(4)));
    try testing.expectEqual(0, pad4Len(@truncate(8)));
    try testing.expectEqual(1, pad4Len(3)); // 7 -> 8
    try testing.expectEqual(2, pad4Len(2)); // 6 -> 8
    try testing.expectEqual(3, pad4Len(1)); // 1 -> 4
    try testing.expectEqual(2, pad4Len(@truncate(14)));
    try testing.expectEqual(3, pad4Len(@truncate(29)));

    inline for (&.{ 4, 8 }) |align_to| {
        for (0..10) |multiplier| {
            try testing.expectEqual(0, padLen(align_to, @truncate(multiplier * align_to)));
        }
        for (1..align_to + 1) |i| {
            try testing.expectEqual(align_to - i, padLen(align_to, @truncate(i)));
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

    pub const default: ParsedDisplay = .{
        .proto = null,
        .hostStart = 0,
        .hostLimit = 0,
        .display_num = .@"0",
        .preferredScreen = null,
    };
    pub const w32: ParsedDisplay = .{
        .proto = .w32,
        .hostStart = 0,
        .hostLimit = 0,
        .display_num = .@"0",
        .preferredScreen = null,
    };

    pub fn asFilePath(self: @This(), ptr: [*]const u8) ?[]const u8 {
        if (ptr[0] != '/') return null;
        return ptr[0..self.hostLimit];
    }
    pub fn equals(self: @This(), other: @This()) bool {
        return self.protoLen == other.protoLen and self.hostLimit == other.hostLimit and self.display_num == other.display_num and optEql(self.preferredScreen, other.preferredScreen);
    }
};

pub const Display = struct {
    string: ?[]const u8,
    pub fn init(s: ?[]const u8) Display {
        return .{ .string = s };
    }
    pub fn format(display: Display, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (display.string) |string| {
            try writer.print("'{s}'", .{string});
        } else {
            try writer.print("<none>", .{});
        }
    }

    pub fn host(self: Display, parsed: *const ParsedDisplay) []const u8 {
        return (self.string orelse return "")[parsed.hostStart..parsed.hostLimit];
    }
};

pub const GetDisplayError = error{
    DisplayTooLong,
};

/// Large enough for any reasonable DISPLAY, see getDisplay.
pub const max_display_len = 512;

/// Returns the DISPLAY environment variable for any platform. On windows the
/// value is converted to WTF-8 into `buf` (see max_display_len), it's unused on
/// other platforms. Use getDisplayPosix which has no possible error for non-windows systems.
pub fn getDisplay(environ: std.process.Environ, buf: []u8) GetDisplayError!Display {
    if (builtin.os.tag == .windows) {
        const value = environ.getWindows(std.unicode.wtf8ToWtf16LeStringLiteral("DISPLAY")) orelse return .{ .string = null };
        const len = std.unicode.calcWtf8Len(value);
        if (len > buf.len) {
            log.err("DISPLAY is {} bytes but the buffer is only {}", .{ len, buf.len });
            return error.DisplayTooLong;
        }
        const written = std.unicode.wtf16LeToWtf8(buf, value);
        std.debug.assert(written == len);
        return .{ .string = buf[0..len] };
    }
    return getDisplayPosix(environ);
}

/// Posix-specific function to get DISPLAY which cannot fail.
pub fn getDisplayPosix(environ: std.process.Environ) Display {
    return .{ .string = environ.getPosix("DISPLAY") };
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
    IsEmpty,
    UnknownProtocol,
    HasMultipleProtocols,
    IsTooLarge,
    NoDisplayNumber,
    BadDisplayNumber,
    BadScreenNumber,
};

// display format: [PROTOCOL/]HOST:DISPLAYNUM[.SCREEN]
// assumption: display.len > 0
pub fn parseDisplay(display: Display) InvalidDisplayError!ParsedDisplay {
    const string = display.string orelse return .default;
    if (string.len == 0) return error.IsEmpty;
    if (string.len >= std.math.maxInt(u16))
        return error.IsTooLarge;

    // Xming (X server for windows) set this
    if (builtin.os.tag == .windows) {
        if (std.mem.eql(u8, string, "w32")) return .w32;
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
        const c = string[index];
        if (c == ':') {
            break;
        }
        if (c == '/') {
            // I guess a DISPLAY that starts with '/' is a file path?
            // This is the case on my M1 macos laptop.
            if (index == 0) return .{
                .proto = null,
                .hostStart = 0,
                .hostLimit = @intCast(string.len),
                .display_num = .@"0",
                .preferredScreen = null,
            };
            if (parsed.proto) |_|
                return error.HasMultipleProtocols;
            parsed.proto = try protoFromString(string[0..index]);
            parsed.hostStart = index + 1;
        }
        index += 1;
        if (index == string.len)
            return error.NoDisplayNumber;
    }

    parsed.hostLimit = index;
    index += 1;
    if (index == string.len)
        return error.NoDisplayNumber;

    while (true) {
        const c = string[index];
        if (c == '.')
            break;
        index += 1;
        if (index == string.len)
            break;
    }

    //std.debug.warn("num '{}'\n", .{string[parsed.hostLimit + 1..index]});
    parsed.display_num = try DisplayNum.fromInt(std.fmt.parseInt(u16, string[parsed.hostLimit + 1 .. index], 10) catch
        return error.BadDisplayNumber);
    if (index == string.len) {
        parsed.preferredScreen = null;
    } else {
        index += 1;
        parsed.preferredScreen = std.fmt.parseInt(u32, string[index..], 10) catch
            return error.BadScreenNumber;
    }
    return parsed;
}

/// A unix domain socket path stored inline.
pub const UnixPath = struct {
    buf: [max_len]u8,
    len: std.math.IntFittingRange(0, max_len),

    /// The size of sockaddr_un.path on linux.
    pub const max_len = 108;

    pub fn init(path: []const u8) error{NameTooLong}!UnixPath {
        if (path.len > max_len) return error.NameTooLong;
        var result: UnixPath = .{ .buf = undefined, .len = @intCast(path.len) };
        @memcpy(result.buf[0..path.len], path);
        return result;
    }
    pub fn initDisplayNum(display_num: DisplayNum) UnixPath {
        var result: UnixPath = .{ .buf = undefined, .len = undefined };
        result.len = @intCast((std.fmt.bufPrint(
            &result.buf,
            "/tmp/.X11-unix/X{d}",
            .{@backingInt(display_num)},
        ) catch unreachable).len);
        return result;
    }
    pub fn slice(path: *const UnixPath) []const u8 {
        return path.buf[0..path.len];
    }
};

pub const Address = union(enum) {
    ip: std.Io.net.IpAddress,
    unix: UnixPath,
    pub fn format(address: Address, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (address) {
            .ip => |ip| try ip.format(writer),
            .unix => |*path| try writer.print("unix:{s}", .{path.slice()}),
        }
    }
};

pub const Host = union(enum) {
    address: Address,
    domain_name: struct {
        string: []const u8,
        port: u16,
    },
    pub fn initDomainName(host: []const u8, port: u16) Host {
        std.debug.assert(host.len != 0);
        if (std.Io.net.IpAddress.parse(host, port)) |ip| return .{ .address = .{ .ip = ip } } else |_| {}
        // TODO: should/could we check if this is a valid hostname?
        //       maybe not since we might detect this later during DNS resolution?
        return .{ .domain_name = .{ .string = host, .port = port } };
    }
    pub fn format(host: Host, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (host) {
            .address => |address| try address.format(writer),
            .domain_name => |d| try writer.print("{s}:{}", .{ d.string, d.port }),
        }
    }
};

fn localhostIp4(port: u16) Address {
    return .{ .ip = .{ .ip4 = .loopback(port) } };
}

pub fn getHost(display: Display, parsed: *const ParsedDisplay) error{X11BadDisplay}!Host {
    const host_or_empty = display.host(parsed);
    if (parsed.proto) |proto| return switch (proto) {
        .unix => {
            if (host_or_empty.len != 0) {
                log.err("not sure if it's valid for DISPLAY to host with the unix protocol", .{});
                return error.X11BadDisplay;
            }
            return .{ .address = .{ .unix = .initDisplayNum(parsed.display_num) } };
        },
        .tcp, .inet => if (host_or_empty.len == 0) return .{
            .address = localhostIp4(parsed.display_num.asPort()),
        } else .initDomainName(host_or_empty, parsed.display_num.asPort()),
        .inet6 => {
            log.err("IPv6 not implemented", .{});
            return error.X11BadDisplay;
        },
        .w32 => .{ .address = localhostIp4(TcpBasePort) },
    };

    if (host_or_empty.len > 0) {
        if (std.mem.eql(u8, host_or_empty, "unix")) {
            // I don't want to carry this complexity if I don't have to, so for now I'll just make it an error
            log.err("host is 'unix' this might mean 'unix domain socket' but not sure, giving up for now", .{});
            return error.X11BadDisplay;
        }
        if (host_or_empty[0] == '/') {
            // TODO: should we check if this file exists?
            return .{ .address = .{ .unix = UnixPath.init(host_or_empty) catch |e| switch (e) {
                error.NameTooLong => {
                    log.err("unix socket path '{s}' is too long ({})", .{ host_or_empty, host_or_empty.len });
                    return error.X11BadDisplay;
                },
            } } };
        }
        return .initDomainName(host_or_empty, parsed.display_num.asPort());
    } else {
        if (builtin.os.tag == .windows) {
            log.err(
                "unsure how to connect to DISPLAY {f} on windows without a hostname. Expected something like 'localhost:{}'",
                .{ display, @backingInt(parsed.display_num) },
            );
            std.process.exit(0xff);
        }
        return .{ .address = .{ .unix = .initDisplayNum(parsed.display_num) } };
    }
}

pub const AuthFileKind = enum {
    env,
    home,

    pub const first: AuthFileKind = .env;

    pub fn context(self: AuthFileKind) []const u8 {
        return switch (self) {
            .env => "from XAUTHORITY environment variable",
            .home => "default HOME path",
        };
    }
};

/// Takes an X11 display/address and IO and attempts to authenticate.
/// Note that if an authentication fails, it will reconnect and reset
/// the given IO.
pub const Authenticator = struct {
    io: std.Io,
    environ: std.process.Environ,
    display: Display,
    parsed_display: *const ParsedDisplay,
    host: *const Host,
    address: *const Address,
    stream: std.Io.net.Stream,
    stream_read_buffer: []u8,
    filename_buffer: []u8,
    order: Order,

    state: State = .{ .connect = .@"0" },
    auth_count: u32 = 0,
    auth_skip_count: u32 = 0,
    need_reconnect: bool = false,

    pub fn deinit(authenticator: *Authenticator) void {
        authenticator.state.deinit();
        authenticator.* = undefined;
    }

    pub const Order = enum { auth_first, no_auth_first };
    const AuthIndex = enum {
        @"0",
        @"1",
        @"2",
        pub fn nextAuthState(index: AuthIndex) State {
            return switch (index) {
                .@"0" => .{ .connect = .@"1" },
                .@"1" => .{ .connect = .@"2" },
                .@"2" => .{ .done = .no_more_auth },
            };
        }
    };
    fn authFromIndex(order: Order, index: AuthIndex) union(enum) {
        no_auth,
        auth: AuthFileKind,
    } {
        return switch (order) {
            .auth_first => switch (index) {
                .@"0" => .{ .auth = .env },
                .@"1" => .{ .auth = .home },
                .@"2" => .no_auth,
            },
            .no_auth_first => switch (index) {
                .@"0" => .no_auth,
                .@"1" => .{ .auth = .env },
                .@"2" => .{ .auth = .home },
            },
        };
    }

    const State = union(enum) {
        connect: AuthIndex,
        read_file: ReadFile,
        done: DoneReason,
        pub fn deinit(state: *State) void {
            switch (state.*) {
                .connect => {},
                .read_file => |*r| r.close(),
                .done => {},
            }
        }
        pub fn update(state: *State, new_state: State) void {
            state.deinit();
            state.* = new_state;
        }
    };
    const DoneReason = union(enum) {
        reconnect_error: ConnectAddressError,
        no_more_auth,
    };

    pub const Success = struct { std.Io.net.Stream.Reader, bool };

    pub const Event = union(enum) {
        reply: union(enum) {
            success: Success,
            failed: SetupFailed,
        },
        done: struct {
            attempt_count: u32,
            skip_count: u32,
            reason: DoneReason,
        },
        get_auth_filename_error: struct {
            kind: AuthFileKind,
            err: GetAuthFilenameError,
        },
        open_auth_file_error: struct {
            kind: AuthFileKind,
            filename: []const u8,
            err: std.Io.File.OpenError,
        },
        auth_file_opened: struct {
            kind: AuthFileKind,
            filename: []const u8,
        },
        io_error: union(enum) {
            write_error: std.Io.net.Stream.Writer.Error,
            read_error: (error{EndOfStream} || std.Io.net.Stream.Reader.Error),
            protocol,
        },
    };

    const ReadFile = struct {
        auth_index: AuthIndex,
        auth_file_kind: AuthFileKind,
        filename: []const u8,
        file: std.Io.File,
        read_buf: [400]u8 = undefined,
        file_reader: std.Io.File.Reader,
        reader: AuthReader,
        pub fn close(self: *ReadFile) void {
            self.file.close(self.file_reader.io);
        }
    };

    pub fn next(authenticator: *Authenticator) Event {
        while (true) switch (authenticator.state) {
            .connect => |index| switch (authFromIndex(authenticator.order, index)) {
                .no_auth => {
                    authenticator.connect() catch |e| {
                        authenticator.state.update(.{ .done = .{ .reconnect_error = e } });
                        continue;
                    };
                    authenticator.state.update(index.nextAuthState());
                    authenticator.need_reconnect = true;
                    log.info("sending setup with no auth...", .{});
                    writeSetupNoAuth(authenticator.io, authenticator.stream) catch |err| return .{
                        .io_error = .{ .write_error = err },
                    };
                    return authenticator.readSetupReply(.{ .used_auth = false });
                },
                .auth => |auth_file_kind| {
                    const maybe_auth_filename = getAuthFilename(
                        authenticator.environ,
                        auth_file_kind,
                        authenticator.filename_buffer,
                    ) catch |err| {
                        authenticator.state.update(index.nextAuthState());
                        return .{ .get_auth_filename_error = .{
                            .kind = auth_file_kind,
                            .err = err,
                        } };
                    };
                    const auth_filename = maybe_auth_filename orelse {
                        authenticator.state.update(index.nextAuthState());
                        continue;
                    };
                    const file = std.Io.Dir.cwd().openFile(authenticator.io, auth_filename, .{}) catch |err| {
                        authenticator.state.update(index.nextAuthState());
                        return .{ .open_auth_file_error = .{
                            .kind = auth_file_kind,
                            .filename = auth_filename,
                            .err = err,
                        } };
                    };
                    authenticator.state.update(.{ .read_file = .{
                        .auth_file_kind = auth_file_kind,
                        .auth_index = index,
                        .filename = auth_filename,
                        .file = file,
                        .read_buf = undefined,
                        .file_reader = undefined,
                        .reader = undefined,
                    } });
                    authenticator.state.read_file.file_reader = .init(file, authenticator.io, &authenticator.state.read_file.read_buf);
                    authenticator.state.read_file.reader = .{ .reader = &authenticator.state.read_file.file_reader.interface };
                },
            },
            .read_file => |*r| {
                const match = switch (matchAuthEntry(
                    authenticator.display,
                    authenticator.parsed_display,
                    authenticator.host,
                    authenticator.address,
                    &r.reader,
                    authenticator.auth_count,
                ) catch |err| {
                    reportAuthReadError(r.filename, err, r.file_reader.err);
                    authenticator.state.update(r.auth_index.nextAuthState());
                    continue;
                }) {
                    .eof => {
                        authenticator.state.update(r.auth_index.nextAuthState());
                        continue;
                    },
                    .skip => {
                        authenticator.auth_count += 1;
                        authenticator.auth_skip_count += 1;
                        continue;
                    },
                    .match => |match| match,
                };

                const auth_index = authenticator.auth_count;
                authenticator.auth_count += 1;
                authenticator.connect() catch |e| {
                    authenticator.state.update(.{ .done = .{ .reconnect_error = e } });
                    continue;
                };
                authenticator.need_reconnect = true;
                log.info(
                    "sending setup with auth {} from '{s}' ({s}) ({s})",
                    .{ auth_index, r.filename, r.auth_file_kind.context(), match.name.nativeSlice() },
                );
                var write_error: ?std.Io.net.Stream.Writer.Error = null;
                writeSetupWithAuth(
                    authenticator.io,
                    authenticator.stream,
                    &r.reader,
                    match.name,
                    match.data_len,
                    &write_error,
                ) catch |err| switch (err) {
                    error.WriteFailed => return .{ .io_error = .{
                        .write_error = write_error orelse error.Unexpected,
                    } },
                    error.ReadFailed, error.EndOfStream => |e| {
                        reportAuthReadError(r.filename, e, r.file_reader.err);
                        authenticator.state.update(r.auth_index.nextAuthState());
                        continue;
                    },
                };
                return authenticator.readSetupReply(.{ .used_auth = true });
            },
            .done => |reason| return .{ .done = .{
                .reason = reason,
                .attempt_count = 1 + (authenticator.auth_count - authenticator.auth_skip_count),
                .skip_count = authenticator.auth_skip_count,
            } },
        };
    }
    fn connect(authenticator: *Authenticator) ConnectAddressError!void {
        if (authenticator.need_reconnect) {
            const new_stream = connectAddress(authenticator.io, authenticator.address) catch |e| {
                log.err("reconnect to {f} failed with {t}", .{ authenticator.address.*, e });
                return e;
            };
            log.info("reconnected", .{});
            std.debug.assert(authenticator.stream.socket.handle != new_stream.socket.handle);
            disconnect(authenticator.io, authenticator.stream);
            authenticator.stream = new_stream;
            authenticator.need_reconnect = false;
        }
    }
    fn readSetupReply(authenticator: *Authenticator, named: struct { used_auth: bool }) Event {
        var socket_reader = authenticator.stream.reader(authenticator.io, authenticator.stream_read_buffer);
        return switch (readSetupReply1(&socket_reader.interface) catch |err| return switch (err) {
            error.ReadFailed => .{ .io_error = .{
                .read_error = socket_reader.err orelse error.Unexpected,
            } },
            error.EndOfStream => |e| .{ .io_error = .{
                .read_error = e,
            } },
            error.Protocol => .{ .io_error = .protocol },
        }) {
            .success => .{ .reply = .{
                .success = .{ socket_reader, named.used_auth },
            } },
            .failed => |failed| .{ .reply = .{ .failed = failed } },
            .authenticate => {
                // I'd like to implement this flow, maybe it would allow us to try
                // another authentication method without reconnecting, but, I've
                // never seen this happen so I can't test a solution yet.
                (if (builtin.mode == .debug) std.debug.panic else log.err)(
                    "TODO: handle authenticate reply from X server",
                    .{},
                );
                // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
                return .{ .io_error = .protocol };
            },
        };
    }
    fn reportAuthReadError(filename: []const u8, err: error{ ReadFailed, EndOfStream }, file_error: ?std.Io.File.Reader.Error) void {
        switch (err) {
            error.ReadFailed => {
                const e = file_error orelse error.Unexpected;
                log.err("read from auth file '{s}' failed with {s}", .{ filename, @errorName(e) });
            },
            error.EndOfStream => {
                log.err("auth file '{s}' was truncated", .{filename});
            },
        }
    }
};

// The size of the client's initial setup message if both name and data are empty
const write_setup_no_auth_len = 12;

fn writeSetupNoAuth(io: std.Io, stream: std.Io.net.Stream) std.Io.net.Stream.Writer.Error!void {
    var write_buffer: [write_setup_no_auth_len]u8 = undefined;
    var socket_writer = stream.writer(io, &write_buffer);
    const w = &socket_writer.interface;
    writeSetupHeader(w, .empty, 0) catch unreachable;
    writeSetupData(w, .empty) catch unreachable;
    std.debug.assert(w.end == write_setup_no_auth_len);
    w.flush() catch return socket_writer.err orelse error.Unexpected;
}
// name is assumed to be taken from the AuthReader buffer, so, it becomes invalidated
// as soon as any more data is read from AuthReader.
fn writeSetupWithAuth(
    io: std.Io,
    stream: std.Io.net.Stream,
    auth_reader: *AuthReader,
    name: Slice(u16, [*]const u8),
    data_len: u16,
    out_write_error: *?std.Io.net.Stream.Writer.Error,
) error{ ReadFailed, EndOfStream, WriteFailed }!void {
    std.debug.assert(out_write_error.* == null);
    var write_buffer: [write_setup_no_auth_len + 400]u8 = undefined;
    var socket_writer = stream.writer(io, &write_buffer);
    defer out_write_error.* = socket_writer.err;
    const w = &socket_writer.interface;
    writeSetupHeader(w, name, data_len) catch unreachable;
    // we're done with name so now we can read the data
    try writeSetupData(w, .initAssume(try auth_reader.takeDynamic(data_len)));
    try w.flush();
}

pub const SetupFailed = struct {
    version_major: u16,
    version_minor: u16,
    reason_len: u8,
    reason_buf: [256]u8,
    pub fn reason(self: *const SetupFailed) []const u8 {
        return std.mem.trimEnd(u8, self.reason_buf[0..self.reason_len], "\r\n");
    }
};

pub const SetupReply1 = union(enum) {
    success,
    failed: SetupFailed,
    authenticate: struct { reason_word_count: u16 },
};
fn readSetupReply1(reader: *std.Io.Reader) error{ ReadFailed, EndOfStream, Protocol }!SetupReply1 {
    const status = try reader.peekByte();
    const Status = enum(u8) {
        failed = 0,
        success = 1,
        authenticate = 2,
        _,
    };
    switch (@as(Status, @fromBackingInt(@intCast(status)))) {
        .failed => {
            reader.seek += 1;
            const reason_len = try reader.takeByte();
            const version_major = try reader.takeInt(u16, native_endian);
            const version_minor = try reader.takeInt(u16, native_endian);
            try reader.discardAll(2);
            var result: SetupReply1 = .{ .failed = .{
                .version_major = version_major,
                .version_minor = version_minor,
                .reason_len = reason_len,
                .reason_buf = undefined,
            } };
            try reader.readSliceAll(result.failed.reason_buf[0..reason_len]);
            return result;
        },
        .success => return .success,
        .authenticate => {
            try reader.discardAll(6);
            const word_count = try reader.takeInt(u16, native_endian);
            return .{ .authenticate = .{ .reason_word_count = word_count } };
        },
        else => {
            log.err("expected first byte of server reply to be 0, 1 or 2 but got {}", .{status});
            return error.Protocol;
        },
    }
}

fn matchAuthEntry(
    display: Display,
    parsed_display: *const ParsedDisplay,
    host: *const Host,
    address: *const Address,
    auth_reader: *AuthReader,
    entry_index: u32,
) error{ ReadFailed, EndOfStream }!union(enum) {
    eof,
    skip,
    match: struct { name: Slice(u16, [*]const u8), data_len: u16 },
} {
    try auth_reader.discardRemaining();
    const family = (try auth_reader.takeFamily()) orelse return .eof;

    {
        const addr_len = try auth_reader.takeDynamicLen(.addr);
        if (addr_len > auth_reader.reader.buffer.len) {
            log.info("auth[{}] skipped, address too long ({} bytes)", .{ entry_index, addr_len });
            return .skip;
        }
        const addr_data = try auth_reader.takeDynamic(addr_len);
        const file_addr: AuthFileAddr = .{ .family = family, .data = addr_data };
        if (!matchAddr(host, address, file_addr)) {
            log.info("auth[{}] skipped, address mismatch {f}", .{ entry_index, file_addr });
            return .skip;
        }
    }
    {
        const display_num_len = try auth_reader.takeDynamicLen(.display_num);
        if (display_num_len > auth_reader.reader.buffer.len) {
            log.info("auth[{}] skipped, display num too long ({} bytes)", .{ entry_index, display_num_len });
            return .skip;
        }
        const display_num = try auth_reader.takeDynamic(display_num_len);
        if (!matchDisplayNum(display, parsed_display, display_num)) {
            log.info("auth[{}] skipped, display num mismatch '{s}'", .{ entry_index, display_num });
            return .skip;
        }
    }
    const name_len = try auth_reader.takeDynamicLen(.name);
    const name_len_plus2 = @as(u32, name_len) + 2;
    if (name_len_plus2 > auth_reader.reader.buffer.len) {
        log.info("auth[{}] skipped, name too long ({} bytes)", .{ entry_index, name_len });
        return .skip;
    }
    const name, const data_len = try auth_reader.takeNameAndDataLen(name_len_plus2);
    if (data_len > auth_reader.reader.buffer.len) {
        log.info("auth[{}] skipped, data too long ({} bytes)", .{ entry_index, data_len });
        return .skip;
    }

    return .{ .match = .{ .name = .initAssume(name), .data_len = data_len } };
}

pub const DisplayNum = enum(u16) {
    @"0" = 0,
    _,

    pub fn fromInt(int: u16) error{BadDisplayNumber}!DisplayNum {
        if (int > max_display_num) return error.BadDisplayNumber;
        return @fromBackingInt(@intCast(int));
    }

    pub fn asPort(self: DisplayNum) u16 {
        return TcpBasePort + @as(u16, @backingInt(self));
    }

    pub fn format(self: DisplayNum, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.print("{}", .{@backingInt(self)});
    }
};

pub const ConnectError =
    error{UnknownHostName} ||
    ConnectTcpError ||
    ConnectUnixError;
pub fn connect(io: std.Io, host: *const Host) ConnectError!struct { Address, std.Io.net.Stream } {
    switch (host.*) {
        .address => |*address| return .{ address.*, try connectAddress(io, address) },
        .domain_name => |*d| {
            var addr_buf: [16]std.Io.net.IpAddress = undefined;
            const addrs = try lookup(io, d.string, d.port, &addr_buf);
            var ip4_only = true;
            while (true) {
                for (addrs) |*ip| {
                    if ((ip.* == .ip4) != ip4_only) continue;
                    if (connectTcp(io, ip)) |stream| {
                        return .{ .{ .ip = ip.* }, stream };
                    } else |err| switch (err) {
                        error.ConnectionRefused, error.Unexpected => continue,
                        error.AccessDenied,
                        error.SystemResources,
                        error.Canceled,
                        => |e| return e,
                    }
                }
                if (!ip4_only) break;
                ip4_only = false;
            }
            if (addrs.len == 0) return error.UnknownHostName;
            return error.ConnectionRefused;
        },
    }
}

const ConnectAddressError = ConnectTcpError || ConnectUnixError;
fn connectAddress(io: std.Io, addr: *const Address) ConnectAddressError!std.Io.net.Stream {
    return switch (addr.*) {
        .ip => |*ip| try connectTcp(io, ip),
        .unix => |*path| try connectUnix(io, path.slice()),
    };
}

/// Resolves `name` to the IP addresses stored in `addr_buf`, any beyond its length are ignored.
pub fn lookup(
    io: std.Io,
    name: []const u8,
    port: u16,
    addr_buf: []std.Io.net.IpAddress,
) ConnectError![]std.Io.net.IpAddress {
    const host_name = std.Io.net.HostName.init(name) catch |err| {
        log.err("invalid host name '{s}': {t}", .{ name, err });
        return error.UnknownHostName;
    };
    // lookup is guaranteed not to block with a capacity of at least 16
    var queue_buf: [32]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&queue_buf);
    host_name.lookup(io, &queue, .{ .port = port }) catch |err| switch (err) {
        error.UnknownHostName, error.NoAddressReturned => return error.UnknownHostName,
        error.SystemResources,
        error.Canceled,
        => |e| return e,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return error.SystemResources,
        // There's sooo many possible errors here it's silly to list them all, by default
        // we'll just handle them as unexpected errors until we know there's a reason to handle
        // specific errors.
        else => |e| {
            log.err("resolve DNS name '{s}' (port {}) failed with {t}", .{ name, port, e });
            return error.Unexpected;
        },
    };
    var len: usize = 0;
    while (queue.getOne(io)) |result| switch (result) {
        .address => |addr| if (len < addr_buf.len) {
            addr_buf[len] = addr;
            len += 1;
        },
        .canonical_name => {},
    } else |err| switch (err) {
        error.Closed => {},
        error.Canceled => |e| return e,
    }
    return addr_buf[0..len];
}

const ConnectTcpError = error{
    AccessDenied,
    ConnectionRefused,
    SystemResources,
    Canceled,
    Unexpected,
};
fn connectTcp(io: std.Io, addr: *const std.Io.net.IpAddress) ConnectTcpError!std.Io.net.Stream {
    // tcp connections can take a while so let's add a log to know
    // if we're blocked on it
    log.info("connecting to {f}", .{addr.*});
    return addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| switch (err) {
        error.Timeout,
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.ConnectionPending,
        error.ConnectionResetByPeer,
        => return error.ConnectionRefused,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => return error.SystemResources,
        error.AccessDenied => return error.AccessDenied,
        error.Canceled => |e| return e,
        else => |e| {
            log.err("TCP connect to {f} failed unexpectedly with {t}", .{ addr.*, e });
            return error.Unexpected;
        },
    };
}

pub fn disconnect(io: std.Io, stream: std.Io.net.Stream) void {
    stream.shutdown(io, .both) catch {}; // ignore any error here
    stream.close(io);
}

const ConnectUnixError = error{
    FileNotFound,
    SystemResources,
    AccessDenied,
    PermissionDenied,
    ConnectionRefused,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Canceled,
    Unexpected,
};
pub fn connectUnix(io: std.Io, path: []const u8) ConnectUnixError!std.Io.net.Stream {
    const addr = std.Io.net.UnixAddress.init(path) catch |err| switch (err) {
        error.NameTooLong => {
            log.err("unix socket path '{s}' is too long ({})", .{ path, path.len });
            return error.Unexpected;
        },
    };
    return addr.connect(io) catch |err| switch (err) {
        error.FileNotFound,
        error.SystemResources,
        error.AccessDenied,
        error.PermissionDenied,
        error.ConnectionRefused,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.Canceled,
        error.Unexpected,
        => |e| return e,
        else => |e| {
            log.err("connect unix socket '{s}' unexpectedly failed with {t}", .{ path, e });
            return error.Unexpected;
        },
    };
}

fn unexpectedError(e: anyerror) error{Unexpected} {
    std.debug.print("unexpected error {s}\n", .{@errorName(e)});
    std.debug.dumpCurrentStackTrace(null);
    return error.Unexpected;
}

fn fmtRead(reader: *std.Io.Reader, n: usize, result: *FmtReadResult) FmtRead {
    return .{ .reader = reader, .n = n, .result = result };
}
const FmtReadResult = union(enum) {
    init,
    success,
    err: error{ ReadFailed, EndOfStream },
};
const FmtRead = struct {
    reader: *std.Io.Reader,
    n: usize,
    result: *FmtReadResult,
    pub fn format(r: FmtRead, writer: *std.Io.Writer) error{WriteFailed}!void {
        std.debug.assert(r.result.* == .init);
        if (r.reader.streamExact(writer, r.n)) {
            r.result.* = .success;
        } else |err| switch (err) {
            error.WriteFailed => return error.WriteFailed,
            error.ReadFailed, error.EndOfStream => |e| {
                r.result.* = .{ .err = e };
            },
        }
    }
};

pub fn ArrayPointer(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .pointer => |info| info,
        else => @compileError("ArrayPointer not implemented for " ++ @typeName(T)),
    };
    if (info.size != .slice) @compileError("ArrayPointer not implemented for " ++ @typeName(T));
    return @Pointer(.many, info.attrs, info.child, info.sentinel());
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

pub const GetAuthFilenameError = error{
    XauthorityEnvTooBig,
    HomeTooLong,
};

pub fn getAuthFilename(environ: std.process.Environ, kind: AuthFileKind, filename_buf: []u8) GetAuthFilenameError!?[]const u8 {
    switch (kind) {
        .env => {
            if (builtin.os.tag == .windows) {
                const xauth = environ.getWindows(std.unicode.wtf8ToWtf16LeStringLiteral("XAUTHORITY")) orelse return null;
                if (std.unicode.calcWtf8Len(xauth) > filename_buf.len) return error.XauthorityEnvTooBig;
                return filename_buf[0..std.unicode.wtf16LeToWtf8(filename_buf, xauth)];
            }
            return environ.getPosix("XAUTHORITY");
        },
        .home => {
            if (builtin.os.tag == .windows) return null;
            const home = environ.getPosix("HOME") orelse return null;
            const basename = ".Xauthority";
            const len = home.len + 1 + basename.len;
            if (len + 1 > filename_buf.len) return error.HomeTooLong;
            @memcpy(filename_buf[0..home.len], home);
            filename_buf[home.len] = '/';
            @memcpy(filename_buf[home.len + 1 ..][0..basename.len], basename);
            filename_buf[len] = 0;
            return filename_buf[0..len :0];
        },
    }
}

pub fn fmtMaybeString(s: ?[]const u8) FmtMaybeString {
    return .{ .s = s };
}
pub const FmtMaybeString = struct {
    s: ?[]const u8,
    pub fn format(f: FmtMaybeString, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (f.s) |string| {
            try writer.print("'{s}'", .{string});
        } else {
            try writer.print("<none>", .{});
        }
    }
};

pub const AuthFamily = enum(u16) {
    inet = 0,
    inet6 = 6,
    // local = 254,
    unix = 256,
    wild = 65535,
    _,
    pub fn expectedLen(self: AuthFamily) ?u8 {
        return switch (self) {
            .inet => 4,
            .inet6 => 16,
            else => null,
        };
    }
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

fn matchAddr(
    connect_host: *const Host,
    connect_addr: *const Address,
    file_addr: AuthFileAddr,
) bool {
    // todo: we'll probably need this to implement better address matching
    _ = connect_host;
    return switch (file_addr.family) {
        .inet => {
            if (file_addr.data.len != 4) {
                log.err("expected xauth inet addr to be 4 bytes but got {}", .{file_addr.data.len});
                return false;
            }
            const ip4 = switch (connect_addr.*) {
                .ip => |ip| switch (ip) {
                    .ip4 => |ip4| ip4,
                    .ip6 => return false,
                },
                .unix => return false,
            };
            return std.mem.eql(u8, &ip4.bytes, file_addr.data);
        },
        .inet6 => {
            if (file_addr.data.len != 16) {
                log.err("expected xauth inet6 addr to be 16 bytes but got {}", .{file_addr.data.len});
                return false;
            }
            const ip6 = switch (connect_addr.*) {
                .ip => |ip| switch (ip) {
                    .ip4 => return false,
                    .ip6 => |ip6| ip6,
                },
                .unix => return false,
            };
            return std.mem.eql(u8, &ip6.bytes, file_addr.data);
        },
        // not sure how to properly compare the paths here so I'm just
        // going to always return true if we've connected to any unix path
        .unix => connect_addr.* == .unix,
        .wild => true,
        _ => return false,
    };
}
fn matchDisplayNum(
    connect_display: Display,
    connect_parsed_display: *const ParsedDisplay,
    file_display_num_string: []const u8,
) bool {
    const connect_display_string = connect_display.string orelse return file_display_num_string.len == 0;
    // My guess is this means it applies to all displays
    if (file_display_num_string.len == 0) return true;
    if (std.fmt.parseInt(u16, file_display_num_string, 10)) |file_display_num| {
        return @backingInt(connect_parsed_display.display_num) == file_display_num;
    } else |_| {}
    (if (builtin.mode == .debug) std.debug.panic else log.err)(
        "TODO: implement matching display '{s}' against num '{s}'",
        .{ connect_display_string, file_display_num_string },
    );
    return false;
}

const AuthFileAddr = struct {
    family: AuthFamily,
    data: []const u8,
    pub fn format(self: AuthFileAddr, writer: *std.Io.Writer) error{WriteFailed}!void {
        const d = self.data;
        switch (self.family) {
            .inet => if (d.len == 4) {
                return try writer.print("{}.{}.{}.{}", .{ d[0], d[1], d[2], d[3] });
            },
            .inet6 => if (d.len == 16) {
                // TODO: format as an actual IPv6 address
                // try writer.print("{x}/inet6", .{fmtHexLower(d)});
            },
            .unix => return try writer.print("{s}/unix", .{d}),
            .wild => return try writer.print("*", .{}),
            _ => {},
        }
        try writer.print("{x}/{f}", .{ d, fmtEnum(self.family) });
    }
};

pub const AuthReader = struct {
    reader: *std.Io.Reader,
    state: State = .family,

    const State = union(enum) {
        family,
        dynamic_len: DynamicPart,
        dynamic_data: DynamicData,
    };
    const DynamicPart = enum {
        addr,
        display_num,
        name,
        data,
        pub fn next(part: DynamicPart) State {
            return switch (part) {
                .addr => .{ .dynamic_len = .display_num },
                .display_num => .{ .dynamic_len = .name },
                .name => .{ .dynamic_len = .data },
                .data => .family,
            };
        }
    };
    const DynamicData = struct {
        part: DynamicPart,
        len: u16,
        read_so_far: u16,
    };

    pub fn discardRemaining(self: *AuthReader) error{ ReadFailed, EndOfStream }!void {
        while (true) {
            switch (self.state) {
                .family => return,
                .dynamic_len => |part| {
                    _ = try self.takeDynamicLen(part);
                    std.debug.assert(self.state == .dynamic_data);
                },
                .dynamic_data => |*dynamic| {
                    try self.discardDynamic(dynamic.len - dynamic.read_so_far);
                    std.debug.assert(self.state != .dynamic_data);
                },
            }
        }
    }
    pub fn takeFamily(self: *AuthReader) error{ReadFailed}!?AuthFamily {
        std.debug.assert(self.state == .family);
        if (self.reader.takeInt(u16, .big)) |int| {
            self.state = .{ .dynamic_len = .addr };
            return @fromBackingInt(@intCast(int));
        } else |err| return switch (err) {
            error.EndOfStream => null,
            else => |e| e,
        };
    }

    pub fn takeDynamicLen(self: *AuthReader, part: DynamicPart) error{ ReadFailed, EndOfStream }!u16 {
        std.debug.assert(part == switch (self.state) {
            .family, .dynamic_data => unreachable,
            .dynamic_len => |p| p,
        });
        const len = try self.reader.takeInt(u16, .big);
        self.state = .{ .dynamic_data = .{
            .part = part,
            .len = len,
            .read_so_far = 0,
        } };
        return len;
    }

    pub fn finishDynamic(self: *AuthReader) void {
        const dynamic = switch (self.state) {
            .family, .dynamic_len => return,
            .dynamic_data => |*d| d,
        };
        std.debug.assert(dynamic.read_so_far == dynamic.len);
        self.state = dynamic.part.next();
    }

    pub fn discardDynamic(self: *AuthReader, n: usize) error{ ReadFailed, EndOfStream }!void {
        const dynamic = switch (self.state) {
            .family, .dynamic_len => unreachable,
            .dynamic_data => |*d| d,
        };
        std.debug.assert(dynamic.read_so_far + n <= dynamic.len);
        try self.reader.discardAll(n);
        dynamic.read_so_far += @intCast(n);
        if (dynamic.read_so_far == dynamic.len) {
            self.state = dynamic.part.next();
        }
    }
    pub fn readDynamic(self: *AuthReader, buf: []u8) error{ ReadFailed, EndOfStream }!void {
        const dynamic = switch (self.state) {
            .family, .dynamic_len => unreachable,
            .dynamic_data => |*d| d,
        };
        std.debug.assert(dynamic.read_so_far + buf.len <= dynamic.len);
        try self.reader.readSliceAll(buf);
        dynamic.read_so_far += @intCast(buf.len);
        if (dynamic.read_so_far == dynamic.len) {
            self.state = dynamic.part.next();
        }
    }
    pub fn takeDynamic(self: *AuthReader, n: usize) error{ ReadFailed, EndOfStream }![]u8 {
        const dynamic = switch (self.state) {
            .family, .dynamic_len => unreachable,
            .dynamic_data => |*d| d,
        };
        std.debug.assert(dynamic.read_so_far + n <= dynamic.len);
        const buf = try self.reader.take(n);
        dynamic.read_so_far += @intCast(n);
        if (dynamic.read_so_far == dynamic.len) {
            self.state = dynamic.part.next();
        }
        return buf;
    }

    pub fn streamDynamic(self: *AuthReader, writer: *std.Io.Writer, n: usize) !void {
        const dynamic = switch (self.state) {
            .family, .dynamic_len => unreachable,
            .dynamic_data => |*d| d,
        };
        std.debug.assert(dynamic.read_so_far + n <= dynamic.len);
        const buf = try self.reader.streamExact(writer, n);
        dynamic.read_so_far += @intCast(n);
        if (dynamic.read_so_far == dynamic.len) {
            self.state = dynamic.part.next();
        }
        return buf;
    }
    pub fn takeNameAndDataLen(self: *AuthReader, n: usize) error{ ReadFailed, EndOfStream }!struct { []u8, u16 } {
        const dynamic = switch (self.state) {
            .family, .dynamic_len => unreachable,
            .dynamic_data => |*d| d,
        };
        std.debug.assert(dynamic.part == .name);
        std.debug.assert(@as(usize, dynamic.read_so_far) + n == @as(usize, dynamic.len) + 2);
        const buf = try self.reader.take(n);
        const data_len = std.mem.readInt(u16, buf[n - 2 ..][0..2], .big);
        self.state = .{ .dynamic_data = .{
            .part = .data,
            .len = data_len,
            .read_so_far = 0,
        } };
        return .{ buf[0 .. n - 2], data_len };
    }
};

/// Call to handle a WriteFailed on the socket writer and/or RequestSink after the intial setup.
/// It will either return an error or nothing if the error means the connection to the X server
/// has been closed (std maps EPIPE to SocketUnconnected).
pub fn onWriteError(write_failed: error{WriteFailed}, err: std.Io.net.Stream.Writer.Error) !void {
    write_failed catch {};
    switch (err) {
        error.ConnectionResetByPeer, error.SocketUnconnected => |e| {
            log.info("connection closed ({t})", .{e});
        },
        else => |e| return e,
    }
}

pub const RequestSink = struct {
    writer: *std.Io.Writer,
    sequence: u16 = 0,

    pub fn CreateWindow(sink: *RequestSink, args: CreateWindowArgs, options: window.Options) error{WriteFailed}!void {
        const msg = inspectCreateWindow(&options);
        var offset: usize = 0;

        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.create_window),
            args.depth,
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg.len >> 2));
        try writeInt(sink.writer, &offset, u32, @backingInt(args.window_id));
        try writeInt(sink.writer, &offset, u32, @backingInt(args.parent_window_id));
        try writeInt(sink.writer, &offset, i16, args.x);
        try writeInt(sink.writer, &offset, i16, args.y);
        try writeInt(sink.writer, &offset, u16, args.width);
        try writeInt(sink.writer, &offset, u16, args.height);
        try writeInt(sink.writer, &offset, u16, args.border_width);
        try writeInt(sink.writer, &offset, u16, @backingInt(args.class));
        try writeInt(sink.writer, &offset, u32, @backingInt(args.visual_id));
        try writeInt(sink.writer, &offset, u32, @bitCast(msg.option_mask));
        inline for (@typeInfo(window.Options).@"struct".field_names) |field_name| {
            if (!isDefaultValue(&options, field_name)) {
                try writeInt(sink.writer, &offset, u32, optionToU32(@field(options, field_name)));
            }
        }
        std.debug.assert(msg.len == offset);
        sink.sequence +%= 1;
    }

    pub fn ChangeWindowAttributes(sink: *RequestSink, window_id: Window, options: window.Options) error{WriteFailed}!void {
        const msg = inspectChangeWindowAttributes(&options);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.change_window_attributes),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg.len >> 2));
        try writeInt(sink.writer, &offset, u32, @backingInt(window_id));
        try writeInt(sink.writer, &offset, u32, @bitCast(msg.option_mask));
        inline for (@typeInfo(window.Options).@"struct".field_names) |field_name| {
            if (!isDefaultValue(&options, field_name)) {
                try writeInt(sink.writer, &offset, u32, optionToU32(@field(options, field_name)));
            }
        }
        std.debug.assert(msg.len == offset);
        sink.sequence +%= 1;
    }

    pub fn DestroyWindow(sink: *RequestSink, window_id: Window) error{WriteFailed}!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.destroy_window),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(window_id));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn MapWindow(sink: *RequestSink, w: Window) error{WriteFailed}!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.map_window),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(w));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn UnmapWindow(sink: *RequestSink, w: Window) error{WriteFailed}!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.unmap_window),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(w));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn ConfigureWindow(
        sink: *RequestSink,
        window_id: Window,
        options: configure_window.Options,
    ) error{WriteFailed}!void {
        const msg = inspectConfigureWindow(&options);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.configure_window),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg.len >> 2));
        try writeInt(sink.writer, &offset, u32, @backingInt(window_id));
        try writeInt(sink.writer, &offset, u32, @bitCast(msg.option_mask));
        inline for (@typeInfo(configure_window.Options).@"struct".field_names) |field_name| {
            if (!isDefaultValue(&options, field_name)) {
                try writeInt(sink.writer, &offset, u32, optionToU32(@field(options, field_name)));
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
        inline for (@typeInfo(configure_window.Options).@"struct".field_names) |field_name| {
            if (!isDefaultValue(options, field_name)) {
                @field(option_mask, field_name) = 1;
                len += 4;
            }
        }
        return .{ .len = len, .option_mask = option_mask };
    }
    pub fn QueryTree(sink: *RequestSink, window_id: Window) error{WriteFailed}!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.query_tree),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(window_id));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn InternAtom(sink: *RequestSink, args: intern_atom.Args) error{WriteFailed}!void {
        const msg_len = intern_atom.getLen(args.name.len);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.intern_atom),
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
    ) error{WriteFailed}!void {
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
            @backingInt(Opcode.change_property),
            @backingInt(mode),
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(window_id));
        try writeInt(sink.writer, &offset, u32, @backingInt(property));
        try writeInt(sink.writer, &offset, u32, @backingInt(property_type));
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
    ) error{WriteFailed}!void {
        const msg_len = 24;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.get_property),
            @intFromBool(named.delete),
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(window_id));
        try writeInt(sink.writer, &offset, u32, @backingInt(named.property));
        try writeInt(sink.writer, &offset, u32, @backingInt(named.type));
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
    }) error{WriteFailed}!void {
        const msg_len = 24;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.grab_pointer),
            if (named.owner_events) 1 else 0,
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(named.grab_window));
        try writeInt(sink.writer, &offset, u16, @bitCast(named.event_mask));
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(named.pointer_mode),
            @backingInt(named.keyboard_mode),
        });
        try writeInt(sink.writer, &offset, u32, @backingInt(named.confine_to));
        try writeInt(sink.writer, &offset, u32, @backingInt(named.cursor));
        try writeInt(sink.writer, &offset, u32, @backingInt(named.time));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn UngrabPointer(sink: *RequestSink, time: Timestamp) error{WriteFailed}!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.ungrab_pointer),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(time));
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
    }) error{WriteFailed}!void {
        const msg_len = 24;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.warp_pointer),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(named.src_window));
        try writeInt(sink.writer, &offset, u32, @backingInt(named.dst_window));
        try writeInt(sink.writer, &offset, i16, named.src_x);
        try writeInt(sink.writer, &offset, i16, named.src_y);
        try writeInt(sink.writer, &offset, u16, named.src_width);
        try writeInt(sink.writer, &offset, u16, named.src_height);
        try writeInt(sink.writer, &offset, i16, named.dst_x);
        try writeInt(sink.writer, &offset, i16, named.dst_y);
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }
    pub fn OpenFont(sink: *RequestSink, font_id: Font, name: Slice(u16, [*]const u8)) error{WriteFailed}!void {
        const non_list_len =
            2 // opcode and unused
            + 2 // request length
            + 4 // font id
            + 4 // name length (2 bytes) and 2 unused bytes
        ;
        const msg_len = non_list_len + std.mem.alignForward(u16, name.len, 4);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.open_font),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(font_id));
        try writeInt(sink.writer, &offset, u16, name.len);
        try writeAll(sink.writer, &offset, &[_]u8{ 0, 0 }); // unused
        try writeAll(sink.writer, &offset, name.nativeSlice());
        try writePad4(sink.writer, &offset);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub fn CloseFont(sink: *RequestSink, font_id: Font) error{WriteFailed}!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.close_font),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(font_id));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn QueryFont(sink: *RequestSink, font: Fontable) error{WriteFailed}!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.query_font),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(font));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn ListFonts(sink: *RequestSink, max_names: u16, pattern: Slice(u16, [*]const u8)) error{WriteFailed}!void {
        const non_list_len =
            2 // opcode and unused
            + 2 // request length
            + 2 // max names
            + 2 // pattern length
        ;
        const msg_len = non_list_len + std.mem.alignForward(u16, pattern.len, 4);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.list_fonts),
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
    ) error{WriteFailed}!void {
        const non_list_len =
            2 // opcode and odd_length
            + 2 // request length
            + 4 // font_id
        ;
        const msg_len = non_list_len + std.mem.alignForward(u16, text.len * 2, 4);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.query_text_extents),
            @intCast(text.len % 2), // odd_length
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(font_id));
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
        depth: Depth,
        width: u16,
        height: u16,
    }) error{WriteFailed}!void {
        const msg_len = 16;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.create_pixmap),
            named.depth.byte(),
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(id));
        try writeInt(sink.writer, &offset, u32, @backingInt(drawable));
        try writeInt(sink.writer, &offset, u16, named.width);
        try writeInt(sink.writer, &offset, u16, named.height);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub fn FreePixmap(sink: *RequestSink, id: Pixmap) error{WriteFailed}!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.free_pixmap),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(id));
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub fn CreateGc(sink: *RequestSink, gc: GraphicsContext, drawable: Drawable, opt: CreateGcOptions) error{WriteFailed}!void {
        const msg = inspectCreateGc(&opt);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.create_gc),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg.len >> 2));
        try writeInt(sink.writer, &offset, u32, @backingInt(gc));
        try writeInt(sink.writer, &offset, u32, @backingInt(drawable));
        try writeInt(sink.writer, &offset, u32, @bitCast(msg.option_mask));
        inline for (@typeInfo(CreateGcOptions).@"struct".field_names) |field_name| {
            if (!isDefaultValue(opt, field_name)) {
                try writeInt(sink.writer, &offset, u32, optionToU32(@field(opt, field_name)));
            }
        }
        std.debug.assert(msg.len == offset);
        sink.sequence +%= 1;
    }
    pub fn ChangeGc(sink: *RequestSink, gc: GraphicsContext, opt: ChangeGcOptions) error{WriteFailed}!void {
        const msg = inspectChangeGc(&opt);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.change_gc),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg.len >> 2));
        try writeInt(sink.writer, &offset, u32, @backingInt(gc));
        try writeInt(sink.writer, &offset, u32, @bitCast(msg.option_mask));
        inline for (@typeInfo(ChangeGcOptions).@"struct".field_names) |field_name| {
            if (!isDefaultValue(opt, field_name)) {
                try writeInt(sink.writer, &offset, u32, optionToU32(@field(opt, field_name)));
            }
        }
        std.debug.assert(msg.len == offset);
        sink.sequence +%= 1;
    }

    pub fn FreeGc(sink: *RequestSink, gc: GraphicsContext) error{WriteFailed}!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.free_gc),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(gc));
        std.debug.assert(offset == msg_len);
        sink.sequence +%= 1;
    }

    pub fn ClearArea(
        sink: *RequestSink,
        window_id: Window,
        area: Rectangle,
        named: struct { exposures: bool },
    ) error{WriteFailed}!void {
        const msg_len = 16;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.clear_area),
            if (named.exposures) 1 else 0,
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(window_id));
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
    }) error{WriteFailed}!void {
        const msg_len = 28;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.copy_area),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(named.src_drawable));
        try writeInt(sink.writer, &offset, u32, @backingInt(named.dst_drawable));
        try writeInt(sink.writer, &offset, u32, @backingInt(named.gc));
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
        coordinate_mode: CoordinateMode,
        drawable: Drawable,
        gc: GraphicsContext,
        points: Slice(u18, [*]const XY(i16)),
    ) error{WriteFailed}!void {
        const msg_len: u18 = poly_line_header_size + points.len * 4; // each point is 4 bytes (i16 x, i16 y)
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.poly_line),
            @backingInt(coordinate_mode),
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg_len >> 2));
        try writeInt(sink.writer, &offset, u32, @backingInt(drawable));
        try writeInt(sink.writer, &offset, u32, @backingInt(gc));
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
    ) error{WriteFailed}!void {
        try sink.polyRectangle(drawable, gc, rectangles, @backingInt(Opcode.poly_rectangle));
    }

    pub inline fn PolyFillRectangle(
        sink: *RequestSink,
        drawable: Drawable,
        gc: GraphicsContext,
        rectangles: Slice(u18, [*]const Rectangle),
    ) error{WriteFailed}!void {
        try sink.polyRectangle(drawable, gc, rectangles, @backingInt(Opcode.poly_fill_rectangle));
    }

    fn polyRectangle(
        sink: *RequestSink,
        drawable: Drawable,
        gc: GraphicsContext,
        rectangles: Slice(u18, [*]const Rectangle),
        opcode: u8,
    ) error{WriteFailed}!void {
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
        try writeInt(sink.writer, &offset, u32, @backingInt(drawable));
        try writeInt(sink.writer, &offset, u32, @backingInt(gc));
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
    ) error{WriteFailed}!void {
        var offset: usize = try PutImageStart(sink, data.len, args);
        try writeAll(sink.writer, &offset, data.nativeSlice());
        offset += data.len;
        try PutImageFinish(sink, 0);
    }

    pub fn PutImageStart(
        sink: *RequestSink,
        /// image_size is calculated by height * calcScanline(...)
        image_size: u18,
        args: put_image.Args,
    ) error{WriteFailed}!u2 {
        const pad_len: u2 = pad4Len(@truncate(image_size));
        const msg_len: u18 = put_image.non_list_len + image_size + @as(u18, pad_len);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.put_image),
            @backingInt(args.format),
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg_len >> 2));
        try writeInt(sink.writer, &offset, u32, @backingInt(args.drawable));
        try writeInt(sink.writer, &offset, u32, @backingInt(args.gc_id));
        try writeInt(sink.writer, &offset, u16, args.width);
        try writeInt(sink.writer, &offset, u16, args.height);
        try writeInt(sink.writer, &offset, i16, args.x);
        try writeInt(sink.writer, &offset, i16, args.y);
        try writeAll(sink.writer, &offset, &[_]u8{
            switch (args.format) {
                .bitmap, .xy_pixmap => |left_pad| left_pad,
                .z_pixmap => 0,
            },
            args.depth.byte(),
            0, // unused
            0, // unused
        });
        std.debug.assert((offset & 0x3) == 0);
        std.debug.assert(offset == put_image.non_list_len);
        return pad_len;
    }

    pub fn PutImageFinish(sink: *RequestSink, pad_len: u2) error{WriteFailed}!void {
        try sink.writer.splatByteAll(0, pad_len);
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
    }) error{WriteFailed}!void {
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
            @backingInt(Opcode.get_image),
            @backingInt(named.format),
        });
        try writeInt(sink.writer, &offset, u16, @intCast(msg_len >> 2));
        try writeInt(sink.writer, &offset, u32, @backingInt(named.drawable));
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
    ) error{WriteFailed}!void {
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
            @backingInt(Opcode.poly_text8),
            0, // unused
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(drawable));
        try writeInt(sink.writer, &offset, u32, @backingInt(gc));
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
                try writeInt(sink.writer, &offset, u32, @backingInt(font));
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
    ) (error{TextTooLong} || error{WriteFailed})!void {
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
    ) error{WriteFailed}!void {
        const msg_len =
            2 // opcode and string_length
            + 2 // request length
            + 4 // drawable id
            + 4 // gc id
            + 4 // x, y coordinates
            + std.mem.alignForward(u16, text.len, 4);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.image_text8),
            text.len,
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(drawable));
        try writeInt(sink.writer, &offset, u32, @backingInt(gc));
        try writeInt(sink.writer, &offset, i16, pos.x);
        try writeInt(sink.writer, &offset, i16, pos.y);
        try writeAll(sink.writer, &offset, text.nativeSlice());
        try writePad4(sink.writer, &offset);
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    pub fn CreateColormap(
        sink: *RequestSink,
        alloc: enum(u8) { none = 0, all = 1 },
        id: Colormap,
        window_id: Window,
        visual: Visual,
    ) error{WriteFailed}!void {
        const msg_len = 16;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.create_colormap),
            @backingInt(alloc),
        });
        try writeInt(sink.writer, &offset, u16, msg_len >> 2);
        try writeInt(sink.writer, &offset, u32, @backingInt(id));
        try writeInt(sink.writer, &offset, u32, @backingInt(window_id));
        try writeInt(sink.writer, &offset, u32, @backingInt(visual));
        std.debug.assert(msg_len == offset);
        sink.sequence +%= 1;
    }

    // free_colormap = 79,
    pub fn QueryExtension(sink: *RequestSink, name: Slice(u16, [*]const u8)) error{WriteFailed}!void {
        const non_list_len = 8;
        const msg_len = non_list_len + std.mem.alignForward(u16, name.len, 4);
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.query_extension),
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
    ) error{WriteFailed}!void {
        const msg_len = 8;
        var offset: usize = 0;
        try writeAll(sink.writer, &offset, &[_]u8{
            @backingInt(Opcode.get_keyboard_mapping),
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

pub const native_endian = builtin.target.cpu.arch.endian();

pub fn writeAll(writer: *std.Io.Writer, offset: *usize, buf: []const u8) error{WriteFailed}!void {
    try writer.writeAll(buf);
    offset.* += buf.len;
}
pub fn writeInt(writer: *std.Io.Writer, offset: *usize, comptime T: type, int: T) error{WriteFailed}!void {
    try writer.writeInt(T, int, native_endian);
    offset.* += @sizeOf(T);
}
pub fn writePad4(writer: *std.Io.Writer, offset: *usize) error{WriteFailed}!void {
    const pad_len = pad4Len(@truncate(offset.*));
    try writer.splatByteAll(0, pad_len);
    offset.* += pad_len;
}

fn writeAllNoFlush(writer: *std.Io.Writer, buf: []const u8) void {
    std.debug.assert(buf.len <= writer.buffer.len - writer.end);
    @memcpy(writer.buffer[writer.end..][0..buf.len], buf);
    writer.end += buf.len;
}
pub fn writeIntNoFlush(writer: *std.Io.Writer, comptime T: type, int: T) void {
    writeAllNoFlush(writer, std.mem.asBytes(&int));
}

fn writeSetupHeader(writer: *std.Io.Writer, name: Slice(u16, [*]const u8), data_len: u16) error{WriteFailed}!void {
    try writer.writeAll(&[_]u8{
        @as(u8, if (native_endian == .big) BigEndian else LittleEndian),
        0, // unused
    });
    try writer.writeInt(u16, 11, native_endian); // X11 protocol major version
    try writer.writeInt(u16, 0, native_endian); // X11 protocol minor version
    try writer.writeInt(u16, name.len, native_endian);
    try writer.writeInt(u16, data_len, native_endian);
    try writer.splatByteAll(0, 2); // unused
    try writer.writeAll(name.nativeSlice());
    try writer.splatByteAll(0, pad4Len(@truncate(name.len)));
}
fn writeSetupData(writer: *std.Io.Writer, data: Slice(u16, [*]const u8)) error{WriteFailed}!void {
    try writer.writeAll(data.nativeSlice());
    try writer.splatByteAll(0, pad4Len(@truncate(data.len)));
}

pub const ResourceBase = enum(u32) {
    _,

    pub fn add(r: ResourceBase, offset: u32) Resource {
        return @fromBackingInt(@intCast(@backingInt(r) + offset));
    }

    pub fn fromInt(i: u32) ResourceBase {
        return @fromBackingInt(@intCast(i));
    }

    pub fn format(v: ResourceBase, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.print("ResourceBase({})", .{@backingInt(v)});
    }
};

pub const ResourceMask = enum(u32) {
    _,

    pub fn fromInt(i: u32) ResourceMask {
        return @fromBackingInt(@intCast(i));
    }

    pub fn format(v: ResourceMask, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.print("ResourceMask(0x{x})", .{@backingInt(v)});
    }
};

pub const IdRange = @import("x/IdRange.zig");

pub const Resource = enum(u32) {
    none = 0,
    _,

    pub fn window(r: Resource) Window {
        return @fromBackingInt(@intCast(@backingInt(r)));
    }

    pub fn drawable(r: Resource) Drawable {
        return @fromBackingInt(@intCast(@backingInt(r)));
    }

    pub fn font(r: Resource) Font {
        return @fromBackingInt(@intCast(@backingInt(r)));
    }

    pub fn fontable(r: Resource) Fontable {
        return @fromBackingInt(@intCast(@backingInt(r)));
    }

    pub fn graphicsContext(r: Resource) GraphicsContext {
        return @fromBackingInt(@intCast(@backingInt(r)));
    }

    pub fn pixmap(r: Resource) Pixmap {
        return @fromBackingInt(@intCast(@backingInt(r)));
    }

    pub fn picture(r: Resource) render.Picture {
        return @fromBackingInt(@intCast(@backingInt(r)));
    }

    pub fn glyphSet(r: Resource) render.GlyphSet {
        return @fromBackingInt(@intCast(@backingInt(r)));
    }

    pub fn colormap(r: Resource) Colormap {
        return @fromBackingInt(@intCast(@backingInt(r)));
    }

    pub fn fixesRegion(r: Resource) fixes.Region {
        return @fromBackingInt(@intCast(@backingInt(r)));
    }

    pub fn format(v: Resource, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .none => try writer.writeAll(".none"),
            _ => |d| try writer.print("{d}", .{d}),
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
        return @fromBackingInt(@intCast(i));
    }

    pub fn format(v: Drawable, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .none => try writer.writeAll(".none"),
            _ => |d| try writer.print("{d}", .{d}),
        }
    }
};

pub const Window = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Window {
        return @fromBackingInt(@intCast(i));
    }

    pub fn resource(w: Window) Resource {
        return @fromBackingInt(@intCast(@backingInt(w)));
    }
    pub fn drawable(w: Window) Drawable {
        return @fromBackingInt(@intCast(@backingInt(w)));
    }

    pub fn format(v: Window, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .none => try writer.writeAll(".none"),
            _ => |d| try writer.print("{d}", .{d}),
        }
    }
};

pub const Cursor = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Cursor {
        return @fromBackingInt(@intCast(i));
    }

    pub fn format(v: Cursor, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .none => try writer.writeAll(".none"),
            _ => |d| try writer.print("{d}", .{d}),
        }
    }
};

pub const Font = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Font {
        return @fromBackingInt(@intCast(i));
    }

    pub fn fontable(f: Font) Fontable {
        return @fromBackingInt(@intCast(@backingInt(f)));
    }

    pub fn format(v: Font, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .none => try writer.writeAll(".none"),
            _ => |d| try writer.print("{d}", .{d}),
        }
    }
};

pub const Fontable = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Fontable {
        return @fromBackingInt(@intCast(i));
    }

    pub fn graphicsContext(f: Fontable) GraphicsContext {
        return @fromBackingInt(@intCast(@backingInt(f)));
    }

    pub fn font(f: Fontable) Font {
        return @fromBackingInt(@intCast(@backingInt(f)));
    }

    pub fn format(v: Fontable, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .none => try writer.writeAll(".none"),
            _ => |d| try writer.print("{d}", .{d}),
        }
    }
};

pub const Colormap = enum(u32) {
    copy_from_parent = 0,
    _,

    pub fn fromInt(i: u32) Colormap {
        return @fromBackingInt(@intCast(i));
    }

    pub fn format(v: Colormap, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .copy_from_parent => try writer.writeAll(".copy_from_parent"),
            _ => |d| try writer.print("{d}", .{d}),
        }
    }
};

pub const Visual = enum(u32) {
    pub fn fromInt(i: u32) Visual {
        return @fromBackingInt(@intCast(i));
    }

    copy_from_parent = 0,
    _,

    pub fn format(visual: Visual, writer: *std.Io.Writer) error{WriteFailed}!void {
        try fmtEnum(visual).format(writer);
    }
};

pub const Pixmap = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) Pixmap {
        return @fromBackingInt(@intCast(i));
    }

    pub fn drawable(p: Pixmap) Drawable {
        return @fromBackingInt(@intCast(@backingInt(p)));
    }

    pub fn format(v: Pixmap, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .none => try writer.writeAll(".none"),
            _ => |d| try writer.print("{d}", .{d}),
        }
    }
};

/// Various information for graphics output is stored in a graphics context such as foreground pixel, background pixel, line width, clipping region, and so on.
/// A graphics context can only be used with drawables that have the same root and the same depth as the graphics context.
pub const GraphicsContext = enum(u32) {
    none = 0,
    _,

    pub fn fromInt(i: u32) GraphicsContext {
        return @fromBackingInt(@intCast(i));
    }

    pub fn fontable(g: GraphicsContext) Fontable {
        return @fromBackingInt(@intCast(@backingInt(g)));
    }

    pub fn format(v: GraphicsContext, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (v) {
            .none => try writer.writeAll(".none"),
            _ => |d| try writer.print("{d}", .{d}),
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
        return @fromBackingInt(@intCast(i));
    }

    /// X11 `CurrentTime`. Never generated by the server.
    current_time = 0,

    _,

    pub fn format(ts: Timestamp, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (ts) {
            .current_time => try writer.writeAll(".current_time"),
            _ => |d| try writer.print("{d}", .{d}),
        }
    }
};

pub const Opcode = enum(u8) {
    create_window = 1,
    change_window_attributes = 2,
    destroy_window = 4,
    map_window = 8,
    unmap_window = 10,
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
    fill_poly = 69,
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

pub fn isDefaultValue(s: anytype, comptime field_name: []const u8) bool {
    const T = switch (@typeInfo(@TypeOf(s))) {
        .pointer => |info| info.child,
        else => @TypeOf(s),
    };
    const default_value = @field(@as(T, .{}), field_name);
    switch (@typeInfo(@FieldType(T, field_name))) {
        .optional => {
            comptime std.debug.assert(default_value == null); // we're assuming all Optionals default to null
            return @field(s, field_name) == null;
        },
        else => {
            return @field(s, field_name) == default_value;
        },
    }
}

pub fn optionToU32(value: anytype) u32 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => return @intFromBool(value),
        .@"enum" => return @backingInt(value),
        .optional => |opt| {
            switch (@typeInfo(opt.child)) {
                .bool => return @intFromBool(value.?),
                .@"enum" => return @backingInt(value.?),
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
    KeymapState: u1 = 0,
    Exposure: u1 = 0,
    VisibilityChange: u1 = 0,
    /// Results in DestroyNotify, UnmapNotify, MapNotify, ReparentNotify,
    /// ConfigureNotify, GravityNotify, CirculateNotify.
    StructureNotify: u1 = 0,
    ResizeRedirect: u1 = 0,
    /// Results in the same events as StructureNotify as well as CreateNotify.
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
        colormap: Colormap = .copy_from_parent,
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
    inline for (@typeInfo(window.Options).@"struct".field_names) |field_name| {
        if (!isDefaultValue(options, field_name)) {
            @field(option_mask, field_name) = 1;
            len += 4;
        }
    }
    return .{ .len = len, .option_mask = option_mask };
}

fn inspectChangeWindowAttributes(options: *const window.Options) struct {
    len: u18,
    option_mask: window.OptionMask,
} {
    const non_option_len: u18 =
        2 // opcode and unused
        + 2 // request length
        + 4 // window id
        + 4 // window options value-mask
    ;
    var len: u18 = non_option_len;
    var option_mask: window.OptionMask = .{};
    inline for (@typeInfo(window.Options).@"struct".field_names) |field_name| {
        if (!isDefaultValue(options, field_name)) {
            @field(option_mask, field_name) = 1;
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
        buf[0] = @backingInt(Opcode.change_window_attributes);
        buf[1] = 0; // unused

        // buf[2-3] is the len, set at the end of the function

        writeIntNative(u32, buf + 4, @backingInt(window_id));
        var request_len: u16 = non_option_len;
        var option_mask: window.OptionMask = .{};

        inline for (@typeInfo(window.Options).@"struct".field_names) |field_name| {
            if (!isDefaultValue(options, field_name)) {
                writeIntNative(u32, buf + request_len, optionToU32(@field(options, field_name)));
                @field(option_mask, field_name) = 1;
                request_len += 4;
            }
        }

        writeIntNative(u32, buf + 8, @bitCast(option_mask));
        std.debug.assert((request_len & 0x3) == 0);
        writeIntNative(u16, buf + 2, request_len >> 2);
        return request_len;
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
        kind: enum(u8) { Reply = @backingInt(ServerMsgKind.Reply) },
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
        kind: enum(u8) { Reply = @backingInt(ServerMsgKind.Reply) },
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
        buf[0] = @backingInt(Opcode.get_font_path);
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
pub const CreateGcOptions = struct {
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
pub const ChangeGcOptions = struct {
    // TODO: add all the options
    // function copy
    // plane_mask all ones
    foreground: ?u32 = null,
    background: ?u32 = null,
    line_width: ?u16 = null,
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
    subwindow_mode: ?SubWindowMode = null,
    graphics_exposures: ?bool = null,
    // clip_x_origin 0
    // clip_y_origin 0
    // clip_mask: ?Font = null,
    // dash_offset 0
    // dashes the list 4, 4
};

pub const create_colormap = struct {
    pub const len = 16;
    pub const Args = struct {
        id: Colormap,
        window_id: Window,
        visual_id: Visual,
        alloc: enum(u8) { none, all },
    };
    pub fn serialize(buf: [*]u8, args: Args) void {
        buf[0] = @backingInt(Opcode.create_colormap);
        buf[1] = @backingInt(args.alloc);
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, args.id);
        writeIntNative(u32, buf + 8, args.window_id);
        writeIntNative(u32, buf + 12, args.visual_id);
    }
};

pub const free_colormap = struct {
    pub const len = 8;
    pub fn serialize(buf: [*]u8, id: Colormap) void {
        buf[0] = @backingInt(Opcode.free_colormap);
        buf[1] = 0; // unused
        writeIntNative(u16, buf + 2, len >> 2);
        writeIntNative(u32, buf + 4, @backingInt(id));
    }
};

fn inspectCreateGc(options: *const CreateGcOptions) struct {
    len: u18,
    option_mask: GcOptionMask,
} {
    const non_option_len: u18 =
        2 // opcode and unused
        + 2 // request length
        + 4 // gc id
        + 4 // drawable id
        + 4 // option mask
    ;

    var len: u18 = non_option_len;
    var option_mask: GcOptionMask = .{};
    inline for (@typeInfo(CreateGcOptions).@"struct".field_names) |field_name| {
        if (!isDefaultValue(options, field_name)) {
            @field(option_mask, field_name) = 1;
            len += 4;
        }
    }
    return .{ .len = len, .option_mask = option_mask };
}

fn inspectChangeGc(options: *const ChangeGcOptions) struct {
    len: u18,
    option_mask: GcOptionMask,
} {
    const non_option_len: u18 =
        2 // opcode and unused
        + 2 // request length
        + 4 // gc id
        + 4 // option mask
    ;

    var len: u18 = non_option_len;
    var option_mask: GcOptionMask = .{};
    inline for (@typeInfo(ChangeGcOptions).@"struct".field_names) |field_name| {
        if (!isDefaultValue(options, field_name)) {
            @field(option_mask, field_name) = 1;
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

pub const ScanlinePad = enum {
    @"8",
    @"16",
    @"32",
    pub fn fromByte(byte: u8) ?ScanlinePad {
        return switch (byte) {
            8 => .@"8",
            16 => .@"16",
            32 => .@"32",
            else => null,
        };
    }
    pub fn bitCount(pad: ScanlinePad, comptime T: type) T {
        return switch (pad) {
            .@"8" => 8,
            .@"16" => 16,
            .@"32" => 32,
        };
    }
    pub fn byteCount(pad: ScanlinePad, comptime T: type) T {
        return switch (pad) {
            .@"8" => 1,
            .@"16" => 2,
            .@"32" => 4,
        };
    }
};

pub const PixelSize = enum {
    @"1",
    @"2",
    @"4",
    pub fn fromByte(depth: u8) PixelSize {
        return switch (depth) {
            0...8 => .@"1",
            9...16 => .@"2",
            else => .@"4",
        };
    }
    pub fn fromDepth(depth: Depth) PixelSize {
        return switch (depth) {
            .@"1", .@"4", .@"8" => .@"1",
            .@"15", .@"16" => .@"2",
            .@"24" => .@"4",
            .@"32" => .@"4",
        };
    }
    pub fn byteCount(s: PixelSize, comptime T: type) T {
        return switch (s) {
            .@"1" => 1,
            .@"2" => 2,
            .@"4" => 4,
        };
    }
    pub fn bitCount(s: PixelSize, comptime T: type) T {
        return switch (s) {
            .@"1" => 8,
            .@"2" => 16,
            .@"4" => 32,
        };
    }
};

pub const ImageFormat = union(enum) {
    bitmap: u8, // the left-pad
    xy_pixmap: u8, // the left-pad
    z_pixmap,
};

/// returns the size of a scanline
/// max possible return value fits within a u18 which is verified by the "max calcScanline" test
pub fn calcScanline(
    pad: ScanlinePad,
    depth: u8,
    width: u16,
    format: union(enum) {
        bit_or_xy: u8, // the left-pad
        z_pixmap,
    },
) u18 {
    const content_bit_count: u32 = switch (format) {
        // For bitmap and XY format, each bit plane is padded separately
        // The scanline contains (width + left_pad) bits
        .bit_or_xy => |left_pad| @as(u32, width) + @as(u32, left_pad),
        .z_pixmap => @as(u32, width) * PixelSize.fromByte(depth).bitCount(u32),
    };
    switch (pad) {
        inline else => |pad_ct| {
            const numerator: u32 = (content_bit_count + pad_ct.bitCount(comptime_int) - 1) / pad_ct.bitCount(comptime_int);
            return @intCast(numerator * pad.byteCount(u32));
        },
    }
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
        format: ImageFormat,
        drawable: Drawable,
        gc_id: GraphicsContext,
        width: u16,
        height: u16,
        x: i16,
        y: i16,
        depth: Depth,
    };
    /// Calculate the max height for PutImage based on the given scanline.
    /// Scanline is the return value of calcScanline which is guaranteed to
    /// be 4-byte aligned.
    pub fn calcMaxHeight(scanline: u18) u16 {
        std.debug.assert((scanline & 3) == 0);
        if (scanline == 0) return std.math.maxInt(u16);
        const max_request_bytes: u18 = std.math.maxInt(u16) * 4;
        const max_data_bytes: u18 = max_request_bytes - put_image.non_list_len;
        // with scanline being >= 4, this division should always fit in a u16
        return @intCast(@divTrunc(max_data_bytes, scanline));
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
        const Self = @This();
        pub const zero: Self = .{ .x = 0, .y = 0 };
        pub fn eql(self: Self, other: Self) bool {
            return std.meta.eql(self.x, other.x) and std.meta.eql(self.y, other.y);
        }
    };
}

pub fn writeIntNative(comptime T: type, buf: [*]u8, value: T) void {
    @as(*align(1) T, @ptrCast(buf)).* = value;
}

pub const Atom = enum(u32) {
    None = 0,
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
    font = @backingInt(ErrorCodeFont.font),
    match = 8,
    drawable = 9,
    access = 10,
    alloc = 11,
    colormap = 12,
    gcontext = 13,
    id_choice = 14,
    name = @backingInt(ErrorCodeOpcode.name),
    length = @backingInt(ErrorCodeOpcode.length),
    implementation = 17,
};

pub const ServerMsgCategory = @typeInfo(ServerMsgKind).@"union".tag_type.?;
pub const ServerMsgKind = union(enum) {
    Error,
    Reply,

    // Core Events (3 - 63)
    KeyPress,
    KeyRelease,
    ButtonPress,
    ButtonRelease,
    MotionNotify,
    EnterNotify,
    LeaveNotify,
    FocusIn,
    FocusOut,
    KeymapNotify,
    Expose,
    GraphicsExposure,
    NoExposure,
    VisibilityNotify,
    CreateNotify,
    DestroyNotify,
    UnmapNotify,
    MapNotify,
    MapRequest,
    ReparentNotify,
    ConfigureNotify,
    ConfigureRequest,
    GravityNotify,
    ResizeRequest,
    CirculateNotify,
    CirculateRequest,
    PropertyNotify,
    SelectionClear,
    SelectionRequest,
    SelectionNotify,
    ColormapNotify,
    ClientMessage,
    MappingNotify,
    GenericEvent,
    // 36 - 63
    UnknownCoreEvent: u6,
    // 64 - 127
    ExtensionEvent: u7,

    pub fn fromU7(byte: u7) ServerMsgKind {
        return switch (byte) {
            0 => .Error,
            1 => .Reply,
            2 => .KeyPress,
            3 => .KeyRelease,
            4 => .ButtonPress,
            5 => .ButtonRelease,
            6 => .MotionNotify,
            7 => .EnterNotify,
            8 => .LeaveNotify,
            9 => .FocusIn,
            10 => .FocusOut,
            11 => .KeymapNotify,
            12 => .Expose,
            13 => .GraphicsExposure,
            14 => .NoExposure,
            15 => .VisibilityNotify,
            16 => .CreateNotify,
            17 => .DestroyNotify,
            18 => .UnmapNotify,
            19 => .MapNotify,
            20 => .MapRequest,
            21 => .ReparentNotify,
            22 => .ConfigureNotify,
            23 => .ConfigureRequest,
            24 => .GravityNotify,
            25 => .ResizeRequest,
            26 => .CirculateNotify,
            27 => .CirculateRequest,
            28 => .PropertyNotify,
            29 => .SelectionClear,
            30 => .SelectionRequest,
            31 => .SelectionNotify,
            32 => .ColormapNotify,
            33 => .ClientMessage,
            34 => .MappingNotify,
            35 => .GenericEvent,
            36...63 => |value| .{ .UnknownCoreEvent = @intCast(value) },
            64...127 => |value| .{ .ExtensionEvent = @intCast(value) },
        };
    }
    pub fn toByte(self: ServerMsgKind) u8 {
        return switch (self) {
            .Error => 0,
            .Reply => 1,
            .KeyPress => 2,
            .KeyRelease => 3,
            .ButtonPress => 4,
            .ButtonRelease => 5,
            .MotionNotify => 6,
            .EnterNotify => 7,
            .LeaveNotify => 8,
            .FocusIn => 9,
            .FocusOut => 10,
            .KeymapNotify => 11,
            .Expose => 12,
            .GraphicsExposure => 13,
            .NoExposure => 14,
            .VisibilityNotify => 15,
            .CreateNotify => 16,
            .DestroyNotify => 17,
            .UnmapNotify => 18,
            .MapNotify => 19,
            .MapRequest => 20,
            .ReparentNotify => 21,
            .ConfigureNotify => 22,
            .ConfigureRequest => 23,
            .GravityNotify => 24,
            .ResizeRequest => 25,
            .CirculateNotify => 26,
            .CirculateRequest => 27,
            .PropertyNotify => 28,
            .SelectionClear => 29,
            .SelectionRequest => 30,
            .SelectionNotify => 31,
            .ColormapNotify => 32,
            .ClientMessage => 33,
            .MappingNotify => 34,
            .GenericEvent => 35,
            .UnknownCoreEvent => |value| value,
            .ExtensionEvent => |value| value,
        };
    }
};

test "ServerMsgKind fromByte" {
    for (0..255) |value| {
        const kind = ServerMsgKind.fromU7(@truncate(value));
        try testing.expectEqual(@as(u7, @truncate(value)), kind.toByte());
    }
}

pub fn enumNamedValue(comptime E: type, e: E) ?E {
    if (@typeInfo(E).@"enum".mode == .exhaustive) @compileError("enumNamedValue only valid on non-exhaustive enums");
    return if (std.enums.tagName(E, e) == null) null else e;
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
        return @fromBackingInt(@intCast(result));
    }

    pub fn format(kbm: KeyButtonMask, writer: *std.Io.Writer) error{WriteFailed}!void {
        var any = false;

        try writer.writeAll("KeyButtonMask{");
        inline for (@typeInfo(KeyButtonMask).@"struct".field_names) |field_name| {
            if (comptime std.mem.startsWith(u8, field_name, "_"))
                continue;

            const value = @field(kbm, field_name);

            if (value) {
                if (any) {
                    try writer.writeAll("|");
                }
                try writer.writeAll(field_name);
                any = true;
            }
        }
        if (!any) {
            try writer.writeAll("<empty>");
        }
        try writer.writeAll("}");
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
    std.debug.assert(@sizeOf(ScreenHeader) == 40);
}
pub const ScreenHeader = extern struct {
    root: Window,
    colormap: Colormap,
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
    // pub fn findMatchingVisualType(self: *@This(), desired_depth: u8, desired_class: VisualType.Class, allocator: std.mem.Allocator) !VisualType {
    //     const depths = try self.getAllowedDepths(allocator);
    //     defer allocator.free(depths);

    //     for (depths) |depth| {
    //         if (depth.depth != desired_depth) continue;
    //         for (depth.getVisualTypes()) |visual_type| {
    //             if (visual_type.class != desired_class) continue;
    //             return visual_type;
    //         }
    //     }
    //     return error.VisualTypeNotFound;
    // }
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
    class: NonExhaustive(Class),
    bits_per_rgb_value: u8,
    colormap_entries: u16,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    unused: u32,
};

pub fn NonExhaustive(comptime T: type) type {
    const info = switch (@typeInfo(T)) {
        .@"enum" => |info| info,
        else => |info| @compileError("expected an Enum type but got a(n) " ++ @tagName(info)),
    };
    std.debug.assert(info.mode == .exhaustive);
    var values: [info.field_values.len]info.tag_type = undefined;
    for (&values, info.field_values) |*value, field_value| value.* = field_value;
    return @Enum(info.tag_type, .nonexhaustive, info.field_names, &values);
}
pub const ImageByteOrder = enum(u8) {
    lsb_first = 0,
    msb_first = 1,
};

comptime {
    std.debug.assert(@sizeOf(Setup) == 40);
}
/// All the connect setup fields that are at fixed offsets
pub const Setup = extern struct {
    status: enum(u8) { success = 1 },
    unused1: u8,
    version_major: u16,
    version_minor: u16,
    word_count: u16,
    release_number: u32,
    resource_id_base: ResourceBase,
    resource_id_mask: ResourceMask,
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
    unused2: u32,

    pub fn required(setup: *const Setup) u35 {
        // The first 8 bytes of Setup are the common reply header, which
        // Source does not count in its word_count tracking. Use
        // @sizeOf(Setup) - 8 to match what Source considers "taken".
        return (@sizeOf(Setup) - 8) +|
            @as(u35, setup.vendor_len) +|
            @as(u35, pad4Len(@truncate(setup.vendor_len))) +|
            (@sizeOf(Format) *| @as(u35, setup.format_count)) +|
            (@sizeOf(ScreenHeader) *| @as(u35, setup.root_screen_count));
    }
    pub fn format(setup: Setup, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.print(
            "release=0x{x} res(base=0x{x} mask=0x{x}) motion-buf={} max-req={} screen-count={} format-count={} image-endian={f} bmp(order={} scan-unit={} scan-pad={}) keycodes={}-{}",
            .{
                setup.release_number,
                @backingInt(setup.resource_id_base),
                @backingInt(setup.resource_id_mask),
                setup.motion_buffer_size,
                setup.max_request_len,
                setup.root_screen_count,
                setup.format_count,
                fmtEnum(setup.image_byte_order),
                setup.bitmap_format_bit_order,
                setup.bitmap_format_scanline_unit,
                setup.bitmap_format_scanline_pad,
                setup.min_keycode,
                setup.max_keycode,
            },
        );
    }
};

pub const Depth = enum {
    /// mono (just black/white)
    @"1",
    /// 16-color (early CGA/EGA era)
    @"4",
    /// 256-color (indexed/palette-based color)
    @"8",
    /// 32,768 colors (5 bits per channel)
    @"15",
    /// 65,536 colors (typically 5-6-5 RGB)
    @"16",
    /// 16.7 million colors (8 bits per RGB channel)
    @"24",
    /// same as 24-bit but with an 8-bit alpha or just padding
    @"32",

    pub fn init(b: u8) ?Depth {
        return switch (b) {
            1 => .@"1",
            4 => .@"4",
            8 => .@"8",
            15 => .@"15",
            16 => .@"16",
            24 => .@"24",
            32 => .@"32",
            else => null,
        };
    }

    pub fn byte(depth: Depth) u8 {
        return switch (depth) {
            .@"1" => 1,
            .@"4" => 4,
            .@"8" => 8,
            .@"15" => 15,
            .@"16" => 16,
            .@"24" => 24,
            .@"32" => 32,
        };
    }

    pub fn rgbFrom24(depth: Depth, color: u24) u32 {
        return switch (depth) {
            .@"1" => rgb1From24(color),
            .@"4" => rgb4From24(color),
            .@"8" => rgb8From24(color),
            .@"15" => rgb15From24(color),
            .@"16" => rgb16From24(color),
            .@"24" => color,
            .@"32" => rgb32From24(color),
        };
    }
};

pub fn rgb1From24(color: u24) u32 {
    const r: u32 = (color >> 16) & 0xff;
    const g: u32 = (color >> 8) & 0xff;
    const b: u32 = color & 0xff;
    // Use luminosity formula to determine if pixel should be white or black
    // Weights: 0.299 R + 0.587 G + 0.114 B
    // Using integer math: (299*R + 587*G + 114*B) / 1000
    const luminosity = (299 * r + 587 * g + 114 * b) / 1000;
    // Threshold at middle gray (128)
    return if (luminosity >= 128) 1 else 0;
}
pub fn rgb4From24(color: u24) u32 {
    const r: u32 = (color >> 16) & 0xff;
    const g: u32 = (color >> 8) & 0xff;
    const b: u32 = color & 0xff;
    // Reduce each component from 8-bit to 1-bit (threshold at 128)
    const r1: u32 = if (r >= 128) 1 else 0;
    const g1: u32 = if (g >= 128) 1 else 0;
    const b1: u32 = if (b >= 128) 1 else 0;
    // 4-bit color is typically: bit 3 = intensity, bit 2 = R, bit 1 = G, bit 0 = B
    // Calculate intensity as whether at least 2 components are bright
    const intensity: u32 = if (r1 + g1 + b1 >= 2) 1 else 0;
    return (intensity << 3) | (r1 << 2) | (g1 << 1) | b1;
}
pub fn rgb8From24(color: u24) u32 {
    const r: u32 = (color >> 16) & 0xff;
    const g: u32 = (color >> 8) & 0xff;
    const b: u32 = color & 0xff;
    // 8-bit color typically uses 3-3-2 encoding (3 bits red, 3 bits green, 2 bits blue)
    // Scale down: 8 bits -> 3 bits (divide by 32), 8 bits -> 2 bits (divide by 64)
    const r3: u32 = r >> 5; // Top 3 bits
    const g3: u32 = g >> 5; // Top 3 bits
    const b2: u32 = b >> 6; // Top 2 bits
    return (r3 << 5) | (g3 << 2) | b2;
}
pub fn rgb15From24(color: u24) u32 {
    const r: u32 = (color >> 16) & 0xff;
    const g: u32 = (color >> 8) & 0xff;
    const b: u32 = color & 0xff;
    const r5: u32 = r >> 3;
    const g5: u32 = g >> 3;
    const b5: u32 = b >> 3;
    return (r5 << 10) | (g5 << 5) | b5;
}
pub fn rgb16From24(color: u24) u16 {
    const r: u8 = @truncate(color >> 16);
    const g: u8 = @truncate(color >> 8);
    const b: u8 = @truncate(color);
    const r5: u5 = @intCast(r >> 3);
    const g6: u6 = @intCast(g >> 2);
    const b5: u5 = @intCast(b >> 3);
    return (@as(u16, r5) << 11) | (@as(u16, g6) << 5) | b5;
}
pub fn rgb32From24(color: u24) u32 {
    // Add an opaque alpha component (0xAARRGGBB)
    const alpha = 0xff;
    // Shift the alpha component all the way up to the top
    // 0x000000ff -> 0xff000000
    const alpha_shifted: u32 = alpha << 24;
    // Combine the color and alpha component
    return alpha_shifted | color;
}

// asserts that the first byte in the source's reader is the value 1
pub fn readSetupSuccess(reader: *std.Io.Reader) error{ ReadFailed, EndOfStream, Protocol }!Setup {
    std.debug.assert(reader.seek < reader.end);
    std.debug.assert(reader.buffer[reader.seek] == 1);
    var setup: Setup = undefined;
    try reader.readSliceAll(std.mem.asBytes(&setup));
    if (setup.version_major != 11) {
        log.err("expected major version 11 but got {}", .{setup.version_major});
        return error.Protocol;
    }
    return setup;
}

pub const Source = struct {
    reader: *std.Io.Reader,
    state: State,

    const State = union(enum) {
        kind,
        second: ServerMsgKind,
        reply: ReplyState,
        err,
    };
    const ReplyState = struct {
        word_count: u33,
        taken: u35,
        msg: union(enum) {
            none,
            reply: struct {
                flexible: u8,
                sequence: u16,
            },
            generic_event: struct {
                ext_opcode_base: u8,
                sequence: u16,
                type: u16,
            },
        },
        pub fn total(self: *const ReplyState) u35 {
            return @as(u35, self.word_count) * 4;
        }
        pub fn remaining(self: *const ReplyState) u35 {
            return self.total() - self.taken;
        }
    };

    pub fn initFinishSetup(reader: *std.Io.Reader, setup: *const Setup) Source {
        return .{
            .reader = reader,
            .state = .{
                .reply = .{
                    .word_count = setup.word_count,
                    .taken = @sizeOf(Setup) - 8,
                    .msg = .none,
                },
            },
        };
    }
    pub fn initAfterSetup(reader: *std.Io.Reader) Source {
        return .{ .reader = reader, .state = .kind };
    }

    /// Call to handle a read error. On graceful disconnect does nothing, otherwise,
    /// returns an error. Graceful exit requires either EndOfStream or ConnectionResetByPeer
    /// with the source state being `.kind` (at the start of a message).
    pub fn onReadError(
        source: *const Source,
        read_err: error{ ReadFailed, EndOfStream, Protocol },
        stream_err: ?std.Io.net.Stream.Reader.Error,
    ) (error{ EndOfStream, Protocol } || std.Io.net.Stream.Reader.Error)!void {
        switch (read_err) {
            error.ReadFailed => switch (stream_err.?) {
                error.ConnectionResetByPeer => |e| {
                    if (source.state != .kind) {
                        log.err("ConnectionReset with source state {t}", .{source.state});
                        return e;
                    }
                    log.info("ConnectionReset", .{});
                },
                else => |e| return e,
            },
            error.EndOfStream => |e| {
                if (source.state != .kind) {
                    log.err("EndOfStream with source state {t}", .{source.state});
                    return e;
                }
                log.info("EndOfStream", .{});
            },
            error.Protocol => {
                log.err("received unexpected data from x11 server", .{});
                return error.Protocol;
            },
        }
    }

    /// Read the first byte (message kind) of a new message.
    pub fn readKind(source: *Source) error{ ReadFailed, EndOfStream }!ServerMsgKind {
        std.debug.assert(source.state == .kind);
        const byte = try source.reader.takeByte();
        const kind: ServerMsgKind = .fromU7(@truncate(byte));
        source.state = .{ .second = kind };
        return kind;
    }

    /// Returns a formatter that will read the next message (or the rest of the current) and write
    /// it to the writer being printed to. If you are formatting into something that
    /// might be skipped, such as std.log, you can call discardRemainig() to ensure
    /// the message is completely read.
    pub fn readFmt(source: *Source, read_error_ref: *?ReadError) ReadFmt {
        std.debug.assert(read_error_ref.* == null);
        return .{ .source = source, .read_error_ref = read_error_ref };
    }
    pub const ReadFmt = struct {
        source: *Source,
        read_error_ref: *?ReadError,
        pub fn format(self: ReadFmt, writer: *std.Io.Writer) error{WriteFailed}!void {
            readFormat(self.source, writer) catch |err| switch (err) {
                error.WriteFailed => return error.WriteFailed,
                error.ReadFailed, error.EndOfStream, error.Protocol => |e| {
                    self.read_error_ref.* = e;
                    return error.WriteFailed;
                },
            };
        }
    };

    pub fn readFmtDropError(source: *Source) ReadFmtDropError {
        return .{ .source = source };
    }
    pub const ReadFmtDropError = struct {
        source: *Source,
        pub fn format(self: ReadFmtDropError, writer: *std.Io.Writer) error{WriteFailed}!void {
            readFormat(self.source, writer) catch return error.WriteFailed;
        }
    };

    /// discards the rest of the current message if we are currently reading one
    pub fn discardRemaining(source: *Source) error{ ReadFailed, EndOfStream, Protocol }!void {
        switch (source.state) {
            .kind => return,
            .second => |kind| {
                switch (kind) {
                    .Reply => {
                        _ = try source.read2(.Reply);
                        try source.discardRemaining();
                    },
                    .GenericEvent => {
                        _ = try source.read2(.GenericEvent);
                        try source.discardRemaining();
                    },
                    else => {
                        const size: usize = switch (kind) {
                            inline else => |_, tag| @sizeOf(@field(servermsg, @tagName(tag))),
                        };
                        try source.reader.discardAll(size - 1);
                    },
                }
                source.state = .kind;
            },
            .reply => |*reply_state| {
                const remaining = reply_state.remaining();
                std.debug.assert(remaining > 0);
                try source.reader.discardAll(remaining);
                source.state = .kind;
            },
            .err => return,
        }
    }

    /// Always call this after calling readKind.  It reads the next part of the given message type which
    /// will be the final read call for all non-reply messages.
    pub fn read2(source: *Source, comptime category: ServerMsgCategory) error{ ReadFailed, EndOfStream, Protocol }!@field(servermsg, @tagName(category)) {
        const kind = switch (source.state) {
            .kind, .reply, .err => unreachable,
            .second => |k| k,
        };
        std.debug.assert(@as(ServerMsgCategory, kind) == category);
        var result: @field(servermsg, @tagName(category)) = undefined;
        result.kind = switch (@typeInfo(@TypeOf(result.kind))) {
            .@"enum" => @fromBackingInt(@intCast(kind.toByte())),
            .int => kind.toByte(),
            else => @compileError("unhandled type " ++ @typeName(@TypeOf(result.kind))),
        };
        try source.reader.readSliceAll(std.mem.asBytes(&result)[1..]);
        source.state = switch (category) {
            .Reply => .{ .reply = .{
                .msg = .{ .reply = .{ .flexible = result.flexible, .sequence = result.sequence } },
                .word_count = @as(u33, result.word_count) + 6,
                .taken = 0,
            } },
            .GenericEvent => .{ .reply = .{
                .msg = .{ .generic_event = .{
                    .ext_opcode_base = result.ext_opcode_base,
                    .sequence = result.sequence,
                    .type = result.type,
                } },
                .word_count = @as(u33, result.word_count) + 5,
                .taken = 0,
            } },
            else => .kind,
        };
        return result;
    }

    pub fn fmtReplyData(source: *Source, n: usize, used_ref: *bool) FmtReplyData {
        std.debug.assert(used_ref.* == false);
        const reply_state: *ReplyState = switch (source.state) {
            .kind, .second, .err => unreachable,
            .reply => |*state| state,
        };
        const total = reply_state.total();
        std.debug.assert(reply_state.taken + n <= total);
        return .{ .source = source, .n = n, .used_ref = used_ref };
    }
    const FmtReplyData = struct {
        source: *Source,
        n: usize,
        // used to make sure the formatter isn't called multiple times and the
        // caller can use it to know if it was called at all
        used_ref: *bool,

        pub fn discardUnused(self: FmtReplyData) !void {
            if (self.used_ref.*) return;
            self.used_ref.* = true;
            self.source.replyDiscard(self.n);
        }
        pub fn format(self: FmtReplyData, writer: *std.Io.Writer) error{WriteFailed}!void {
            if (self.used_ref.*) unreachable;
            self.used_ref.* = true;
            self.source.streamReply(writer, self.n) catch |err| switch (err) {
                error.ReadFailed => return error.WriteFailed,
                error.EndOfStream => return error.WriteFailed,
                else => |e| return e,
            };
        }
    };

    /// Reads the reply to the request with the given sequence, or an event that arrived
    /// before it. For an event only its kind has been read, the caller must read the
    /// rest of it (i.e. read2 or discardRemaining) before calling this again.
    pub fn readSynchronousReplyOrEvent(
        source: *Source,
        sequence: u16,
    ) error{ ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!ReplyOrEvent {
        switch (try source.readKind()) {
            .Reply => {
                const reply = try source.read2(.Reply);
                if (reply.sequence != sequence) {
                    var maybe_read_error: ?ReadError = null;
                    log.err("expected sequence {} but got {f}", .{ sequence, source.readFmt(&maybe_read_error) });
                    if (maybe_read_error) |e| return e;
                    return error.UnexpectedMessage;
                }
                return .{ .reply = reply };
            },
            .Error => {
                var maybe_read_error: ?ReadError = null;
                log.err("expected Reply but got {f}", .{source.readFmt(&maybe_read_error)});
                if (maybe_read_error) |e| return e;
                return error.UnexpectedMessage;
            },
            else => |kind| return .{ .event = kind },
        }
    }
    pub const ReplyOrEvent = union(enum) {
        reply: servermsg.Reply,
        event: ServerMsgKind,
    };

    /// Handles an event returned by readSynchronousReplyOrEvent that wasn't expected.
    /// MappingNotify is skipped since it's delivered to all clients regardless of event
    /// masks, any other event is logged and fails with error.UnexpectedMessage.
    pub fn rejectEvent(
        source: *Source,
        kind: ServerMsgKind,
    ) error{ ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!void {
        switch (kind) {
            .MappingNotify => {
                log.debug("skipping MappingNotify during synchronous read", .{});
                try source.discardRemaining();
            },
            else => {
                var maybe_read_error: ?ReadError = null;
                log.err("expected Reply but got {f}", .{source.readFmt(&maybe_read_error)});
                if (maybe_read_error) |e| return e;
                return error.UnexpectedMessage;
            },
        }
    }

    /// Reads the reply to the request with the given sequence when no events are
    /// expected, see readSynchronousReplyOrEvent and rejectEvent.
    pub fn readSynchronousReply1(
        source: *Source,
        sequence: u16,
    ) error{ ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!servermsg.Reply {
        while (true) switch (try source.readSynchronousReplyOrEvent(sequence)) {
            .reply => |reply| return reply,
            .event => |kind| try source.rejectEvent(kind),
        };
    }

    pub fn read3Full(
        source: *Source,
        comptime read3_kind: Read3Full,
    ) error{ ReadFailed, EndOfStream }!read3_kind.Type() {
        var result: read3_kind.Type() = undefined;
        try source.readReply(std.mem.asBytes(&result));
        return result;
    }
    pub fn read3Header(
        source: *Source,
        comptime read3_kind: Read3Header,
    ) error{ ReadFailed, EndOfStream }!read3_kind.Type() {
        var result: read3_kind.Type() = undefined;
        try source.readReply(std.mem.asBytes(&result));
        return result;
    }

    /// A convenience function to read a synchronous reply when no events are expected,
    /// see readSynchronousReply1.
    pub fn readSynchronousReplyFull(
        source: *Source,
        sequence: u16,
        comptime read3_kind: Read3Full,
    ) error{ ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!WithFlexible(read3_kind.Type()) {
        return source.readReplyFull(try source.readSynchronousReply1(sequence), read3_kind);
    }

    /// A convenience function to read a synchronous reply header when no events are
    /// expected, see readSynchronousReply1.
    pub fn readSynchronousReplyHeader(
        source: *Source,
        sequence: u16,
        comptime read3_kind: Read3Header,
    ) error{ ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!WithFlexible(read3_kind.Type()) {
        return source.readReplyHeader(try source.readSynchronousReply1(sequence), read3_kind);
    }

    /// Reads the rest of a reply returned by readSynchronousReplyOrEvent.
    pub fn readReplyFull(
        source: *Source,
        reply: servermsg.Reply,
        comptime read3_kind: Read3Full,
    ) error{ ReadFailed, EndOfStream, Protocol }!WithFlexible(read3_kind.Type()) {
        try source.requireReplyExact(@sizeOf(read3_kind.Type()));
        return .{ try source.read3Full(read3_kind), reply.flexible };
    }

    /// Reads the header of a reply returned by readSynchronousReplyOrEvent.
    pub fn readReplyHeader(
        source: *Source,
        reply: servermsg.Reply,
        comptime read3_kind: Read3Header,
    ) error{ ReadFailed, EndOfStream, Protocol }!WithFlexible(read3_kind.Type()) {
        try source.requireReplyAtLeast(@sizeOf(read3_kind.Type()));
        return .{ try source.read3Header(read3_kind), reply.flexible };
    }

    /// Call to verify that the reply has at least this much data remaining
    pub fn requireReplyAtLeast(source: *Source, required: u35) error{Protocol}!void {
        const remaining = source.replyRemainingSize();
        if (required > remaining) {
            log.err("reply is truncated, {} bytes required but only have {}", .{ required, remaining });
            return error.Protocol;
        }
    }
    /// Call to verify that the reply has exactly this much data remaining
    pub fn requireReplyExact(source: *Source, expected: u35) error{Protocol}!void {
        const remaining = source.replyRemainingSize();
        if (remaining != expected) {
            log.err("expected reply to have {} bytes remaining but has {}", .{ expected, remaining });
            return error.Protocol;
        }
    }

    /// Get the remaining number of bytes belonging to the current reply.
    /// It's allowed to call this function even if the entire reply was just read.
    pub fn replyRemainingSize(source: *Source) u35 {
        const reply_state: *ReplyState = switch (source.state) {
            .kind => return 0, // allowed
            .second => unreachable,
            .err => unreachable,
            .reply => |*state| state,
        };
        const remaining = reply_state.remaining();
        std.debug.assert(remaining > 0);
        return remaining;
    }

    /// Discard n bytes belonging to the current reply.
    /// It's allowed to call this function with an n of 0 if the entire reply has been read.
    pub fn replyDiscard(source: *Source, n: usize) error{ ReadFailed, EndOfStream }!void {
        const reply_state: *ReplyState = switch (source.state) {
            .kind => {
                std.debug.assert(n == 0);
                return;
            },
            .second, .err => unreachable,
            .reply => |*state| state,
        };
        const total = reply_state.total();
        std.debug.assert(reply_state.taken + n <= total);
        try source.reader.discardAll(n);
        reply_state.taken += @intCast(n);
        if (reply_state.taken == total) {
            source.state = .kind;
        }
    }

    /// After reading the reply kind/header, call this method to read reply data into a slice.
    pub fn readReply(source: *Source, buffer: []u8) error{ ReadFailed, EndOfStream }!void {
        const reply_state: *ReplyState = switch (source.state) {
            .kind, .second, .err => unreachable,
            .reply => |*state| state,
        };
        const total = reply_state.total();
        std.debug.assert(reply_state.taken + buffer.len <= total);
        try source.reader.readSliceAll(buffer);
        reply_state.taken += @intCast(buffer.len);
        if (reply_state.taken == total) {
            source.state = .kind;
        }
    }

    /// After reading the reply kind/header, call this method to call `take` on the underlying
    /// reader. Like Reader, `n` must be <= the size of the reader buffer.
    pub fn takeReply(source: *Source, n: u35) error{ ReadFailed, EndOfStream }![]u8 {
        const reply_state: *ReplyState = switch (source.state) {
            .kind, .second, .err => unreachable,
            .reply => |*state| state,
        };
        const total = reply_state.total();
        std.debug.assert(reply_state.taken + n <= total);
        const data = try source.reader.take(n);
        reply_state.taken += @intCast(data.len);
        if (reply_state.taken == total) {
            source.state = .kind;
        }
        return data;
    }
    pub fn takeReplyInt(source: *Source, comptime Int: type) error{ ReadFailed, EndOfStream }!Int {
        const reply_state: *ReplyState = switch (source.state) {
            .kind, .second, .err => unreachable,
            .reply => |*state| state,
        };
        const total = reply_state.total();
        std.debug.assert(reply_state.taken + @sizeOf(Int) <= total);
        const int = try source.reader.takeInt(Int, native_endian);
        reply_state.taken += @sizeOf(Int);
        if (reply_state.taken == total) {
            source.state = .kind;
        }
        return int;
    }
    pub fn streamReply(source: *Source, writer: *std.Io.Writer, n: usize) error{ ReadFailed, EndOfStream, WriteFailed }!void {
        const reply_state: *ReplyState = switch (source.state) {
            .kind, .second, .err => unreachable,
            .reply => |*state| state,
        };
        const total = reply_state.total();
        std.debug.assert(reply_state.taken + n <= total);
        try source.reader.streamExact(writer, n);
        reply_state.taken += @intCast(n);
        if (reply_state.taken == total) {
            source.state = .kind;
        }
    }
};

pub fn WithFlexible(comptime T: type) type {
    return struct { T, u8 };
}

pub const ReadError = error{ ReadFailed, EndOfStream, Protocol };

fn readFormat(source: *Source, writer: *std.Io.Writer) (error{WriteFailed} || ReadError)!void {
    // code currently assumes buffer has non-zero capacity
    std.debug.assert(source.reader.buffer.len > 0);
    const msg_kind: ServerMsgKind = switch (source.state) {
        .kind => try source.readKind(),
        .second => |kind| kind,
        .reply => .Reply,
        .err => {
            try writer.print("error reading from server", .{});
            return;
        },
        // .err => |err| {
        //     switch (err) {
        //         .bad_setup_status => |status| try writer.print("bad setup status {}", .{status}),
        //         .auth_not_implemented => try writer.print("setup auth not implemented", .{}),
        //         .unsupported_protocol_version => |ver| try writer.print("unsupported proto version {}", .{ver}),
        //     }
        //     return;
        // },
    };
    try writer.print("{s}({})", .{ @tagName(msg_kind), msg_kind.toByte() });
    switch (msg_kind) {
        .Error => { // 0
            const err = try source.read2(.Error);
            try writer.print(" {f}", .{err});
        },
        .Reply, .GenericEvent => {
            switch (source.state) {
                .kind => unreachable,
                .second => |kind| switch (kind) {
                    .Reply => _ = try source.read2(.Reply),
                    .GenericEvent => _ = try source.read2(.GenericEvent),
                    else => unreachable,
                },
                .reply => {},
                .err => unreachable,
            }
            const reply = &source.state.reply;
            switch (reply.msg) {
                .none => {},
                .reply => |msg| try writer.print(
                    " sequence={} flex={}",
                    .{ msg.sequence, msg.flexible },
                ),
                .generic_event => |msg| try writer.print(
                    " sequence={} ext-opcode-base={} event-type={}",
                    .{ msg.sequence, msg.ext_opcode_base, msg.type },
                ),
            }
            const total = reply.total();
            try writer.print(" with {} bytes: ", .{total});
            var remaining = reply.remaining();
            if (remaining < total) {
                try writer.print("[{} bytes truncated]...", .{total - remaining});
            }
            while (remaining > 0) {
                // note: we asserted above that reader buffer has non-zero capacity
                const take_len = @min(source.reader.buffer.len, remaining);
                const next = try source.takeReply(take_len);
                try writer.print("{x}", .{next});
                remaining -= @intCast(take_len);
            }
        },
        inline else => |_, tag| {
            const msg = try source.read2(tag);
            try writer.print("{}", .{msg});
        },
    }
}

comptime {
    std.debug.assert(@sizeOf(CommonEvent) == 32);
}
// A common view of many of the x11 events, cast multiple kinds
// of events to this in order to handle them with common code
pub const CommonEvent = extern struct {
    kind: enum(u8) { ButtonPress = @backingInt(ServerMsgKind.ButtonPress) },
    flexible: u8,
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
    something: u8,
    unused: u8,
};

pub const FocusDetail = enum(u8) {
    ancestor = 0,
    virtual = 1,
    inferior = 2,
    nonlinear = 3,
    nonlinear_virtual = 4,
    pointer = 5,
    pointer_root = 6,
    none = 7,
};

pub const FocusMode = enum(u8) {
    normal = 0,
    grab = 1,
    ungrab = 2,
    while_grabbed = 3,
};

pub const servermsg = struct {
    comptime {
        std.debug.assert(@sizeOf(Error) == 32);
    }
    pub const Error = extern struct {
        kind: enum(u8) { Error = @backingInt(ServerMsgKind.Error) },
        code: NonExhaustive(ErrorCode),
        sequence: u16,
        generic: u32,
        minor_opcode: u16,
        major_opcode: NonExhaustive(Opcode),
        data: [21]u8,
        pub fn format(err: Error, writer: *std.Io.Writer) error{WriteFailed}!void {
            try writer.print("{f} sequence={} generic={} opcode={f}.{}", .{
                fmtEnum(err.code),
                err.sequence,
                err.generic,
                fmtEnum(err.major_opcode),
                err.minor_opcode,
            });
        }
    };
    comptime {
        std.debug.assert(@sizeOf(Reply) == 8);
    }
    pub const Reply = extern struct {
        kind: enum(u8) { Reply = @backingInt(ServerMsgKind.Reply) },
        flexible: u8 align(1),
        sequence: u16 align(1),
        word_count: u32 align(1),
        pub fn remainingSize(self: *const Reply) u35 {
            return (@as(u35, self.word_count) * 4) + 24;
        }
    };

    comptime {
        std.debug.assert(@sizeOf(KeyPress) == 32);
    }
    pub const KeyPress = extern struct {
        kind: enum(u8) { KeyPress = @backingInt(ServerMsgKind.KeyPress) },
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
        kind: enum(u8) { KeyPress = @backingInt(ServerMsgKind.KeyRelease) },
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
        kind: enum(u8) { ButtonPress = @backingInt(ServerMsgKind.ButtonPress) },
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
        pub fn asCommon(self: ButtonPress) CommonEvent {
            return @bitCast(self);
        }
    };
    comptime {
        std.debug.assert(@sizeOf(ButtonRelease) == 32);
    }
    pub const ButtonRelease = extern struct {
        kind: enum(u8) { ButtonRelease = @backingInt(ServerMsgKind.ButtonRelease) },
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
        kind: enum(u8) { MotionNotify = @backingInt(ServerMsgKind.MotionNotify) },
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
        pub fn asCommon(self: MotionNotify) CommonEvent {
            return @bitCast(self);
        }
    };
    comptime {
        std.debug.assert(@sizeOf(EnterNotify) == 32);
    }
    pub const EnterNotify = extern struct {
        kind: enum(u8) { EnterNotify = @backingInt(ServerMsgKind.EnterNotify) },
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
        kind: enum(u8) { LeaveNotify = @backingInt(ServerMsgKind.LeaveNotify) },
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
        kind: enum(u8) { FocusIn = @backingInt(ServerMsgKind.FocusIn) },
        detail: NonExhaustive(FocusDetail),
        sequence: u16,
        event: Window,
        mode: NonExhaustive(FocusMode),
        unused: [23]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(FocusOut) == 32);
    }
    pub const FocusOut = extern struct {
        kind: enum(u8) { FocusOut = @backingInt(ServerMsgKind.FocusOut) },
        detail: NonExhaustive(FocusDetail),
        sequence: u16,
        event: Window,
        mode: NonExhaustive(FocusMode),
        unused: [23]u8,
    };

    comptime {
        std.debug.assert(@sizeOf(KeymapNotify) == 32);
    }
    pub const KeymapNotify = extern struct {
        kind: enum(u8) { KeymapNotify = @backingInt(ServerMsgKind.KeymapNotify) },
        keys: [31]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(Expose) == 32);
    }
    pub const Expose = extern struct {
        kind: enum(u8) { Expose = @backingInt(ServerMsgKind.Expose) },
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
        kind: enum(u8) { GraphicsExposure = @backingInt(ServerMsgKind.GraphicsExposure) },
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
        kind: enum(u8) { NoExposure = @backingInt(ServerMsgKind.NoExposure) },
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
        kind: enum(u8) { VisibilityNotify = @backingInt(ServerMsgKind.VisibilityNotify) },
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
        kind: enum(u8) { CreateNotify = @backingInt(ServerMsgKind.CreateNotify) },
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
        kind: enum(u8) { DestroyNotify = @backingInt(ServerMsgKind.DestroyNotify) },
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
        kind: enum(u8) { UnmapNotify = @backingInt(ServerMsgKind.UnmapNotify) },
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
        kind: enum(u8) { MapNotify = @backingInt(ServerMsgKind.MapNotify) },
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
        kind: enum(u8) { MapRequest = @backingInt(ServerMsgKind.MapRequest) },
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
        kind: enum(u8) { ReparentNotify = @backingInt(ServerMsgKind.ReparentNotify) },
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
        kind: enum(u8) { ConfigureNotify = @backingInt(ServerMsgKind.ConfigureNotify) },
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
        kind: enum(u8) { ConfigureRequest = @backingInt(ServerMsgKind.ConfigureRequest) },
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
        kind: enum(u8) { GravityNotify = @backingInt(ServerMsgKind.GravityNotify) },
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
        kind: enum(u8) { ResizeRequest = @backingInt(ServerMsgKind.ResizeRequest) },
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
        kind: enum(u8) { CirculateNotify = @backingInt(ServerMsgKind.CirculateNotify) },
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
        kind: enum(u8) { CirculateRequest = @backingInt(ServerMsgKind.CirculateRequest) },
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
        kind: enum(u8) { PropertyNotify = @backingInt(ServerMsgKind.PropertyNotify) },
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
        kind: enum(u8) { SelectionClear = @backingInt(ServerMsgKind.SelectionClear) },
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
        kind: enum(u8) { SelectionRequest = @backingInt(ServerMsgKind.SelectionRequest) },
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
        kind: enum(u8) { SelectionNotify = @backingInt(ServerMsgKind.SelectionNotify) },
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
        kind: enum(u8) { ColormapNotify = @backingInt(ServerMsgKind.ColormapNotify) },
        unused: u8,
        sequence: u16,
        window: Window,
        colormap: Colormap,
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
        kind: enum(u8) { ClientMessage = @backingInt(ServerMsgKind.ClientMessage) },
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
        kind: enum(u8) { MappingNotify = @backingInt(ServerMsgKind.MappingNotify) },
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
        std.debug.assert(@sizeOf(GenericEvent) == 12);
    }
    pub const GenericEvent = extern struct {
        kind: enum(u8) { GenericEvent = @backingInt(ServerMsgKind.GenericEvent) },
        /// The extension's opcode base value
        ext_opcode_base: u8 align(1),
        sequence: u16 align(1),
        word_count: u32 align(1),
        type: u16,
        unused: u16,

        pub fn isPresentCompleteNotify(event: *const GenericEvent, opcode_base: u8) bool {
            return event.ext_opcode_base == opcode_base and
                event.type == @backingInt(present.EventType.complete_notify);
        }
        pub fn isPresentIdleNotify(event: *const GenericEvent, opcode_base: u8) bool {
            return event.ext_opcode_base == opcode_base and
                event.type == @backingInt(present.EventType.idle_notify);
        }
    };

    comptime {
        std.debug.assert(@sizeOf(UnknownCoreEvent) == 32);
    }
    pub const UnknownCoreEvent = extern struct {
        kind: u8,
        opcode: u8,
        sequence: u16,
        reserved: [28]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(ExtensionEvent) == 32);
    }
    pub const ExtensionEvent = extern struct {
        kind: u8,
        opcode: u8,
        sequence: u16,
        reserved: [28]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(ExtensionError) == 32);
    }
    pub const ExtensionError = extern struct {
        kind: u8,
        error_type: u8,
        sequence: u16,
        details: [28]u8,
    };
};

pub const GrabResult = enum(u8) {
    success = 0,
    already_grabbed = 1,
    invalid_time = 2,
    not_viewable = 3,
    frozen = 4,
    pub fn fromFlexible(flexible: u8) NonExhaustive(GrabResult) {
        return @fromBackingInt(@intCast(flexible));
    }
};

pub const stage3 = struct {
    // QueryTree 15
    comptime {
        std.debug.assert(@sizeOf(QueryTree) == 24);
    }
    pub const QueryTree = extern struct {
        root: Window,
        parent: Window,
        window_count: u16,
        unused: [14]u8,
        // folowwed by LISTofWINDOW
    };
    // InternAtom 16
    comptime {
        std.debug.assert(@sizeOf(InternAtom) == 24);
    }
    pub const InternAtom = extern struct {
        atom: Atom,
        unused: [20]u8,
    };
    // GetProperty 20
    comptime {
        std.debug.assert(@sizeOf(GetProperty) == 24);
    }
    pub const GetProperty = extern struct {
        type: Atom,
        bytes_after: u32,
        // format 0 (should be)
        // format 8 (size in bytes)
        value_size_in_format_units: u32,
        unused: [12]u8,
        // followed by LISTofBYTE and pad
    };
    // GrabPointer 26
    comptime {
        std.debug.assert(@sizeOf(GrabPointer) == 24);
    }
    pub const GrabPointer = [24]u8;
    // QueryFont 47
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
    // QueryTextExtents 48
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
    // ListFonts 49
    comptime {
        std.debug.assert(@sizeOf(ListFonts) == 24);
    }
    pub const ListFonts = extern struct {
        count: u16,
        unused: [22]u8,
    };
    // GetImage 73
    comptime {
        std.debug.assert(@sizeOf(GetImage) == 24);
    }
    pub const GetImage = extern struct {
        visual: Visual,
        unused: [20]u8,
    };
    // QueryExtension 98
    comptime {
        std.debug.assert(@sizeOf(QueryExtension) == 24);
    }
    pub const QueryExtension = extern struct {
        present: NonExhaustive(enum(u8) {
            no = 0,
            yes = 1,
        }),
        opcode_base: u8,
        event_base: u8,
        error_base: u8,
        unused: [20]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(tst_GetVersion) == 24);
    }
    pub const tst_GetVersion = extern struct {
        minor: u16,
        unused: [22]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(render_QueryVersion) == 24);
    }
    pub const render_QueryVersion = extern struct {
        major: u32,
        minor: u32,
        reserved: [15]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(render_QueryPictFormats) == 24);
    }
    pub const render_QueryPictFormats = extern struct {
        num_formats: u32,
        num_screens: u32,
        num_depths: u32,
        num_visuals: u32,
        num_subpixel: u32, // new in version 0.6
        unused: u32,
    };
    comptime {
        std.debug.assert(@sizeOf(shape_QueryVersion) == 24);
    }
    pub const shape_QueryVersion = extern struct {
        major: u16,
        minor: u16,
        unused: [20]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(composite_QueryVersion) == 24);
    }
    pub const composite_QueryVersion = extern struct {
        major: u32,
        minor: u32,
        unused_pad: [16]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(composite_GetOverlayWindow) == 24);
    }
    pub const composite_GetOverlayWindow = extern struct {
        overlay_window_id: u32,
        unused_pad: [20]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(fixes_QueryVersion) == 24);
    }
    pub const fixes_QueryVersion = extern struct {
        major: u32,
        minor: u32,
        unused: [16]u8,
    };
    comptime {
        std.debug.assert(@sizeOf(present_CompleteNotify) == 28);
    }
    pub const present_CompleteNotify = extern struct {
        event_id: u32,
        window: Window,
        serial: u32,
        /// The time the presentation occurred, in microseconds,
        /// from an unspecified epoch.
        unadjusted_system_time: u64 align(4),
        /// The vblank count at which the presentation occurred.
        media_stream_counter: u64 align(4),
    };
    comptime {
        std.debug.assert(@sizeOf(present_IdleNotify) == 20);
    }
    pub const present_IdleNotify = extern struct {
        event_id: u32,
        window: Window,
        serial: u32,
        pixmap: Pixmap,
        idle_fence: u32,
    };
};

pub const Read3Header = enum {
    QueryTree, // 15
    GetProperty, // 20
    QueryFont, // 47
    ListFonts, // 50
    GetImage, // 73

    render_QueryPictFormats,
    pub fn Type(self: Read3Header) type {
        return switch (self) {
            inline else => |tag| @field(stage3, @tagName(tag)),
        };
    }
};

const Read3Full = enum {
    GrabPointer,
    InternAtom,
    QueryTextExtents,
    QueryExtension,

    tst_GetVersion,
    render_QueryVersion,
    shape_QueryVersion,
    composite_QueryVersion,
    fixes_QueryVersion,
    present_CompleteNotify,
    present_IdleNotify,
    pub fn Type(self: Read3Full) type {
        return switch (self) {
            inline else => |tag| @field(stage3, @tagName(tag)),
        };
    }
};

pub const Extension = struct {
    opcode_base: u8,
    event_base: u8,
    error_base: u8,
    pub fn init(reply: stage3.QueryExtension) error{Protocol}!?Extension {
        switch (reply.present) {
            .no => return null,
            .yes => {},
            else => |v| {
                log.err("unexpected present value {}", .{v});
                return error.Protocol;
            },
        }
        return .{
            .opcode_base = reply.opcode_base,
            .event_base = reply.event_base,
            .error_base = reply.error_base,
        };
    }
};

pub fn charsetName(set: Charset) ?[]const u8 {
    return std.enums.tagName(Charset, set);
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
        pub fn format(self: Self, writer: *std.Io.Writer) error{WriteFailed}!void {
            if (@typeInfo(T).@"enum".mode == .exhaustive) {
                try writer.print("{s}", .{@tagName(self.value)});
            } else {
                @setEvalBranchQuota(@typeInfo(T).@"enum".field_names.len);
                if (std.enums.tagName(T, self.value)) |name| {
                    try writer.print("{s}", .{name});
                } else {
                    try writer.print("?({d})", .{@backingInt(self.value)});
                }
            }
        }
    };
}

pub const KeycodeRange = struct {
    min: u8,
    max: u8,
    pub fn init(min: u8, max: u8) error{Protocol}!KeycodeRange {
        if (min < 8) {
            log.err("minimum keycode {} is too small (must be >= 8)", .{min});
            return error.Protocol;
        }
        if (min > max) {
            log.err("minimum keycode {} cannot be > maximum keycode {}", .{ min, max });
            return error.Protocol;
        }
        return .{ .min = min, .max = max };
    }
    pub fn count(range: KeycodeRange) u8 {
        std.debug.assert(range.min >= 8);
        std.debug.assert(range.min <= range.max);
        return range.max - range.min + 1;
    }
};
pub fn synchronousGetKeyboardMapping(
    sink: *RequestSink,
    source: *Source,
    keycode_range: KeycodeRange,
) !KeyboardMappingIterator {
    const keycode_count = keycode_range.count();
    try sink.GetKeyboardMapping(keycode_range.min, keycode_count);
    try sink.writer.flush();
    const reply = try source.readSynchronousReply1(sink.sequence);
    try source.replyDiscard(24);
    {
        const expected_size = @as(u35, keycode_count) * @as(u35, reply.flexible) * 4;
        const remaining_size = source.replyRemainingSize();
        if (remaining_size != expected_size) {
            log.err("expected keyboard mapping reply to be {} bytes but got {}", .{ expected_size, remaining_size });
            return error.UnexpectedMessage;
        }
    }
    return .{
        .syms_per_keycode = reply.flexible,
        .syms_buffer = undefined,
    };
}
pub const KeyboardMappingIterator = struct {
    syms_per_keycode: u8,
    syms_buffer: [std.math.maxInt(u8)]charset.Combined,
    pub fn readSyms(self: *KeyboardMappingIterator, source: *Source) ![]charset.Combined {
        for (0..self.syms_per_keycode) |index| {
            const keysym_u32 = try source.takeReplyInt(u32);
            self.syms_buffer[index] = @fromBackingInt(@intCast(@as(u16, @truncate(keysym_u32))));
        }
        return self.syms_buffer[0..self.syms_per_keycode];
    }
};

pub const CoordinateMode = enum(u8) { origin = 0, previous = 1 };
pub const FillShape = enum(u8) { complex = 0, non_convex = 1, convex = 2 };

const poly_line_header_size: u18 =
    2 // opcode and coordinate-mode
    + 2 // request length
    + 4 // drawable id
    + 4 // gc id
;
const fill_poly_header_size: u18 =
    2 // opcode
    + 2 // request length
    + 4 // drawable id
    + 4 // gc id
    + 4 // coorindate-mode and shape
;
const point_size = 4; // points are 4 bytes (two i16's)

/// Sends a sequence of Poly* messages (i.e. PolyLine) where
/// the caller can provide one point at a time.  If the maximum
/// number of points per message is reached, it will end and start
/// a new message for you.
///
/// Caller must guarantee that the sink writer buffer is at least min_buffer.
/// (big enough to hold the header and at least two points).
pub const PolyPointSink = struct {
    kind: Kind,
    coordinate_mode: CoordinateMode,
    drawable: Drawable,
    gc: GraphicsContext,
    state: union(enum) {
        initial,
        header_written: struct {
            start_offset: usize,
        },
    } = .initial,

    pub const Kind = union(enum) {
        line, // PolyLine
        fill: FillShape, // FillPoly
    };

    // buffer must fit at least the header and two points
    pub fn minBuffer(kind: Kind) usize {
        return switch (kind) {
            .line => poly_line_header_size + 2 * point_size,
            .fill => fill_poly_header_size + 2 * point_size,
        };
    }

    // updates the write buffer with the actual length of the message
    pub fn endSetMsgSize(point_sink: *PolyPointSink, writer: *std.Io.Writer) void {
        point_sink.setMsgSize(writer);
        point_sink.* = undefined;
    }
    fn setMsgSize(point_sink: PolyPointSink, writer: *std.Io.Writer) void {
        const state = switch (point_sink.state) {
            .initial => return,
            .header_written => |*s| s,
        };
        std.debug.assert(writer.end >= state.start_offset + poly_line_header_size);
        const msg_len = writer.end - state.start_offset;
        std.debug.assert(msg_len & 3 == 0);
        std.mem.writeInt(u16, writer.buffer[state.start_offset + 2 ..][0..2], @intCast(msg_len >> 2), native_endian);
    }
    pub fn write(point_sink: *PolyPointSink, msg_sink: *RequestSink, p: XY(i16)) error{WriteFailed}!void {
        std.debug.assert(msg_sink.writer.buffer.len >= minBuffer(point_sink.kind));
        var write_header = false;
        var maybe_previous_point: ?XY(i16) = null;
        switch (point_sink.state) {
            .initial => {
                write_header = true;
            },
            .header_written => |*state| {
                const available = msg_sink.writer.buffer.len - msg_sink.writer.end;
                if (available < point_size or (msg_sink.writer.end + 2 - state.start_offset >= std.math.maxInt(u18))) {
                    maybe_previous_point = .{
                        .x = std.mem.readInt(i16, msg_sink.writer.buffer[msg_sink.writer.end - 4 ..][0..2], native_endian),
                        .y = std.mem.readInt(i16, msg_sink.writer.buffer[msg_sink.writer.end - 2 ..][0..2], native_endian),
                    };
                    point_sink.setMsgSize(msg_sink.writer);
                    point_sink.state = .initial;
                    write_header = true;
                }
            },
        }

        if (write_header) {
            std.debug.assert(point_sink.state == .initial);
            const available = msg_sink.writer.buffer.len - msg_sink.writer.end;
            if (available < minBuffer(point_sink.kind)) {
                try msg_sink.writer.flush();
            }
            const start_offset = msg_sink.writer.end;
            writeAllNoFlush(msg_sink.writer, &[_]u8{
                @backingInt(switch (point_sink.kind) {
                    .line => Opcode.poly_line,
                    .fill => Opcode.fill_poly,
                }),
                switch (point_sink.kind) {
                    .line => @backingInt(point_sink.coordinate_mode),
                    .fill => 0,
                },
            });
            // the message length (filled in at the end)
            writeIntNoFlush(msg_sink.writer, u16, undefined);
            writeIntNoFlush(msg_sink.writer, u32, @backingInt(point_sink.drawable));
            writeIntNoFlush(msg_sink.writer, u32, @backingInt(point_sink.gc));
            switch (point_sink.kind) {
                .line => {},
                .fill => |fill_shape| writeAllNoFlush(msg_sink.writer, &[_]u8{
                    @backingInt(fill_shape),
                    @backingInt(point_sink.coordinate_mode),
                    0,
                    0,
                }),
            }
            point_sink.state = .{ .header_written = .{
                .start_offset = start_offset,
            } };
            msg_sink.sequence +%= 1;
        }
        if (maybe_previous_point) |p2| {
            writeIntNoFlush(msg_sink.writer, i16, p2.x);
            writeIntNoFlush(msg_sink.writer, i16, p2.y);
        }
        writeIntNoFlush(msg_sink.writer, i16, p.x);
        writeIntNoFlush(msg_sink.writer, i16, p.y);
    }
};

/// Tracks state needed for double-buffered vsync.
pub const Presenter = struct {
    opcode_base: u8,

    depth: Depth,
    window_id: Window,
    event_id: u32,
    pixmaps: [2]Pixmap,

    serial: u32 = 0,
    back_buf: u1 = 0,
    pixmap_idle: [2]bool = .{ true, true },
    presenting: bool = false,

    /// Call once at startup after CreateWindow, before MapWindow.
    pub fn init(p: *const Presenter, sink: *RequestSink, width: u16, height: u16) error{WriteFailed}!void {
        try present.selectInput(sink, p.opcode_base, p.event_id, p.window_id, .{
            .complete_notify = true,
            .idle_notify = true,
        });
        for (p.pixmaps) |pixmap| {
            try sink.CreatePixmap(pixmap, p.window_id.drawable(), .{
                .depth = p.depth,
                .width = width,
                .height = height,
            });
        }
    }

    /// Call if the window size changes (from ConfigureNotify) to free/recreate
    /// the pixmaps with the new size. Caller is responsible for only calling them
    /// when the size has actually changed.
    pub fn resize(p: *Presenter, sink: *RequestSink, width: u16, height: u16) error{WriteFailed}!void {
        for (p.pixmaps) |pixmap| {
            try sink.FreePixmap(pixmap);
            try sink.CreatePixmap(pixmap, p.window_id.drawable(), .{
                .depth = p.depth,
                .width = width,
                .height = height,
            });
        }
        p.reset();
    }

    /// Reset to idle state, e.g. after unmapping a window. Stale
    /// CompleteNotify/IdleNotify events that arrive after reset are harmless
    /// (idempotent state transitions).
    pub fn reset(p: *Presenter) void {
        p.pixmap_idle = .{ true, true };
        p.presenting = false;
    }

    /// Returns the back pixmap to render into if it's safe to do so, else null.
    pub fn beginFrame(p: *const Presenter) ?Pixmap {
        if (p.presenting) return null;
        if (!p.pixmap_idle[p.back_buf]) return null;
        return p.pixmaps[p.back_buf];
    }
    pub fn endFrame(p: *Presenter, sink: *RequestSink) error{WriteFailed}!void {
        p.serial +%= 1;
        try present.presentPixmap(
            sink,
            p.opcode_base,
            p.window_id,
            p.pixmaps[p.back_buf],
            p.serial,
            0,
            0,
            0,
        );
        p.pixmap_idle[p.back_buf] = false;
        p.back_buf +%= 1;
        p.presenting = true;
    }

    pub fn handleCompleteNotify(p: *Presenter, complete: stage3.present_CompleteNotify) error{Protocol}!bool {
        if (complete.event_id != p.event_id) return false;
        if (complete.window != p.window_id) {
            log.err(
                "present CompleteNotify: event_id matches but window doesn't: expected {f} got {f}",
                .{ p.window_id, complete.window },
            );
            return error.Protocol;
        }
        if (complete.serial == p.serial) {
            p.presenting = false;
        }
        return true;
    }

    pub fn handleIdleNotify(p: *Presenter, idle: stage3.present_IdleNotify) error{Protocol}!bool {
        if (idle.event_id != p.event_id) return false;
        if (idle.window != p.window_id) {
            log.err(
                "present IdleNotify: event_id matches but window doesn't: expected {f} got {f}",
                .{ p.window_id, idle.window },
            );
            return error.Protocol;
        }
        if (idle.pixmap == p.pixmaps[0]) {
            p.pixmap_idle[0] = true;
        } else if (idle.pixmap == p.pixmaps[1]) {
            p.pixmap_idle[1] = true;
        } else {
            log.err("present IdleNotify: unexpected pixmap {f}", .{idle.pixmap});
            return error.Protocol;
        }
        return true;
    }
};
