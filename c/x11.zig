const std = @import("std");
const c = @cImport({
    @cDefine("XLIB_ILLEGAL_ACCESS", "1");
    @cInclude("X11/Xlib.h");
});
const x11 = @import("x11");
const c_allocator = std.heap.c_allocator;

fn sendAll(sock: std.posix.socket_t, data: []const u8) !void {
    var total_sent: usize = 0;
    while (true) {
        const sent = try x11.writeSock(sock, data[total_sent..], 0);
        total_sent += sent;
        std.debug.assert(total_sent != 0);
        if (total_sent == data.len) return;
    }
}
pub const SocketReader = std.io.Reader(std.posix.socket_t, std.posix.RecvFromError, readSocket);
fn readSocket(sock: std.posix.socket_t, buffer: []u8) !usize {
    return x11.readSock(sock, buffer, 0);
}

export fn ZigXSetErrorHandler(handler: *const fn (*anyopaque, [*:0]const u8) callconv(.C) void, ctx: *anyopaque) void {
    _ = handler;
    _ = ctx;
    std.log.err("TODO: set error handler!", .{});
}
fn reportErrorRaw(comptime fmt: []const u8, args: anytype) void {
    // TODO: report to handler
    std.log.err(fmt, args);
}
fn reportError(comptime fmt: []const u8, args: anytype) error{Reported} {
    reportErrorRaw(fmt, args);
    return error.Reported;
}
fn generateErrorEvent(display: *Display) void {
    _ = display;
    @panic("TODO: generate an error event!");
}

const GC = struct {
    id: x11.GraphicsContext,
};

const Display = struct {
    public: c.Display,
    resource_id_base: u32,
    next_resource_id_offset: u32,
    gc_list: std.SinglyLinkedList(*GC),
    read_buf: []align(4) u8,
};

export fn XOpenDisplay(display_opt: ?[*:0]const u8) ?*c.Display {
    return openDisplay(display_opt) catch return null;
}
fn openDisplay(display_spec_opt: ?[*:0]const u8) error{ Reported, OutOfMemory }!*c.Display {
    // TODO: x11.getDisplay allocates on windows, maybe we cache it on windows?
    // TODO: should an empty string be handled like null as well?
    const display_spec = if (display_spec_opt) |d| std.mem.span(d) else x11.getDisplay();
    std.log.info("connecting to DISPLAY '{s}'", .{display_spec});

    const parsed_display = x11.parseDisplay(display_spec) catch |err|
        return reportError("invalid DISPLAY '{s}': {s}", .{ display_spec, @errorName(err) });

    const sock = x11.connect(display_spec, parsed_display) catch |err|
        return reportError("failed to connect to DISPLAY '{s}': {s}", .{ display_spec, @errorName(err) });
    errdefer x11.disconnect(sock);

    const setup_header = blk: {
        if (x11.getAuthFilename(c_allocator) catch |err|
            return reportError("failed to get auth filename with {s}", .{@errorName(err)})) |auth_filename|
        {
            defer auth_filename.deinit(c_allocator);
            if (try connectSetupAuth(parsed_display.display_num, sock, auth_filename.str)) |hdr|
                break :blk hdr;
        }

        var msg: [x11.connect_setup.getLen(0, 0)]u8 = undefined;
        x11.connect_setup.serialize(&msg, 11, 0, .{ .ptr = undefined, .len = 0 }, .{ .ptr = undefined, .len = 0 });
        sendAll(sock, &msg) catch |err|
            return reportError("send connect setup failed with {s}", .{@errorName(err)});

        const reader = SocketReader{ .context = sock };
        const connect_setup_header = x11.readConnectSetupHeader(reader, .{}) catch |err|
            return reportError("failed to read connect setup with {s}", .{@errorName(err)});
        switch (connect_setup_header.status) {
            .failed => {
                std.log.debug("no auth connect setup failed, version={}.{}, reason='{s}'", .{
                    connect_setup_header.proto_major_ver,
                    connect_setup_header.proto_minor_ver,
                    connect_setup_header.readFailReason(reader),
                });
            },
            .authenticate => {
                std.log.debug("no auth connect setup failed with AUTHENTICATE", .{});
            },
            .success => break :blk connect_setup_header,
            else => |status| return reportError(
                "expected 0, 1 or 2 as first byte of connect setup reply, but got {}",
                .{status},
            ),
        }
        return reportError("the X server rejected our connect setup message", .{});
    };

    const buf = try c_allocator.allocWithOptions(u8, setup_header.getReplyLen(), 4, null);
    defer c_allocator.free(buf);

    const connect_setup = x11.ConnectSetup{ .buf = buf };
    std.log.debug("connect setup reply is {} bytes", .{connect_setup.buf.len});
    const reader = SocketReader{ .context = sock };
    x11.readFull(reader, connect_setup.buf) catch |err|
        return reportError("failed to read connect setup with {s}", .{@errorName(err)});

    const fixed = connect_setup.fixed();
    inline for (@typeInfo(@TypeOf(fixed.*)).@"struct".fields) |field| {
        std.log.debug("{s}: {any}", .{ field.name, @field(fixed, field.name) });
    }
    //std.log.debug("vendor: {s}", .{try connect_setup.getVendorSlice(fixed.vendor_len)});
    const format_list_offset = x11.ConnectSetup.getFormatListOffset(fixed.vendor_len);
    const format_list_limit = x11.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
    std.log.debug("fmt list off={} limit={}", .{ format_list_offset, format_list_limit });
    //const formats = try connect_setup.getFormatList(format_list_offset, format_list_limit);
    //for (formats) |format, i| {
    //    std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{i, format.depth, format.bits_per_pixel, format.scanline_pad});
    //}

    const display = try c_allocator.create(Display);
    errdefer c_allocator.destroy(display);

    const setup_screens_ptr = connect_setup.getScreensPtr(format_list_limit);
    const screens = try c_allocator.alloc(c.Screen, fixed.root_screen_count);
    std.log.debug("screens allocated to 0x{x}", .{@intFromPtr(screens.ptr)});
    errdefer c_allocator.free(screens);
    for (screens, 0..) |*screen_dst, screen_index| {
        const screen_src = &setup_screens_ptr[screen_index];
        inline for (@typeInfo(@TypeOf(screen_src.*)).@"struct".fields) |field| {
            std.log.debug("SCREEN {}| {s}: {any}", .{ screen_index, field.name, @field(screen_src, field.name) });
        }
        std.log.debug("screen_ptr is 0x{x}", .{@intFromPtr(screen_dst)});
        screen_dst.* = .{
            .display = &display.public,
            .root = @intFromEnum(screen_src.root),
            .root_visual_num = @intFromEnum(screen_src.root_visual),
            .white_pixel = @intCast(screen_src.white_pixel),
            .black_pixel = @intCast(screen_src.black_pixel),
        };
    }

    const read_buf = try c_allocator.allocWithOptions(u8, 4096, 4, null);
    errdefer c_allocator.free(read_buf);

    display.* = .{
        .public = .{
            .fd = sock,
            .proto_major_version = setup_header.proto_major_ver,
            .proto_minor_version = setup_header.proto_minor_ver,
            .default_screen = 0,
            .nscreens = @intCast(fixed.root_screen_count),
            .screens = screens.ptr,
        },
        .resource_id_base = @intFromEnum(fixed.resource_id_base),
        .next_resource_id_offset = 0,
        .gc_list = .{},
        .read_buf = read_buf,
    };
    return &display.public;
}

fn connectSetupAuth(
    display_num: ?u32,
    sock: std.posix.socket_t,
    auth_filename: []const u8,
) error{ Reported, OutOfMemory }!?x11.ConnectSetup.Header {
    const auth_mapped = x11.MappedFile.init(auth_filename, .{}) catch |err|
        return reportError("failed to mmap auth file '{s}' with {s}", .{ auth_filename, @errorName(err) });
    defer auth_mapped.unmap();

    var auth_filter = x11.AuthFilter{
        .addr = .{ .family = .wild, .data = &[0]u8{} },
        .display_num = display_num,
    };

    var addr_buf: [x11.max_sock_filter_addr]u8 = undefined;
    auth_filter.applySocket(sock, &addr_buf) catch |err| {
        std.log.warn("failed to apply socket to auth filter with {s}", .{@errorName(err)});
    };

    var auth_it = x11.AuthIterator{ .mem = auth_mapped.mem };
    while (auth_it.next() catch {
        std.log.warn("auth file '{s}' is invalid", .{auth_filename});
        return null;
    }) |entry| {
        if (auth_filter.isFiltered(auth_mapped.mem, entry)) |reason| {
            std.log.debug("ignoring auth because {s} does not match: {}", .{ @tagName(reason), entry.fmt(auth_mapped.mem) });
            continue;
        }
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

        const msg_len = x11.connect_setup.getLen(name_x.len, data_x.len);
        const msg = try c_allocator.alloc(u8, msg_len);
        defer c_allocator.free(msg);
        x11.connect_setup.serialize(msg.ptr, 11, 0, name_x, data_x);
        sendAll(sock, msg) catch |err|
            return reportError("send connect setup failed with {s}", .{@errorName(err)});

        const reader = SocketReader{ .context = sock };
        const connect_setup_header = x11.readConnectSetupHeader(reader, .{}) catch |err|
            return reportError("failed to read connect setup with {s}", .{@errorName(err)});
        switch (connect_setup_header.status) {
            .failed => {
                std.log.debug("connect setup failed, version={}.{}, reason='{s}'", .{
                    connect_setup_header.proto_major_ver,
                    connect_setup_header.proto_minor_ver,
                    connect_setup_header.readFailReason(reader),
                });
                // try the next?
            },
            .authenticate => {
                std.log.debug("AUTHENTICATE with {} failed", .{entry.fmt(auth_mapped.mem)});
                // try the next auth
            },
            .success => {
                // TODO: check version?
                std.log.debug("SUCCESS! version {}.{}", .{ connect_setup_header.proto_major_ver, connect_setup_header.proto_minor_ver });
                return connect_setup_header;
            },
            else => |status| return reportError(
                "expected 0, 1 or 2 as first byte of connect setup reply, but got {}",
                .{status},
            ),
        }
    }

    return null;
}

export fn XCloseDisplay(display_opt: ?*c.Display) c_int {
    const display = display_opt orelse return 0;
    const display_full: *Display = @fieldParentPtr("public", display);

    {
        var it = display_full.gc_list.first;
        while (it) |gc| : (it = gc.next) {
            c_allocator.destroy(gc);
        }
    }

    c_allocator.free(display_full.read_buf);
    c_allocator.free(display.screens[0..@intCast(display.nscreens)]);
    //c_allocator.free(@ptrCast([*]u8, display.connect_setup)[0 .. display.connect_setup_len]);
    c_allocator.destroy(display);
    return 0;
}

export fn XCreateSimpleWindow(
    display: *c.Display,
    root_window: c.Window,
    x_pos: c_int,
    y: c_int,
    width: c_uint,
    height: c_uint,
    border_width: c_int,
    border: c_ulong,
    background: c_ulong,
) c.Window {
    _ = border;
    _ = background;

    const display_full: *Display = @fieldParentPtr("public", display);

    const new_window: x11.Window = .fromInt(display_full.resource_id_base + display_full.next_resource_id_offset);
    display_full.next_resource_id_offset += 1;

    var msg_buf: [x11.create_window.max_len]u8 = undefined;
    const len = x11.create_window.serialize(&msg_buf, .{
        .window_id = new_window,
        .parent_window_id = .fromInt(root_window),
        // TODO: set this correctly
        .depth = 0,
        .x = @intCast(x_pos),
        .y = @intCast(y),
        .width = @intCast(width),
        .height = @intCast(height),
        .border_width = @intCast(border_width),
        // TODO
        .class = .copy_from_parent,
        // .class = .input_output,
        .visual_id = .fromInt(display.screens[0].root_visual_num),
    }, .{});
    sendAll(display.fd, msg_buf[0..len]) catch |err| {
        reportErrorRaw("failed to send CreateWindow message with {s}", .{@errorName(err)});
        generateErrorEvent(display_full);
    };
    return @intFromEnum(new_window);
}

//export fn XSetStandardProperties

export fn XCreateGC(
    display: *c.Display,
    drawable: c.Drawable,
    value_mask: c_ulong,
    values: ?[*]c.XGCValues,
) c.GC {
    const display_full: *Display = @fieldParentPtr("public", display);

    const gc_id: x11.GraphicsContext = .fromInt(display_full.resource_id_base + display_full.next_resource_id_offset);
    display_full.next_resource_id_offset += 1;

    const gc = c_allocator.create(GC) catch @panic("Out of memory");
    gc.* = .{ .id = gc_id };

    if (value_mask != 0) @panic("todo: non-zero value_mask");
    if (values) |_| @panic("todo: non-zero values");

    var msg_buf: [x11.create_gc.max_len]u8 = undefined;
    const len = x11.create_gc.serialize(&msg_buf, .{
        .gc_id = gc_id,
        .drawable_id = .fromInt(drawable),
    }, .{
        //.foreground = screen.black_pixel,
    });
    sendAll(display.fd, msg_buf[0..len]) catch |err| {
        reportErrorRaw("failed to send CreateGC message with {s}", .{@errorName(err)});
        generateErrorEvent(display_full);
    };

    return @ptrCast(gc);
}

export fn XMapRaised(display: *c.Display, window: c.Window) c_int {
    const display_full: *Display = @fieldParentPtr("public", display);

    std.log.info("TODO: send ConfigureWindow stack-mode=Above", .{});
    var msg: [x11.map_window.len]u8 = undefined;
    x11.map_window.serialize(&msg, .fromInt(window));
    sendAll(display.fd, &msg) catch |err| {
        reportErrorRaw("failed to send MapWindow message with {s}", .{@errorName(err)});
        generateErrorEvent(display_full);
    };
    return 0;
}

fn handleReadError(err: anytype) noreturn {
    switch (err) {
        error.ConnectionResetByPeer,
        error.EndOfStream,
        error.ConnectionTimedOut,
        => {
            //@panic("TODO: report x connection closed and/or reset");
            // This seems to be similar to what libx11 does?
            std.io.getStdErr().writer().print("X connection broken\n", .{}) catch @panic("X connection broken");
            std.process.exit(1);
        },
        error.MessageTooBig => {
            @panic("TODO: how to handle MessageTooBig?");
        },
        error.NetworkSubsystemFailed => @panic("TODO: how to handle NetworkSubsystemFailed?"),
        error.SystemResources => @panic("TODO: how to handle SystemResources?"),
        error.WouldBlock => @panic("TODO: how to handle WouldBlock?"),
        error.ConnectionRefused,
        error.SocketNotBound,
        error.SocketNotConnected,
        error.Unexpected,
        => unreachable,
    }
}

export fn XNextEvent(display: *c.Display, event: *c.XEvent) c_int {
    const display_full: *Display = @fieldParentPtr("public", display);

    //var header_buf: [32]u8 align(4) = undefined;
    const len = x11.readOneMsg(SocketReader{ .context = display.fd }, display_full.read_buf) catch |err| handleReadError(err);

    if (len > display_full.read_buf.len) {
        std.log.err("TODO: realloc read_buf len to be bigger", .{});
        //c_allocator.realloc();
        x11.readOneMsgFinish(SocketReader{ .context = display.fd }, display_full.read_buf) catch |err| handleReadError(err);
        @panic("todo");
    }

    switch (x11.serverMsgTaggedUnion(display_full.read_buf.ptr)) {
        .expose => |e| {
            event.* = .{
                .xexpose = .{
                    .type = c.Expose,
                    .serial = e.sequence,
                    .send_event = @intFromBool((display_full.read_buf[0] & 0x80) != 0),
                    .display = display,
                    .window = @intFromEnum(e.window),
                    .x = e.x,
                    .y = e.y,
                    .width = e.width,
                    .height = e.height,
                    .count = e.count,
                },
            };
        },
        else => |m| std.debug.panic("todo: handle server msg {s}", .{@tagName(m)}),
    }
    return 0;
}

// ChangeWindowAttributes(window=w#0A000001, event-mask=KeyPress|ButtonPress|Exposure)
export fn XSelectInput(display: *c.Display, window: c.Window, event_mask: c_ulong) c_int {
    const display_full: *Display = @fieldParentPtr("public", display);

    var msg_buf: [x11.change_window_attributes.max_len]u8 = undefined;
    const len = x11.change_window_attributes.serialize(&msg_buf, .fromInt(window), .{
        .event_mask = @bitCast(@as(u32, @truncate(event_mask))),
    });
    sendAll(display.fd, msg_buf[0..len]) catch |err| {
        reportErrorRaw("failed to send ChangeWindowAttributes message with {s}", .{@errorName(err)});
        generateErrorEvent(display_full);
    };
    return 0;
}
