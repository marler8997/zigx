//! An example of using the "Double Buffer Extension" (DBE)
const std = @import("std");
const x11 = @import("x11");
const common = @import("common.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 400;
const window_height = 400;

const Key = enum {
    f, // faster
    s, // slower
    d, // toggle double buffering
};

const Ids = struct {
    base: x11.ResourceBase,
    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.base.add(1).graphicsContext();
    }
    pub fn backBuffer(self: Ids) x11.Drawable {
        return self.base.add(2).drawable();
    }
};

pub fn main() !u8 {
    try x11.wsaStartup();
    const conn = try common.connect(allocator);
    defer std.posix.shutdown(conn.sock, .both) catch {};

    var sequence: u16 = 0;

    var keycode_map = std.AutoHashMapUnmanaged(u8, Key){};
    {
        var sym_key_map = std.AutoHashMapUnmanaged(u32, Key){};
        defer sym_key_map.deinit(allocator);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.latin_f), Key.f);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.latin_F), Key.f);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.latin_s), Key.s);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.latin_S), Key.s);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.latin_d), Key.d);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.latin_D), Key.d);
        const keymap = try x11.keymap.request(allocator, conn.sock, &sequence, conn.setup.fixed());
        defer keymap.deinit(allocator);
        {
            var i: usize = 0;
            var sym_offset: usize = 0;
            while (i < keymap.keycode_count) : (i += 1) {
                const keycode: u8 = @intCast(conn.setup.fixed().min_keycode + i);
                var j: usize = 0;
                while (j < keymap.syms_per_code) : (j += 1) {
                    const sym = keymap.syms[sym_offset];
                    if (sym_key_map.get(sym)) |key| {
                        std.log.info("key {s} code is {}", .{ @tagName(key), keycode });
                        try keycode_map.put(allocator, keycode, key);
                    }
                    sym_offset += 1;
                }
            }
            std.debug.assert(sym_offset == keymap.syms.len);
        }
    }

    const screen = blk: {
        const fixed = conn.setup.fixed();
        inline for (@typeInfo(@TypeOf(fixed.*)).@"struct".fields) |field| {
            std.log.debug("{s}: {any}", .{ field.name, @field(fixed, field.name) });
        }
        std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
        const format_list_offset = x11.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = x11.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        std.log.debug("fmt list off={} limit={}", .{ format_list_offset, format_list_limit });
        const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
        for (formats, 0..) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{ i, format.depth, format.bits_per_pixel, format.scanline_pad });
        }
        const screen = conn.setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).@"struct".fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
        }
        break :blk screen;
    };

    const ids: Ids = .{ .base = conn.setup.fixed().resource_id_base };

    {
        var msg_buf: [x11.create_window.max_len]u8 = undefined;
        const len = x11.create_window.serialize(&msg_buf, .{
            .window_id = ids.window(),
            .parent_window_id = screen.root,
            .depth = 0, // we don't care, just inherit from the parent
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
            .bg_pixel = 0x332211,
            .event_mask = .{
                .key_press = 1,
                .key_release = 0,
                .button_press = 0,
                .button_release = 0,
                .enter_window = 1,
                .leave_window = 1,
                .pointer_motion = 1,
                .keymap_state = 1,
                .exposure = 1,
            },
        });
        try conn.sendOne(&sequence, msg_buf[0..len]);
    }

    {
        var msg_buf: [x11.create_gc.max_len]u8 = undefined;
        const len = x11.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.gc(),
            .drawable_id = ids.window().drawable(),
        }, .{
            .background = 0x332211,
            .foreground = 0xaabbff,
        });
        try conn.sendOne(&sequence, msg_buf[0..len]);
    }

    const double_buf = try x11.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.heap.pageSize()),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    // double_buf.deinit() (not necessary)
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    const maybe_dbe_ext = try common.getExtensionInfo(conn.sock, &sequence, &buf, x11.dbe.name.nativeSlice());
    var dbe: Dbe = .unsupported;
    if (maybe_dbe_ext) |ext| {
        try allocateBackBuffer(conn.sock, &sequence, ext.opcode, ids.window(), ids.backBuffer());
        dbe = .{ .enabled = .{ .opcode = ext.opcode, .back_buffer = ids.backBuffer() } };
    }

    {
        var msg: [x11.map_window.len]u8 = undefined;
        x11.map_window.serialize(&msg, ids.window());
        try conn.sendOne(&sequence, &msg);
    }

    var animate: Animate = .{ .previous_time = try std.time.Instant.now() };
    var animate_frame_ms: i32 = 15;

    while (true) {
        const action: enum { timeout, socket } = switch (try pollSocket(conn.sock, 0)) {
            .ready => .socket,
            .timeout => if (try getTimeout(animate.previous_time, animate_frame_ms)) |timeout_ms| switch (try pollSocket(conn.sock, timeout_ms)) {
                .ready => .socket,
                .timeout => .timeout,
            } else .timeout,
        };

        switch (action) {
            .timeout => {
                try render(
                    conn.sock,
                    &sequence,
                    ids.window(),
                    ids.gc(),
                    dbe,
                    &animate,
                    animate_frame_ms,
                );
                continue;
            },
            .socket => {},
        }

        const recv_buf = buf.nextReadBuffer();
        if (recv_buf.len == 0) {
            std.log.err("buffer size {} not big enough!", .{buf.half_len});
            return 1;
        }
        const len = try x11.readSock(conn.sock, recv_buf, 0);
        if (len == 0) {
            std.log.info("X server connection closed", .{});
            return 0;
        }
        buf.reserve(len);
        while (true) {
            const data = buf.nextReservedBuffer();
            if (data.len < 32)
                break;
            const msg_len = x11.parseMsgLen(data[0..32].*);
            if (data.len < msg_len)
                break;
            buf.release(msg_len);
            //buf.resetIfEmpty();
            switch (x11.serverMsgTaggedUnion(@alignCast(data.ptr))) {
                .err => |msg| {
                    std.log.err("{}", .{msg});
                    return 1;
                },
                .reply => |msg| {
                    std.log.info("todo: handle a reply message {}", .{msg});
                    return error.TodoHandleReplyMessage;
                },
                .key_press => |msg| {
                    var do_render = true;
                    if (keycode_map.get(msg.keycode)) |key| switch (key) {
                        .f => {
                            if (animate_frame_ms > 1) {
                                animate_frame_ms -= 1;
                            }
                        },
                        .s => animate_frame_ms += 1,
                        .d => switch (dbe) {
                            .unsupported => {},
                            .disabled => |disabled| {
                                try allocateBackBuffer(
                                    conn.sock,
                                    &sequence,
                                    disabled.opcode,
                                    ids.window(),
                                    ids.backBuffer(),
                                );
                                dbe = .{ .enabled = .{
                                    .opcode = disabled.opcode,
                                    .back_buffer = ids.backBuffer(),
                                } };
                            },
                            .enabled => |enabled| {
                                try deallocateBackBuffer(
                                    conn.sock,
                                    &sequence,
                                    enabled.opcode,
                                    ids.backBuffer(),
                                );
                                dbe = .{ .disabled = .{ .opcode = enabled.opcode } };
                            },
                        },
                    } else {
                        std.log.info("key_press: {}", .{msg.keycode});
                        do_render = false;
                    }
                    if (do_render) {
                        try render(
                            conn.sock,
                            &sequence,
                            ids.window(),
                            ids.gc(),
                            dbe,
                            &animate,
                            animate_frame_ms,
                        );
                    }
                },
                .key_release => unreachable,
                .button_press => unreachable,
                .button_release => unreachable,
                .enter_notify => |msg| {
                    std.log.info("enter_window: {}", .{msg});
                },
                .leave_notify => |msg| {
                    std.log.info("leave_window: {}", .{msg});
                },
                .motion_notify => |msg| {
                    // too much logging
                    _ = msg;
                    //std.log.info("pointer_motion: {}", .{msg});
                },
                .keymap_notify => |msg| {
                    std.log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    try render(
                        conn.sock,
                        &sequence,
                        ids.window(),
                        ids.gc(),
                        dbe,
                        &animate,
                        animate_frame_ms,
                    );
                },
                .mapping_notify => |msg| {
                    std.log.info("mapping_notify: {}", .{msg});
                },
                .no_exposure => |msg| std.debug.panic("unexpected no_exposure {}", .{msg}),
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
                .destroy_notify,
                .unmap_notify,
                .map_notify,
                .reparent_notify,
                .configure_notify,
                => unreachable, // did not register for these
            }
        }
    }
}

fn allocateBackBuffer(
    sock: std.posix.socket_t,
    sequence: *u16,
    dbe_ext_opcode: u8,
    window: x11.Window,
    back_buffer: x11.Drawable,
) !void {
    var msg: [x11.dbe.allocate.len]u8 = undefined;
    x11.dbe.allocate.serialize(&msg, .{
        .ext_opcode = dbe_ext_opcode,
        .window = window,
        .backbuffer = back_buffer,
        .swapaction = .background,
    });
    try common.sendOne(sock, sequence, &msg);
}

fn deallocateBackBuffer(
    sock: std.posix.socket_t,
    sequence: *u16,
    dbe_ext_opcode: u8,
    back_buffer: x11.Drawable,
) !void {
    var msg: [x11.dbe.deallocate.len]u8 = undefined;
    x11.dbe.deallocate.serialize(&msg, .{
        .ext_opcode = dbe_ext_opcode,
        .backbuffer = back_buffer,
    });
    try common.sendOne(sock, sequence, &msg);
}

fn swapBuffers(sock: std.posix.socket_t, sequence: *u16, dbe_ext_opcode: u8, window: x11.Window) !void {
    const swap_infos = [_]x11.dbe.SwapInfo{
        .{ .window = window, .action = .background },
    };
    var msg: [x11.dbe.swap.getLen(swap_infos.len)]u8 = undefined;
    const swap_infos_x11: x11.Slice(u32, [*]const x11.dbe.SwapInfo) = .{
        .ptr = &swap_infos,
        .len = swap_infos.len,
    };
    x11.dbe.swap.serialize(&msg, swap_infos_x11, .{
        .ext_opcode = dbe_ext_opcode,
    });
    try common.sendOne(sock, sequence, &msg);
}

fn pollSocket(sock: std.posix.socket_t, timeout_ms: i32) !enum { ready, timeout } {
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = sock,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    return switch (try std.posix.poll(&poll_fds, timeout_ms)) {
        0 => .timeout,
        1 => .ready,
        else => unreachable,
    };
}

pub fn getTimeout(start: std.time.Instant, duration_ms: i32) !?u31 {
    const now = try std.time.Instant.now();
    const since_ms = @divTrunc(now.since(start), std.time.ns_per_ms);
    if (since_ms >= duration_ms) return null;
    return @intCast(duration_ms - @as(i32, @intCast(since_ms)));
}

const Animate = struct {
    previous_time: std.time.Instant,
    progress: f32 = 0,
};

const Dbe = union(enum) {
    unsupported,
    disabled: struct {
        opcode: u8,
    },
    enabled: struct {
        opcode: u8,
        back_buffer: x11.Drawable,
    },
    pub fn backBuffer(self: Dbe) ?x11.Drawable {
        return switch (self) {
            .unsupported, .disabled => null,
            .enabled => |enabled| enabled.back_buffer,
        };
    }
};

fn render(
    sock: std.posix.socket_t,
    sequence: *u16,
    window: x11.Window,
    gc_id: x11.GraphicsContext,
    dbe: Dbe,
    animate: *Animate,
    animate_frame_ms: i32,
) !void {
    const elapsed_ms = blk: {
        const now = try std.time.Instant.now();
        const elapsed_ms = now.since(animate.previous_time);
        animate.previous_time = now;
        break :blk elapsed_ms;
    };

    const animation_duration_ms: f32 = 2000.0; // 2 seconds for full cycle
    const elapsed_ms_f32: f32 = @floatFromInt(elapsed_ms / std.time.ns_per_ms);
    const progress_increment: f32 = elapsed_ms_f32 / animation_duration_ms;
    animate.progress = @mod(animate.progress + progress_increment, 1.0);

    if (null == dbe.backBuffer()) {
        var msg: [x11.clear_area.len]u8 = undefined;
        x11.clear_area.serialize(&msg, false, window, .{
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
        });
        try common.sendOne(sock, sequence, &msg);
    }

    const target_drawable = if (dbe.backBuffer()) |back_buffer| back_buffer else window.drawable();

    {
        var msg: [x11.poly_fill_rectangle.getLen(1)]u8 = undefined;
        x11.poly_fill_rectangle.serialize(&msg, .{
            .drawable_id = target_drawable,
            .gc_id = gc_id,
        }, &.{.{
            .x = @intFromFloat(@round(@as(f32, window_width) * animate.progress)),
            .y = @intFromFloat(@round(@as(f32, window_width) * animate.progress)),
            .width = 10,
            .height = 10,
        }});
        try common.sendOne(sock, sequence, &msg);
    }

    const fps: f32 = @as(f32, 1000.0) / @as(f32, @floatFromInt(animate_frame_ms));
    if (animate_frame_ms == 0) {
        try renderString(sock, sequence, target_drawable, gc_id, 10, 10, "FPS: <no limit>", .{});
    } else {
        try renderString(sock, sequence, target_drawable, gc_id, 10, 10, "FPS: {d:.1}", .{fps});
    }
    try renderString(sock, sequence, target_drawable, gc_id, 270, 10, "f: faster, s: slower", .{});
    try renderString(sock, sequence, target_drawable, gc_id, 10, 30, "DoubleBuffering: {s}", .{@tagName(dbe)});
    try renderString(sock, sequence, target_drawable, gc_id, 270, 30, "d: toggle", .{});
    switch (dbe) {
        .unsupported, .disabled => {},
        .enabled => |enabled| {
            try swapBuffers(sock, sequence, enabled.opcode, window);
        },
    }
}

fn renderString(
    sock: std.posix.socket_t,
    sequence: *u16,
    drawable_id: x11.Drawable,
    gc_id: x11.GraphicsContext,
    pos_x: i16,
    pos_y: i16,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var msg: [x11.image_text8.max_len]u8 = undefined;
    const text_buf = msg[x11.image_text8.text_offset .. x11.image_text8.text_offset + 0xff];
    const text_len: u8 = @intCast((std.fmt.bufPrint(text_buf, fmt, args) catch @panic("string too long")).len);
    x11.image_text8.serializeNoTextCopy(&msg, text_len, .{
        .drawable_id = drawable_id,
        .gc_id = gc_id,
        .x = pos_x,
        .y = pos_y,
    });
    try common.sendOne(sock, sequence, msg[0..x11.image_text8.getLen(text_len)]);
}
