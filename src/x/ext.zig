//! This file contains apis that I'm unsure whether to include as they are.
pub const MappedFile = @import("ext/MappedFile.zig");
pub const DoubleBuffer = @import("ext/DoubleBuffer.zig");
pub const ContiguousReadBuffer = @import("ext/ContiguousReadBuffer.zig");

const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

const AuthResult = union(enum) {
    failed: x11.AuthFailReason,
    success: x11.SetupReplyStart,
};
pub fn authenticate(
    writer: *x11.Writer,
    source: *x11.Source,
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
        break :blk switch (try connectSetupAuth(writer, source, auth_filename.str, &auth_filter2)) {
            .success => |reply| return .{ .success = reply },
            .fail => |err| break :blk err,
        };
    };

    // Try no authentication
    x11.log.info("trying no auth", .{});
    try x11.flushSetup(writer, .{
        .auth_name = .empty,
        .auth_data = .empty,
    });
    switch (try source.readSetup()) {
        .failed => |reason| {
            x11.log.info("no AUTH setup failed: {s}'", .{reason.slice()});
        },
        .success => |reply| return .{ .success = reply },
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

const AuthError = union(enum) {
    creds_failed: struct { attempted: u32, total: u32 },
    invalid_auth_file,
};

fn connectSetupAuth(
    writer: *x11.Writer,
    source: *x11.Source,
    auth_filename: []const u8,
    auth_filter: *const x11.AuthFilter,
) !union(enum) {
    success: x11.SetupReplyStart,
    fail: AuthError,
} {
    const test_bad_auth = false;
    if (test_bad_auth) {
        x11.log.debug("trying bad auth...", .{});
        try x11.flushSetup(writer, .{ .auth_name = .initComptime("wat"), .auth_data = .empty });
        switch (try source.readSetup()) {
            .failed => |reason| {
                x11.log.info("bad auth failed as expected: {s}", .{reason.slice()});
            },
            .success => @panic("this was supposed to fail"),
        }
    }

    const auth_mapped = try MappedFile.init(auth_filename, .{});
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
        try x11.flushSetup(writer, .{ .auth_name = name_x, .auth_data = data_x });
        switch (try source.readSetup()) {
            .failed => |reason| {
                x11.log.err("connect setup failed: {s}'", .{reason.slice()});
                return error.ConnectSetupFailed;
            },
            .success => |reply| return .{ .success = reply },
        }
    }

    return .{ .fail = .{ .creds_failed = .{
        .attempted = attempted_cred_count,
        .total = total_cred_count,
    } } };
}

pub fn readSetupDynamic(
    source: *x11.Source,
    setup: *const x11.SetupReplyStart,
    opt: struct {
        log_vendor: bool = true,
        log_visuals: bool = false,
    },
) (x11.ProtocolError || x11.Reader.Error)!?x11.ScreenHeader {
    try source.requireReplyAtLeast(setup.required());

    {
        const old_remaining = source.replyRemainingSize();
        if (opt.log_vendor) {
            if (zig_atleast_15) {
                var used = false;
                x11.log.info("vendor '{f}'", .{source.fmtReplyData(setup.vendor_len, &used)});
            } else {
                var buf: [100]u8 = undefined;
                const read_len = @min(buf.len, setup.vendor_len);
                const vendor = buf[0..read_len];
                try source.readReply(vendor);
                if (setup.vendor_len > buf.len) {
                    x11.log.info("vendor '{s}' (truncated to {} from {})", .{ vendor, buf.len, setup.vendor_len });
                } else {
                    x11.log.info("vendor '{s}'", .{vendor});
                }
            }
        }
        const vendor_written = old_remaining - source.replyRemainingSize();
        const vendor_remaining = setup.vendor_len - vendor_written;
        try source.replyDiscard(vendor_remaining + x11.pad4Len(@truncate(setup.vendor_len)));
    }

    for (0..setup.format_count) |index| {
        var format: x11.Format = undefined;
        try source.readReply(std.mem.asBytes(&format));
        std.log.info(
            "format {} depth={} bpp={} scanlinepad={}",
            .{ index, format.depth, format.bits_per_pixel, format.scanline_pad },
        );
    }

    var first_screen_header: ?x11.ScreenHeader = null;

    for (0..setup.root_screen_count) |screen_index| {
        try source.requireReplyAtLeast(@sizeOf(x11.ScreenHeader));
        var screen_header: x11.ScreenHeader = undefined;
        try source.readReply(std.mem.asBytes(&screen_header));
        std.log.info("screen {} | {}", .{ screen_index, screen_header });
        if (first_screen_header == null) {
            first_screen_header = screen_header;
        }
        try source.requireReplyAtLeast(@as(u35, screen_header.allowed_depth_count) * @sizeOf(x11.ScreenDepth));
        for (0..screen_header.allowed_depth_count) |depth_index| {
            var depth: x11.ScreenDepth = undefined;
            try source.readReply(std.mem.asBytes(&depth));
            try source.requireReplyAtLeast(@as(u35, depth.visual_type_count) * @sizeOf(x11.VisualType));
            std.log.info("screen {} | depth {} | {}", .{ screen_index, depth_index, depth });
            for (0..depth.visual_type_count) |visual_index| {
                var visual: x11.VisualType = undefined;
                try source.readReply(std.mem.asBytes(&visual));
                if (opt.log_visuals) {
                    std.log.info("screen {} | depth {} | visual {} | {}\n", .{ screen_index, depth_index, visual_index, visual });
                }
            }
        }
    }

    const remaining = source.replyRemainingSize();
    if (remaining != 0) {
        x11.log.err("setup reply had an extra {} bytes", .{remaining});
        return error.X11Protocol;
    }
    return first_screen_header;
}

/// Sends and receives QueryExtension synchronously.  Synchronous methods must
/// being called at the start of the connection before any other events would be received.
pub fn synchronousQueryExtension(
    source: *x11.Source,
    sink: *x11.RequestSink,
    name: x11.Slice(u16, [*]const u8),
) !?x11.Extension {
    try sink.QueryExtension(name);
    try sink.writer.flush();
    const extension, _ = try source.readSynchronousReplyFull(sink.sequence, .QueryExtension);
    const result: ?x11.Extension = try .init(extension);
    std.log.info("extension '{s}': {?}", .{ name.nativeSlice(), result });
    return result;
}

const std = @import("std");
const x11 = @import("../x.zig");
