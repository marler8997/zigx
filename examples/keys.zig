const window_width = 300;
const window_height = 800;

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

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    const conn = try common.connect(allocator);
    defer std.posix.shutdown(conn.sock, .both) catch {};

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

    var sequence: u16 = 0;

    var keymap: x11.keymap.Full = .initVoid();

    {
        const keymap_response = try x11.keymap.request(
            allocator,
            conn.sock,
            &sequence,
            conn.setup.fixed(),
        );
        defer keymap_response.deinit(allocator);
        try keymap.load(conn.setup.fixed().min_keycode, keymap_response);
    }

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
                .key_release = 1,
                // .keymap_state = 1,
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

    // get some font information
    {
        const text_literal = [_]u16{'m'};
        const text = x11.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        var msg: [x11.query_text_extents.getLen(text.len)]u8 = undefined;
        x11.query_text_extents.serialize(&msg, ids.gc().fontable(), text);
        try conn.sendOne(&sequence, &msg);
    }

    const font_dims: FontDims = blk: {
        _ = try x11.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x11.ServerMsg.QueryTextExtents = @ptrCast(msg_reply);
                break :blk .{
                    .width = @intCast(msg.overall_width),
                    .height = @intCast(msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(msg.overall_left),
                    .font_ascent = msg.font_ascent,
                };
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return 1;
            },
        }
    };

    {
        var msg: [x11.map_window.len]u8 = undefined;
        x11.map_window.serialize(&msg, ids.window());
        try conn.sendOne(&sequence, &msg);
    }

    var key_log: std.BoundedArray(KeyEvent, 80) = .{ .len = 0, .buffer = undefined };
    var key_log_next: usize = 0;

    while (true) {
        {
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
        }

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
                    if (keymap.getKeysym(msg.keycode, msg.state.mod())) |keysym| {
                        // std.log.info("key_press: mod={} sym={} {}", .{ msg.state.mod(), keysym, msg.keycode });
                        key_log.buffer[key_log_next] = .{
                            .keycode = msg.keycode,
                            .mask = msg.state,
                            .keysym = keysym,
                        };
                        key_log_next = (key_log_next + 1) % key_log.buffer.len;
                        key_log.len = @max(key_log_next, key_log.len);
                        try render(
                            conn.sock,
                            &sequence,
                            ids.window(),
                            ids.gc(),
                            dbe,
                            &font_dims,
                            key_log.slice(),
                            key_log_next,
                        );
                    } else |err| switch (err) {
                        error.KeycodeTooSmall => {
                            std.log.err("keycode {} is too small", .{msg.keycode});
                        },
                    }
                },
                .key_release => {
                    std.log.err("TODO: handle key release", .{});
                },
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
                        &font_dims,
                        key_log.slice(),
                        key_log_next,
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
                .generic_extension_event,
                => unreachable, // did not register for these
            }
        }
    }
}

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

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

const KeyEvent = struct {
    keycode: u8,
    mask: x11.KeyButtonMask,
    keysym: x11.charset.Combined,
};

fn render(
    sock: std.posix.socket_t,
    sequence: *u16,
    window: x11.Window,
    gc_id: x11.GraphicsContext,
    dbe: Dbe,
    font_dims: *const FontDims,
    key_log: []const KeyEvent,
    key_log_next: usize,
) !void {
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

    const margin_left = 5;
    const margin_top = 5;

    const line_height = font_dims.height;

    {
        const text = x11.SliceWithMaxLen(u8, [*]const u8, 254).initComptime("Idx: Cod Mod    -> Sym");
        try renderString(
            sock,
            sequence,
            target_drawable,
            gc_id,
            text,
            .{
                .x = margin_left,
                .y = @intCast(margin_top + line_height),
            },
        );
    }

    var key_log_previous_index = key_log_next;
    for (0..key_log.len) |row| {
        var text_buf: [254]u8 = undefined;

        const key_log_index = blk: {
            if (key_log_previous_index == 0) break :blk key_log.len - 1;
            break :blk key_log_previous_index - 1;
        };
        key_log_previous_index = key_log_index;
        const mod_string: []const u8 = switch (key_log[key_log_index].mask.mod()) {
            .lower => "lower0",
            .upper => "upper0",
            .lower_mod => "lower1",
            .upper_mod => "upper1",
        };
        const text = std.fmt.bufPrint(&text_buf, "{: >3}: {: >3} {s} -> {s}", .{
            row,
            key_log[key_log_index].keycode,
            mod_string,
            @tagName(key_log[key_log_index].keysym),
        }) catch unreachable;
        const text_x11 = x11.SliceWithMaxLen(u8, [*]const u8, text_buf.len){
            .ptr = text.ptr,
            .len = std.math.cast(u8, text.len) orelse std.debug.panic("TODO: handle text with {} bytes", .{text.len}),
        };
        try renderString(
            sock,
            sequence,
            target_drawable,
            gc_id,
            text_x11,
            .{
                .x = margin_left,
                .y = @intCast(margin_top + ((row + 2) * line_height)),
            },
        );
    }

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
    drawable: x11.Drawable,
    gc: x11.GraphicsContext,
    text: x11.SliceWithMaxLen(u8, [*]const u8, 254),
    pos: struct { x: i16, y: i16 },
) !void {
    const poly_text8_max_one_item = comptime x11.poly_text8.getLen(&[_]x11.TextItem8{
        .{ .text_element = .{ .delta = 0, .string = .undefined_max_len } },
    });
    var msg_buf: [poly_text8_max_one_item]u8 = undefined;
    const items = [_]x11.TextItem8{
        .{ .text_element = .{ .delta = 0, .string = text } },
    };
    x11.poly_text8.serialize(&msg_buf, &items, .{
        .drawable_id = drawable,
        .gc_id = gc,
        .x = pos.x,
        .y = pos.y,
    });
    const msg_len: usize = x11.poly_text8.getLen(&items);
    try common.sendOne(sock, sequence, msg_buf[0..msg_len]);
}

const std = @import("std");
const x11 = @import("x11");
const common = @import("common.zig");
