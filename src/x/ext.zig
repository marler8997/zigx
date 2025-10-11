//! This file contains apis that I'm unsure whether to include as they are.

const std = @import("std");
const x11 = @import("../x.zig");
const ext = @This();

const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

/// Sanity check that we're not running into data integrity (corruption) issues caused
/// by overflowing and wrapping around to the front ofq the buffer.
fn checkMessageLengthFitsInBuffer(message_length: usize, buffer_limit: usize) !void {
    if (message_length > buffer_limit) {
        std.debug.panic("Reply is bigger than our buffer (data corruption will ensue) {} > {}. In order to fix, increase the buffer size.", .{
            message_length,
            buffer_limit,
        });
    }
}

pub const ConnectResult = struct {
    sock: std.posix.socket_t,
    setup: x11.ConnectSetup.Fixed,

    pub fn sendOne(self: *const ConnectResult, sequence: *u16, data: []const u8) !void {
        try ext.sendNoSequencing(self.sock, data);
        sequence.* +%= 1;
    }
    pub fn sendNoSequencing(self: *const ConnectResult, data: []const u8) !void {
        try ext.sendNoSequencing(self.sock, data);
    }
};

pub fn connectSetup(
    writer: *x11.Writer,
    reader: *x11.Reader,
    auth_name: x11.Slice(u16, [*]const u8),
    auth_data: x11.Slice(u16, [*]const u8),
) !?u16 {
    try x11.flushConnectSetup(writer, .{
        .auth_name = auth_name,
        .auth_data = auth_data,
    });
    try writer.flush();

    var connect_setup_header: x11.ConnectSetup.Header = undefined;
    try reader.readSliceAll(std.mem.asBytes(&connect_setup_header));
    switch (connect_setup_header.status) {
        .failed => {
            const reason = connect_setup_header.readFailReason(reader);
            x11.log.err("connect setup failed, version={}.{}, reason='{f}'", .{
                connect_setup_header.proto_major_ver,
                connect_setup_header.proto_minor_ver,
                reason,
            });
            return error.ConnectSetupFailed;
        },
        .authenticate => {
            x11.log.err("AUTHENTICATE! not implemented", .{});
            return error.NotImplemented;
        },
        .success => {
            // TODO: check version?
            x11.log.debug("SUCCESS! version {}.{}", .{
                connect_setup_header.proto_major_ver,
                connect_setup_header.proto_minor_ver,
            });
            const reply_len = connect_setup_header.getReplyLen();
            if (reply_len < @sizeOf(x11.ConnectSetup.Fixed)) {
                x11.log.err("reply len {} is too small", .{reply_len});
                return error.XMalformedReply;
            }
            return reply_len;
        },
        else => |status| {
            x11.log.err("Error: expected 0, 1 or 2 as first byte of connect setup reply, but got {}", .{status});
            return error.XMalformedXReply;
        },
    }
}

const AuthError = union(enum) {
    creds_failed: struct { attempted: u32, total: u32 },
    invalid_auth_file,
};

fn connectSetupAuth(
    writer: *x11.Writer,
    reader: *x11.Reader,
    auth_filename: []const u8,
    auth_filter: *const x11.AuthFilter,
    // display_num: x11.DisplayNum,
    // sock: std.posix.socket_t,
) !union(enum) {
    authenticated: u16,
    fail: AuthError,
} {
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: test bad auth
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    //if (try connectSetupMaxAuth(sock, 1000, .{ .ptr = "wat", .len = 3}, .{ .ptr = undefined, .len = 0})) |_|
    //    @panic("todo");

    const auth_mapped = try x11.MappedFile.init(auth_filename, .{});
    defer auth_mapped.unmap();

    var total_cred_count: u32 = 0;
    var attempted_cred_count: u32 = 0;

    var auth_it = x11.AuthIterator{ .mem = auth_mapped.mem };
    while (auth_it.next() catch {
        x11.log.warn("auth file '{s}' is invalid", .{auth_filename});
        return .{ .fail = .invalid_auth_file };
    }) |entry| {
        total_cred_count += 1;
        if (auth_filter.isFiltered(auth_mapped.mem, entry)) |reason| {
            x11.log.debug("ignoring auth because {s} does not match: {f}", .{ @tagName(reason), entry.fmt(auth_mapped.mem) });
            continue;
        }
        attempted_cred_count += 1;
        const name = entry.name(auth_mapped.mem);
        const data = entry.data(auth_mapped.mem);
        const name_x = x11.Slice(u16, [*]const u8){
            .ptr = name.ptr,
            .len = @intCast(name.len),
        };
        const data_x = x11.Slice(u16, [*]const u8){
            .ptr = data.ptr,
            .len = @intCast(data.len),
        };
        x11.log.debug("trying auth {f}", .{entry.fmt(auth_mapped.mem)});
        if (try connectSetup(writer, reader, name_x, data_x)) |reply_len|
            return .{ .authenticated = reply_len };
    }

    return .{ .fail = .{ .creds_failed = .{
        .attempted = attempted_cred_count,
        .total = total_cred_count,
    } } };
}

const AuthResult = union(enum) {
    failed: x11.AuthFailReason,
    success: u16,
};
pub fn authenticate(
    writer: *x11.Writer,
    reader: *x11.Reader,
    auth_filter: struct {
        display_num: x11.DisplayNum, // used to filter authentication entries
        socket: std.posix.socket_t, // used to filter authentication entries
    },
) !AuthResult {
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    const auth_error: AuthError = blk: {
        var fba: std.heap.FixedBufferAllocator = .init(&filename_buf);
        const auth_filename = try x11.getAuthFilename(fba.allocator()) orelse break :blk .{ .creds_failed = .{
            .total = 0,
            .attempted = 0,
        } };
        var auth_filter2 = x11.AuthFilter{
            .addr = .{ .family = .wild, .data = &[0]u8{} },
            .display_num = auth_filter.display_num,
        };
        var addr_buf: [x11.max_sock_filter_addr]u8 = undefined;
        if (auth_filter2.applySocket(auth_filter.socket, &addr_buf)) {
            x11.log.debug("applied address filter {f}", .{auth_filter2.addr});
        } else |err| {
            // not a huge deal, we'll just try all auth methods
            x11.log.warn("failed to apply socket to auth filter with {s}", .{@errorName(err)});
        }
        break :blk switch (try connectSetupAuth(writer, reader, auth_filename.str, &auth_filter2)) {
            .authenticated => |reply_len| return .{ .success = reply_len },
            .fail => |err| break :blk err,
        };
    };

    // Try no authentication
    x11.log.debug("trying no auth", .{});
    if (try connectSetup(writer, reader, .empty, .empty)) |reply_len| {
        return .{ .success = reply_len };
    }

    var result: AuthResult = .{ .failed = .{ .len = undefined, .buf = undefined } };
    result.failed.len = @intCast((switch (auth_error) {
        .invalid_auth_file => std.fmt.bufPrint(&result.failed.buf, "invalid auth file", .{}) catch unreachable,
        .creds_failed => |cred_counts| std.fmt.bufPrint(
            &result.failed.buf,
            "auth failed with {} out of {} credentials",
            .{ cred_counts.attempted, cred_counts.total },
        ) catch unreachable,
    }).len);
    return result;
}

pub fn readConnectSetupFixed(reader: *x11.Reader) x11.Reader.Error!x11.ConnectSetup.Fixed {
    var fixed: x11.ConnectSetup.Fixed = undefined;
    try reader.readSliceAll(std.mem.asBytes(&fixed));
    return fixed;
}

pub fn readConnectSetupDynamic(
    reader: *x11.Reader,
    reply_len: u16,
    fixed: *const x11.ConnectSetup.Fixed,
) (error{XMalformedReply} || x11.Reader.Error)!?x11.Screen {
    const vendor_pad_len = x11.pad4Len(@truncate(fixed.vendor_len));
    const required_reply_len1: u16 =
        @sizeOf(x11.ConnectSetup.Fixed) +%
        fixed.vendor_len + vendor_pad_len +%
        (@sizeOf(x11.Format) *% fixed.format_count) +%
        (@sizeOf(x11.Screen) *% fixed.root_screen_count);
    if (reply_len < required_reply_len1) {
        x11.log.err("connect setup reply len {} is less than required {}", .{ reply_len, required_reply_len1 });
        return error.XMalformedReply;
    }

    const max_take_len = reader.buffer.len;
    if (max_take_len == 0) @panic("unbuffered reader currently not supported");

    {
        var remaining = fixed.vendor_len;
        var suffix: []const u8 = "";
        while (remaining > 0) {
            const take_len = @min(max_take_len, remaining);
            const slice = try reader.take(take_len);
            x11.log.info("vendor '{s}'{s}", .{ slice, suffix });
            remaining -= take_len;
            suffix = " (continued)";
        }
    }
    try reader.discardAll(vendor_pad_len);

    for (0..fixed.format_count) |index| {
        var format: x11.Format = undefined;
        try reader.readSliceAll(std.mem.asBytes(&format));
        std.log.info(
            "format {} depth={} bpp={} scanlinepad={}",
            .{ index, format.depth, format.bits_per_pixel, format.scanline_pad },
        );
    }

    var first_screen: ?x11.Screen = null;

    var allowed_depth_total: u16 = 0;
    for (0..fixed.root_screen_count) |screen_index| {
        var screen_fixed: x11.Screen = undefined;
        try reader.readSliceAll(std.mem.asBytes(&screen_fixed));
        std.log.info("screen {} | {}", .{ screen_index, screen_fixed });
        if (first_screen == null) {
            first_screen = screen_fixed;
        }
        allowed_depth_total += screen_fixed.allowed_depth_count;
        for (0..screen_fixed.allowed_depth_count) |depth_index| {
            var depth: x11.ScreenDepth = undefined;
            try reader.readSliceAll(std.mem.asBytes(&depth));
            std.log.info("screen {} | depth {} | {}", .{ screen_index, depth_index, depth });
        }
    }

    const required_reply_len2: u16 = required_reply_len1 +% (allowed_depth_total *% @sizeOf(x11.ScreenDepth));
    if (reply_len < required_reply_len2) {
        x11.log.err("connect setup reply len {} is less than required {}", .{ reply_len, required_reply_len2 });
        return error.XMalformedReply;
    }

    const discard_len: u16 = reply_len - required_reply_len2;
    x11.log.info("discarding {} bytes of {}-byte connect setup response", .{ discard_len, reply_len });
    try reader.discardAll(discard_len);
    return first_screen;
}
