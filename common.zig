const std = @import("std");
const x = @import("x.zig");
const common = @This();

pub const SocketReader = std.io.Reader(std.posix.socket_t, std.posix.RecvFromError, readSocket);

/// Sanity check that we're not running into data integrity (corruption) issues caused
/// by overflowing and wrapping around to the front ofq the buffer.
fn checkMessageLengthFitsInBuffer(message_length: usize, buffer_limit: usize) !void {
    if(message_length > buffer_limit) {
        std.debug.panic("Reply is bigger than our buffer (data corruption will ensue) {} > {}. In order to fix, increase the buffer size.", .{
            message_length,
            buffer_limit,
        });
    }
}

pub fn send(sock: std.posix.socket_t, data: []const u8) !void {
    const sent = try x.writeSock(sock, data, 0);
    if (sent != data.len) {
        std.log.err("send {} only sent {}\n", .{data.len, sent});
        return error.DidNotSendAllData;
    }
}

pub const ConnectResult = struct {
    sock: std.posix.socket_t,
    setup: x.ConnectSetup,
    pub fn reader(self: ConnectResult) SocketReader {
        return .{ .context = self.sock };
    }
    pub fn send(self: ConnectResult, data: []const u8) !void {
        try common.send(self.sock, data);
    }
};

pub fn connectSetupMaxAuth(
    sock: std.posix.socket_t,
    comptime max_auth_len: usize,
    auth_name: x.Slice(u16, [*]const u8),
    auth_data: x.Slice(u16, [*]const u8),
) !?u16 {
    var buf: [x.connect_setup.auth_offset + max_auth_len]u8 = undefined;
    const len = x.connect_setup.getLen(auth_name.len, auth_data.len);
    if (len > max_auth_len)
        return error.AuthTooBig;
    return connectSetup(sock, buf[0 .. len], auth_name, auth_data);
}

pub fn connectSetup(
    sock: std.posix.socket_t,
    msg: []u8,
    auth_name: x.Slice(u16, [*]const u8),
    auth_data: x.Slice(u16, [*]const u8),
) !?u16 {
    std.debug.assert(msg.len == x.connect_setup.getLen(auth_name.len, auth_data.len));

    x.connect_setup.serialize(msg.ptr, 11, 0, auth_name, auth_data);
    try send(sock, msg);

    const reader = SocketReader { .context = sock };
    const connect_setup_header = try x.readConnectSetupHeader(reader, .{});
    switch (connect_setup_header.status) {
        .failed => {
            std.log.err("connect setup failed, version={}.{}, reason='{s}'", .{
                connect_setup_header.proto_major_ver,
                connect_setup_header.proto_minor_ver,
                connect_setup_header.readFailReason(reader),
            });
            return error.ConnectSetupFailed;
        },
        .authenticate => {
            std.log.err("AUTHENTICATE! not implemented", .{});
            return error.NotImplemetned;
        },
        .success => {
            // TODO: check version?
            std.log.debug("SUCCESS! version {}.{}", .{connect_setup_header.proto_major_ver, connect_setup_header.proto_minor_ver});
            return connect_setup_header.getReplyLen();
        },
        else => |status| {
            std.log.err("Error: expected 0, 1 or 2 as first byte of connect setup reply, but got {}", .{status});
            return error.MalformedXReply;
        }
    }
}

fn connectSetupAuth(
    display_num: ?u32,
    sock: std.posix.socket_t,
    auth_filename: []const u8,
) !?u16 {
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: test bad auth
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    //if (try connectSetupMaxAuth(sock, 1000, .{ .ptr = "wat", .len = 3}, .{ .ptr = undefined, .len = 0})) |_|
    //    @panic("todo");

    const auth_mapped = try x.MappedFile.init(auth_filename, .{});
    defer auth_mapped.unmap();

    var auth_filter = x.AuthFilter{
        .addr = .{ .family = .wild, .data = &[0]u8{ } },
        .display_num = display_num,
    };

    var addr_buf: [x.max_sock_filter_addr]u8 = undefined;
    if (auth_filter.applySocket(sock, &addr_buf)) {
        std.log.debug("applied address filter {}", .{auth_filter.addr});
    } else |err| {
        // not a huge deal, we'll just try all auth methods
        std.log.warn("failed to apply socket to auth filter with {s}", .{@errorName(err)});
    }

    var auth_it = x.AuthIterator{ .mem = auth_mapped.mem };
    while (auth_it.next() catch {
        std.log.warn("auth file '{s}' is invalid", .{auth_filename});
        return null;
    }) |entry| {
        if (auth_filter.isFiltered(auth_mapped.mem, entry)) |reason| {
            std.log.debug("ignoring auth because {s} does not match: {}", .{@tagName(reason), entry.fmt(auth_mapped.mem)});
            continue;
        }
        const name = entry.name(auth_mapped.mem);
        const data = entry.data(auth_mapped.mem);
        const name_x = x.Slice(u16, [*]const u8){
            .ptr = name.ptr,
            .len = @intCast(name.len),
        };
        const data_x = x.Slice(u16, [*]const u8){
            .ptr = data.ptr,
            .len = @intCast(data.len),
        };
        std.log.debug("trying auth {}", .{entry.fmt(auth_mapped.mem)});
        if (try connectSetupMaxAuth(sock, 1000, name_x, data_x)) |reply_len|
            return reply_len;
    }

    return null;
}

pub fn connect(allocator: std.mem.Allocator) !ConnectResult {
    const display = x.getDisplay();
    const parsed_display = x.parseDisplay(display) catch |err| {
        std.log.err("invalid display '{s}': {s}", .{display, @errorName(err)});
        std.process.exit(0xff);
    };

    const sock = x.connect(display, parsed_display) catch |err| {
        std.log.err("failed to connect to display '{s}': {s}", .{display, @errorName(err)});
        std.process.exit(0xff);
    };
    errdefer x.disconnect(sock);

    const setup_reply_len: u16 = blk: {
        if (try x.getAuthFilename(allocator)) |auth_filename| {
            defer auth_filename.deinit(allocator);
            if (try connectSetupAuth(parsed_display.display_num, sock, auth_filename.str)) |reply_len|
                break :blk reply_len;
        }

        // Try no authentication
        std.log.debug("trying no auth", .{});
        var msg_buf: [x.connect_setup.getLen(0, 0)]u8 = undefined;
        if (try connectSetup(
            sock,
            &msg_buf,
            .{ .ptr = undefined, .len = 0 },
            .{ .ptr = undefined, .len = 0 },
        )) |reply_len| {
            break :blk reply_len;
        }

        std.log.err("the X server rejected our connect setup message", .{});
        std.process.exit(0xff);
    };

    const connect_setup = x.ConnectSetup {
        .buf = try allocator.allocWithOptions(u8, setup_reply_len, 4, null),
    };
    std.log.debug("connect setup reply is {} bytes", .{connect_setup.buf.len});
    const reader = SocketReader { .context = sock };
    try x.readFull(reader, connect_setup.buf);

    return ConnectResult{ .sock = sock, .setup = connect_setup };
}

pub fn asReply(comptime T: type, msg_bytes: []align(4) u8) !*T {
    const generic_msg: *x.ServerMsg.Generic = @ptrCast(msg_bytes.ptr);
    if (generic_msg.kind != .reply) {
        std.log.err("expected reply but got {}", .{generic_msg});
        return error.UnexpectedReply;
    }
    return @alignCast(@ptrCast(generic_msg));
}

fn readSocket(sock: std.posix.socket_t, buffer: []u8) !usize {
    return x.readSock(sock, buffer, 0);
}

/// X server extension info.
pub const ExtensionInfo = struct {
    extension_name: []const u8,
    /// The extension opcode is used to identify which X extension a given request is
    /// intended for (used as the major opcode). This essentially namespaces any extension
    /// requests. The extension differentiates its own requests by using a minor opcode.
    opcode: u8,
    /// Extension error codes are added on top of this base error code.
    base_error_code: u8,
};

pub const ExtensionVersion = struct {
    major_version: u16,
    minor_version: u16,
};

/// Determines whether the extension is available on the server.
pub fn getExtensionInfo(
    sock: std.posix.socket_t,
    buffer: *x.ContiguousReadBuffer,
    comptime extension_name: []const u8,
) !?ExtensionInfo {
    const reader = common.SocketReader{ .context = sock };
    const buffer_limit = buffer.half_len;

    {
        const ext_name = comptime x.Slice(u16, [*]const u8).initComptime(extension_name);
        var message_buffer: [x.query_extension.getLen(ext_name.len)]u8 = undefined;
        x.query_extension.serialize(&message_buffer, ext_name);
        try common.send(sock, &message_buffer);
    }
    const message_length = try x.readOneMsg(reader, @alignCast(buffer.nextReadBuffer()));
    try checkMessageLengthFitsInBuffer(message_length, buffer_limit);
    const optional_extension = blk: {
        switch (x.serverMsgTaggedUnion(@alignCast(buffer.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.ServerMsg.QueryExtension = @ptrCast(msg_reply);
                if (msg.present == 0) {
                    std.log.info("{s} extension: not present", .{extension_name});
                    break :blk null;
                }
                std.debug.assert(msg.present == 1);
                std.log.info("{s} extension: opcode={} base_error_code={}", .{
                    extension_name,
                    msg.major_opcode,
                    msg.first_error,
                });
                std.log.info("{s} extension: {}", .{ extension_name, msg });
                break :blk ExtensionInfo{
                    .extension_name = extension_name,
                    .opcode = msg.major_opcode,
                    .base_error_code = msg.first_error,
                };
            },
            else => |msg| {
                std.log.err("expected a reply for `x.query_extension` but got {}", .{msg});
                return error.ExpectedReplyButGotSomethingElse;
            },
        }
    };

    return optional_extension;
}
