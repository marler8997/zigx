//! This file contains apis that I'm unsure whether to include as they are.
const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

pub const ConnectError = error{
    GetDisplay,
    BadDisplay,
    ConnectFailed,
    AuthenticateFailed,
};
pub fn connect(read_buffer: []u8) ConnectError!x11.Authenticator.Success {
    const display = x11.getDisplay() catch |err| {
        x11.log.err("failed to get x11 display with {s}", .{@errorName(err)});
        return error.GetDisplay;
    };
    x11.log.info("DISPLAY {f}", .{display});
    const parsed_display = x11.parseDisplay(display) catch |err| {
        x11.log.err("invalid DISPLAY {f}: {s}", .{ display, @errorName(err) });
        return error.BadDisplay;
    };
    const host = x11.getHost(display, &parsed_display) catch |err| switch (err) {
        error.X11BadDisplay => {
            x11.log.err("DISPLAY {f} is not a valid host", .{display});
            return error.BadDisplay;
        },
    };
    const address, const initial_stream = x11.connect(&host) catch |err| {
        x11.log.err("connect to {f} failed with {s}", .{ host, @errorName(err) });
        return error.ConnectFailed;
    };
    errdefer x11.disconnect(initial_stream);
    if (zig_atleast_15)
        x11.log.info("connected to {f}", .{address})
    else
        x11.log.info("connected to {}", .{address});
    return x11.draft.authenticate(
        display,
        &parsed_display,
        &host,
        &address,
        initial_stream,
        read_buffer,
        .{},
    ) catch |err| return switch (err) {
        error.X11Authentication => error.AuthenticateFailed,
    };
}

pub fn authenticate(
    display: x11.Display,
    parsed_display: *const x11.ParsedDisplay,
    host: *const x11.Host,
    address: *const std.net.Address,
    stream: std.net.Stream,
    stream_read_buffer: []u8,
    opt: struct {
        order: x11.Authenticator.Order = .auth_first,
    },
) !x11.Authenticator.Success {
    var filename_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var authenticator: x11.Authenticator = .{
        .display = display,
        .parsed_display = parsed_display,
        .host = host,
        .address = address,
        .stream = stream,
        .stream_read_buffer = stream_read_buffer,
        .filename_buffer = &filename_buffer,
        .order = opt.order,
    };
    defer authenticator.deinit();
    while (true) switch (authenticator.next()) {
        .reply => |reply| switch (reply) {
            .success => |success| return success,
            .failed => |f| x11.log.err(
                "server (version {}.{}) reported failure '{s}'",
                .{ f.version_major, f.version_minor, f.reason() },
            ),
        },
        .done => |done| {
            switch (done.reason) {
                .reconnect_error => |err| {
                    x11.log.err(
                        "reconnect (to try a new auth) failed with {s} ({} attempts, {} auth entries skipped)",
                        .{ @errorName(err), done.attempt_count, done.skip_count },
                    );
                },
                .no_more_auth => {
                    x11.log.err(
                        "failed to connect ({} attempts, {} auth entries skipped)",
                        .{ done.attempt_count, done.skip_count },
                    );
                },
            }
            return error.X11Authentication;
        },
        .get_auth_filename_error => |e| {
            x11.log.err("get auth filename ({s}) failed with {s}", .{ e.kind.context(), @errorName(e.err) });
        },
        .open_auth_file_error => |e| {
            x11.log.err("open auth file '{s}' ({s}) failed with {s}", .{ e.filename, e.kind.context(), @errorName(e.err) });
        },
        .auth_file_opened => |f| {
            x11.log.info("opened auth file '{s}' ({s})", .{ f.filename, f.kind.context() });
        },
        .io_error => |e| switch (e) {
            .write_error => |err| {
                x11.log.err("write to server failed with {s}", .{@errorName(err)});
            },
            .read_error => |err| {
                x11.log.err("read from server failed with {s}", .{@errorName(err)});
            },
            .protocol => {
                x11.log.err("server sent unexpected data", .{});
            },
        },
    };
}

pub fn readSetupDynamic(
    source: *x11.Source,
    setup: *const x11.Setup,
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
        x11.log.info(
            "format {} depth={} bpp={} scanlinepad={}",
            .{ index, format.depth, format.bits_per_pixel, format.scanline_pad },
        );
    }

    var first_screen_header: ?x11.ScreenHeader = null;

    for (0..setup.root_screen_count) |screen_index| {
        try source.requireReplyAtLeast(@sizeOf(x11.ScreenHeader));
        var screen_header: x11.ScreenHeader = undefined;
        try source.readReply(std.mem.asBytes(&screen_header));
        x11.log.info("screen {} | {}", .{ screen_index, screen_header });
        if (first_screen_header == null) {
            first_screen_header = screen_header;
        }
        try source.requireReplyAtLeast(@as(u35, screen_header.allowed_depth_count) * @sizeOf(x11.ScreenDepth));
        for (0..screen_header.allowed_depth_count) |depth_index| {
            var depth: x11.ScreenDepth = undefined;
            try source.readReply(std.mem.asBytes(&depth));
            try source.requireReplyAtLeast(@as(u35, depth.visual_type_count) * @sizeOf(x11.VisualType));
            x11.log.info("screen {} | depth {} | {}", .{ screen_index, depth_index, depth });
            for (0..depth.visual_type_count) |visual_index| {
                var visual: x11.VisualType = undefined;
                try source.readReply(std.mem.asBytes(&visual));
                if (opt.log_visuals) {
                    x11.log.info("screen {} | depth {} | visual {} | {}\n", .{ screen_index, depth_index, visual_index, visual });
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
