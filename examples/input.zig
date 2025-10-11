const std = @import("std");
const x11 = @import("x11");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 400;
const window_height = 400;

const Key = enum {
    escape,
    w,
    i,
    d,
    g,
    c,
    l,
};

const bg_color = 0x231a20;
const fg_color = 0xadccfa;

const Ids = struct {
    base: x11.ResourceBase,

    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn bg(self: Ids) x11.GraphicsContext {
        return self.base.add(1).graphicsContext();
    }
    pub fn fg(self: Ids) x11.GraphicsContext {
        return self.base.add(2).graphicsContext();
    }
    pub fn childWindow(self: Ids) x11.Window {
        return self.base.add(3).window();
    }
};

pub fn main() !u8 {
    try x11.wsaStartup();
    const conn = try x11.ext.connect(allocator);
    defer std.posix.shutdown(conn.sock, .both) catch {};

    var write_buf: [4096]u8 = undefined;
    var socket_writer = x11.socketWriter(conn.sock, &write_buf);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };

    var keycode_map = std.AutoHashMapUnmanaged(u8, Key){};
    {
        var sym_key_map = std.AutoHashMapUnmanaged(u32, Key){};
        defer sym_key_map.deinit(allocator);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.kbd_escape), Key.escape);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.latin_w), Key.w);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.latin_i), Key.i);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.latin_d), Key.d);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.latin_g), Key.g);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.latin_c), Key.c);
        try sym_key_map.put(allocator, @intFromEnum(x11.charset.Combined.latin_l), Key.l);

        const keymap = try x11.keymap.request(allocator, conn.sock, &sink, conn.setup.fixed());
        defer keymap.deinit(allocator);
        std.log.info("Keymap: syms_per_code={} total_syms={}", .{ keymap.syms_per_code, keymap.syms.len });
        {
            var i: usize = 0;
            var sym_offset: usize = 0;
            while (i < keymap.keycode_count) : (i += 1) {
                const keycode: u8 = @intCast(conn.setup.fixed().min_keycode + i);
                var j: usize = 0;
                while (j < keymap.syms_per_code) : (j += 1) {
                    const sym = keymap.syms[sym_offset];
                    if (sym_key_map.get(sym)) |key| {
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

    // TODO: maybe need to call conn.setup.verify or something?
    const ids: Ids = .{ .base = conn.setup.fixed().resource_id_base };

    try sink.CreateWindow(.{
        .window_id = ids.window(),
        .parent_window_id = screen.root,
        .depth = 0, // dont care, inherit from parent
        .x = 0,
        .y = 0,
        .width = window_width,
        .height = window_height,
        .border_width = 0, // TODO: what is this?
        .class = .input_output,
        .visual_id = screen.root_visual,
    }, .{
        // .bg_pixmap = .copy_from_parent,
        .bg_pixel = bg_color,
        // .border_pixmap =
        // .border_pixel = 0x01fa8ec9,
        // .bit_gravity = .north_west,
        // .win_gravity = .east,
        // .backing_store = .when_mapped,
        // .backing_planes = 0x1234,
        // .backing_pixel = 0xbbeeeeff,
        // .override_redirect = true,
        // .save_under = true,
        .event_mask = .{
            .key_press = 1,
            .key_release = 1,
            .button_press = 1,
            .button_release = 1,
            .enter_window = 1,
            .leave_window = 1,
            .pointer_motion = 1,
            .keymap_state = 1,
            .exposure = 1,
        },
        // .dont_propagate = 1,
    });

    try sink.CreateGc(
        ids.bg(),
        ids.window().drawable(),
        .{ .foreground = fg_color },
    );
    try sink.CreateGc(
        ids.fg(),
        ids.window().drawable(),
        .{
            .background = bg_color,
            .foreground = fg_color,
        },
    );

    // get some font information
    {
        const text_literal = [_]u16{'m'};
        const text = x11.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        try sink.QueryTextExtents(ids.fg().fontable(), text);
    }

    const double_buf = try x11.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.heap.pageSize()),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    // double_buf.deinit() (not necessary)
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    var reader: x11.SocketReader = .init(conn.sock);

    const font_dims: FontDims = blk: {
        try sink.writer.flush();
        _ = try x11.readOneMsg(reader.interface(), @alignCast(buf.nextReadBuffer()));
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
                std.log.err("expected a reply but got {f}", .{msg});
                return 1;
            },
        }
    };

    try sink.MapWindow(ids.window());

    var state = State{};

    try sink.QueryExtension(.initComptime("XInputExtension"));
    state.xinput = .{ .sent_extension_query = .{
        .sequence = sink.sequence,
    } };

    while (true) {
        try sink.writer.flush();

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
                    std.log.err("X11Error: {f}", .{msg});
                    return 1;
                },
                .reply => |msg| {
                    const handled = try handleReply(
                        &sink,
                        &state,
                        msg,
                        screen.root,
                        ids.window(),
                        ids.bg(),
                        ids.fg(),
                        font_dims,
                    );
                    if (!handled) {
                        std.log.info("unexpected X11 reply: {f}", .{msg});
                        std.process.exit(0xff);
                    }
                    // just always do another render, it's *probably* needed
                    try render(&sink, ids.window(), ids.bg(), ids.fg(), font_dims, state);
                },
                .generic_extension_event => |msg| {
                    if (state.xinput == .enabled and msg.ext_opcode == state.xinput.enabled.input_extension_info.opcode) {
                        switch (x11.inputext.genericExtensionEventTaggedUnion(@alignCast(data.ptr))) {
                            .raw_button_press => |extension_msg| {
                                std.log.info("received raw_button_press {}", .{extension_msg});
                            },
                            else => unreachable, // We did not register for these events so we should not see them
                        }
                    } else {
                        std.log.info("TODO: handle a generic extension event {}", .{msg});
                        return error.TodoHandleGenericExtensionEvent;
                    }
                },
                .key_press => |msg| {
                    var do_render = true;
                    if (keycode_map.get(msg.keycode)) |key| switch (key) {
                        .g => {
                            //try state.toggleGrab(&sink, screen.root);
                            try state.toggleGrab(&sink, ids.window());
                        },
                        .w => try warpPointer(&sink),
                        .c => {
                            state.confine_grab = !state.confine_grab;
                        },
                        .i => if (state.window_created) {
                            try sink.DestroyWindow(ids.childWindow());
                            state.window_created = false;
                        } else {
                            try createWindow(&sink, screen.root, ids.childWindow());
                            state.window_created = true;
                        },
                        .d => {
                            try disableInputDevice(&sink, &state);
                        },
                        .l => {
                            try listenToRawEvents(&sink, &state, screen.root);
                        },
                        .escape => {
                            std.log.info("ESC pressed, exiting loop...", .{});
                            return 0;
                        },
                    } else {
                        std.log.info("key_press: {}", .{msg.keycode});
                        do_render = false;
                    }
                    if (do_render) {
                        try render(&sink, ids.window(), ids.bg(), ids.fg(), font_dims, state);
                    }
                },
                .key_release => |msg| {
                    std.log.info("key_release: {}", .{msg.keycode});
                },
                .button_press => |msg| {
                    std.log.info("button_press: {}", .{msg});
                },
                .button_release => |msg| {
                    std.log.info("button_release: {}", .{msg});
                },
                .enter_notify => |msg| {
                    std.log.info("enter_window: {}", .{msg});
                },
                .leave_notify => |msg| {
                    std.log.info("leave_window: {}", .{msg});
                },
                .motion_notify => |msg| {
                    // too much logging
                    //std.log.info("pointer_motion: {}", .{msg});
                    state.pointer_root_pos.x = msg.root_x;
                    state.pointer_root_pos.y = msg.root_y;
                    state.pointer_event_pos.x = msg.event_x;
                    state.pointer_event_pos.y = msg.event_y;
                    try render(&sink, ids.window(), ids.bg(), ids.fg(), font_dims, state);
                },
                .keymap_notify => |msg| {
                    std.log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    try render(&sink, ids.window(), ids.bg(), ids.fg(), font_dims, state);
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
                => unreachable, // We did not register for these events so we should not see them
            }
        }
    }
}

fn handleReply(
    sink: *x11.RequestSink,
    state: *State,
    msg: *const x11.ServerMsg.Reply,
    root_window_id: x11.Window,
    window_id: x11.Window,
    bg_gc_id: x11.GraphicsContext,
    fg_gc_id: x11.GraphicsContext,
    font_dims: FontDims,
) !bool {
    switch (state.grab) {
        .disabled => {},
        .requested => |requested_grab| if (requested_grab.sequence == msg.sequence) {
            // I guess we'll assume this is the reply for now
            const status = msg.reserve_min[0];
            if (status == 0) {
                std.log.info("grab success!", .{});
                state.grab = .{ .enabled = .{ .confined = requested_grab.confined } };
            } else {
                const error_msg = switch (status) {
                    1 => "already grabbed",
                    2 => "invalid time",
                    3 => "not viewable",
                    4 => "frozen",
                    else => "unknown error code",
                };
                std.log.info("grab failed with '{s}' ({})", .{ error_msg, status });
                state.grab = .disabled;
            }
            try render(sink, window_id, bg_gc_id, fg_gc_id, font_dims, state.*);
            return true; // handled
        },
        .enabled => {},
    }

    switch (state.xinput) {
        .initial, .extension_missing, .enabled => {},
        .sent_extension_query => |query| if (msg.sequence == query.sequence) {
            const msg_ext: *const x11.ServerMsg.QueryExtension = @ptrCast(msg);
            if (msg_ext.present == 0) {
                state.xinput = .extension_missing;
            } else {
                std.debug.assert(msg_ext.present == 1);
                const name = comptime x11.Slice(u16, [*]const u8).initComptime("XInputExtension");
                try x11.inputext.GetExtensionVersion(sink, msg_ext.major_opcode, name);

                // Useful for debugging
                std.log.info("{f} extension: opcode={} base_error_code={}", .{
                    name,
                    msg_ext.major_opcode,
                    msg_ext.first_error,
                });

                state.xinput = .{ .get_version = .{
                    .sequence = sink.sequence,
                    .input_extension_info = .{
                        .extension_name = "XInputExtension",
                        .opcode = msg_ext.major_opcode,
                        .base_error_code = msg_ext.first_error,
                    },
                } };
            }
            return true; // handled
        },
        .get_version => |info| if (msg.sequence == info.sequence) {
            const opcode = msg.flexible;
            const msg_ext: *const x11.inputext.GetExtensionVersionReply = @ptrCast(msg);
            std.log.debug("get_extension_version returned {}", .{msg_ext});
            if (opcode != @intFromEnum(x11.inputext.ExtOpcode.get_extension_version))
                std.debug.panic("invalid opcode in reply {}, expected {}", .{ opcode, @intFromEnum(x11.inputext.ExtOpcode.get_extension_version) });
            if (!msg_ext.present)
                std.debug.panic("XInputExtension is not present, but it was before?", .{});
            if (msg_ext.major_version != 2)
                std.debug.panic("XInputExtension major version is {} but need {}", .{ msg_ext.major_version, 2 });
            if (msg_ext.minor_version < 3)
                std.debug.panic("XInputExtension minor version is {} but I've only tested >= {}", .{ msg_ext.minor_version, 3 });

            state.xinput = .{ .enabled = .{
                .input_extension_info = info.input_extension_info,
            } };

            // Now that we see that the input extension is available and compatible, let's
            // resume any operations that someone requested while we were waiting for the
            // extension to be available.
            if (state.disable_input_device == .extension_not_available_yet) {
                try disableInputDevice(sink, state);
            }
            if (state.listen_to_raw_events == .extension_not_available_yet) {
                try listenToRawEvents(sink, state, root_window_id);
            }

            return true; // handled
        },
    }

    switch (state.disable_input_device) {
        .initial, .no_pointer_to_disable, .extension_not_available_yet, .extension_missing, .disabled => {},
        .list_devices => |state_info| if (msg.sequence == state_info.sequence) {
            const devices_reply: *const x11.inputext.ListInputDevicesReply = @ptrCast(msg);
            var input_info_it = devices_reply.inputInfoIterator();
            var names_it = devices_reply.findNames();
            var selected_pointer_id: ?u8 = null;
            for (devices_reply.deviceInfos().nativeSlice()) |*device| {
                const name = (try names_it.next()) orelse @panic("malformed reply");
                if (device.use == .extension_pointer) {
                    if (selected_pointer_id) |id| {
                        std.log.warn("multiple pointer ids, dropping {}", .{id});
                    }
                    selected_pointer_id = device.id;
                }
                std.log.info("Device {} '{f}', type={}, use={s}:", .{ device.id, name, device.device_type, @tagName(device.use) });
                var info_index: u8 = 0;
                while (info_index < device.class_count) : (info_index += 1) {
                    std.log.info("  Input: {f}", .{input_info_it.front()});
                    input_info_it.pop();
                }
            }
            std.debug.assert((try names_it.next()) == null);

            if (selected_pointer_id) |pointer_id| {
                const name = comptime x11.Slice(u16, [*]const u8).initComptime("Device Enabled");
                try sink.InternAtom(.{
                    .only_if_exists = false,
                    .name = name,
                });
                state.disable_input_device = .{ .intern_atom = .{
                    .sequence = sink.sequence,
                    .ext_opcode = state_info.ext_opcode,
                    .pointer_id = pointer_id,
                } };
            } else {
                state.disable_input_device = .no_pointer_to_disable;
            }
            return true; // handled
        },
        .intern_atom => |info| if (msg.sequence == info.sequence) {
            const atom = x11.readIntNative(u32, msg.reserve_min[0..]);
            try x11.inputext.GetProperty(sink, info.ext_opcode, .{
                .device_id = info.pointer_id,
                .property = atom,
                .type = 0,
                .offset = 0,
                .len = 0,
                .delete = false,
            });
            state.disable_input_device = .{ .get_prop = .{
                .sequence = sink.sequence,
                .ext_opcode = info.ext_opcode,
                .pointer_id = info.pointer_id,
                .atom = atom,
            } };
            return true;
        },
        .get_prop => |info| if (msg.sequence == info.sequence) {
            const reply: *const x11.inputext.get_property.Reply = @ptrCast(msg);
            std.log.info("get_property returned {}", .{reply});

            try x11.inputext.ChangeProperty(sink, info.ext_opcode, u8, .{
                .device_id = info.pointer_id,
                .mode = .replace,
                .property = info.atom,
                .type = @intFromEnum(x11.Atom.INTEGER),
                .values = x11.Slice(u16, [*]const u8).initComptime(&[_]u8{0}),
            });
            state.disable_input_device = .{ .disabled = .{
                .ext_opcode = info.ext_opcode,
                .pointer_id = info.pointer_id,
                .atom = info.atom,
            } };
            return true;
        },
    }

    return false; // not handled
}

fn warpPointer(sink: *x11.RequestSink) !void {
    std.log.info("warping pointer 20 x 10...", .{});
    try sink.WarpPointer(.{
        .src_window = .none,
        .dst_window = .none,
        .src_x = 0,
        .src_y = 0,
        .src_width = 0,
        .src_height = 0,
        .dst_x = 20,
        .dst_y = 10,
    });
}

fn createWindow(sink: *x11.RequestSink, parent_window_id: x11.Window, window_id: x11.Window) !void {
    try sink.CreateWindow(.{
        .window_id = window_id,
        .parent_window_id = parent_window_id,
        .depth = 0, // dont care, inherit from parent
        .x = 0,
        .y = 0,
        .width = 500,
        .height = 500,
        .border_width = 0, // TODO: what is this?
        .class = .input_output,
        //.class = .input_only,
        .visual_id = .copy_from_parent,
    }, .{
        // .bg_pixmap = .copy_from_parent,
        // .bg_pixel = bg_color,
        // //.border_pixmap =
        // .border_pixel = 0x01fa8ec9,
        // .bit_gravity = .north_west,
        // .win_gravity = .east,
        // .backing_store = .when_mapped,
        // .backing_planes = 0x1234,
        // .backing_pixel = 0xbbeeeeff,
        // .override_redirect = true,
        // .save_under = true,
        // .event_mask =
        //     x11.event.key_press
        //     | x11.event.key_release
        //     | x11.event.button_press
        //     | x11.event.button_release
        //     | x11.event.enter_window
        //     | x11.event.leave_window
        //     | x11.event.pointer_motion
        //     | x11.event.pointer_motion_hint WHAT THIS DO?
        //     | x11.event.button1_motion  WHAT THIS DO?
        //     | x11.event.button2_motion  WHAT THIS DO?
        //     | x11.event.button3_motion  WHAT THIS DO?
        //     | x11.event.button4_motion  WHAT THIS DO?
        //     | x11.event.button5_motion  WHAT THIS DO?
        //     | x11.event.button_motion  WHAT THIS DO?
        //     | x11.event.keymap_state
        //     | x11.event.exposure
        //     ,
        // .dont_propagate = 1,
    });
    try sink.MapWindow(window_id);
}

fn listenToRawEvents(sink: *x11.RequestSink, state: *State, root_window_id: x11.Window) !void {
    const extension_missing_fmt = "unable to listen to raw events, XInputExtension is missing";
    switch (state.listen_to_raw_events) {
        .initial, .extension_not_available_yet => {
            if (state.xinput == .extension_missing) {
                std.log.info(extension_missing_fmt, .{});
                state.listen_to_raw_events = .extension_missing;
                return;
            } else if (state.xinput != .enabled) {
                std.log.info("unable to listen to raw events at this moment, waiting for the XInputExtension before continuing.", .{});
                state.listen_to_raw_events = .extension_not_available_yet;
                return;
            }

            // Listen to all mouse clicks regardless of where they occurred
            std.log.info("Setting up raw mouse click listener...", .{});
            var event_masks = [_]x11.inputext.EventMask{.{
                .device_id = .all_master,
                .mask = x11.inputext.event.raw_button_press,
            }};

            const input_ext_opcode = state.xinput.enabled.input_extension_info.opcode;
            try x11.inputext.SelectEvents(sink, input_ext_opcode, root_window_id, event_masks[0..]);

            state.listen_to_raw_events = .enabled;
        },
        .extension_missing => std.log.info(extension_missing_fmt, .{}),
        .enabled => std.log.info("listening to raw events already", .{}),
    }
}

fn disableInputDevice(sink: *x11.RequestSink, state: *State) !void {
    const already_fmt = "disable input device already requested, {s}...";
    const extension_missing_fmt = "can't disable input device, XInputExtension is missing";
    switch (state.disable_input_device) {
        // Transition from initial or someone who previously failed to disable the
        // pointer because they had no pointer at the time.
        .initial, .no_pointer_to_disable, .extension_not_available_yet => {
            if (state.xinput == .extension_missing) {
                std.log.info(extension_missing_fmt, .{});
                state.disable_input_device = .extension_missing;
                return;
            } else if (state.xinput != .enabled) {
                std.log.info("can't disable input device at this moment, waiting for the XInputExtension before continuing.", .{});
                state.disable_input_device = .extension_not_available_yet;
                return;
            }

            const input_ext_opcode = state.xinput.enabled.input_extension_info.opcode;
            try x11.inputext.ListInputDevices(sink, input_ext_opcode);
            state.disable_input_device = .{ .list_devices = .{
                .sequence = sink.sequence,
                .ext_opcode = input_ext_opcode,
            } };
        },
        .extension_missing => std.log.info(extension_missing_fmt, .{}),
        .list_devices => std.log.info(already_fmt, .{"getting input devices"}),
        .intern_atom => std.log.info(already_fmt, .{"interning atom"}),
        .get_prop => std.log.info(already_fmt, .{"getting property"}),
        .disabled => |info| {
            std.log.info("TODO: re-enabled input device {}", .{info.pointer_id});
        },
    }
}

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

fn Pos(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}
const State = struct {
    pointer_root_pos: Pos(i16) = .{ .x = -1, .y = -1 },
    pointer_event_pos: Pos(i16) = .{ .x = -1, .y = -1 },
    grab: union(enum) {
        disabled: void,
        requested: struct { confined: bool, sequence: u16 },
        enabled: struct { confined: bool },
    } = .disabled,
    confine_grab: bool = false,

    xinput: union(enum) {
        initial: void,
        sent_extension_query: struct {
            sequence: u16,
        },
        extension_missing: void,
        get_version: struct {
            sequence: u16,
            input_extension_info: x11.ext.ExtensionInfo,
        },
        enabled: struct {
            input_extension_info: x11.ext.ExtensionInfo,
        },
    } = .initial,

    listen_to_raw_events: union(enum) {
        initial: void,
        extension_not_available_yet: void,
        extension_missing: void,
        enabled: void,
    } = .initial,

    disable_input_device: union(enum) {
        initial: void,
        extension_not_available_yet: void,
        extension_missing: void,
        list_devices: struct {
            sequence: u16,
            ext_opcode: u8,
        },
        no_pointer_to_disable: void,
        intern_atom: struct {
            sequence: u16,
            ext_opcode: u8,
            pointer_id: u8,
        },
        get_prop: struct {
            sequence: u16,
            ext_opcode: u8,
            pointer_id: u8,
            atom: u32,
        },
        disabled: struct {
            ext_opcode: u8,
            pointer_id: u8,
            atom: u32,
        },
    } = .initial,
    window_created: bool = false,

    fn toggleGrab(self: *State, sink: *x11.RequestSink, grab_window: x11.Window) !void {
        switch (self.grab) {
            .disabled => {
                std.log.info("requesting grab...", .{});
                try sink.GrabPointer(.{
                    //.owner_events = true,
                    .owner_events = false,
                    .grab_window = grab_window,
                    .event_mask = .{ .pointer_motion = 1 },
                    .pointer_mode = .synchronous,
                    .keyboard_mode = .asynchronous,
                    .confine_to = if (self.confine_grab) grab_window else .none,
                    .cursor = .none,
                    .time = .current_time,
                });
                self.grab = .{ .requested = .{
                    .confined = self.confine_grab,
                    .sequence = sink.sequence,
                } };
            },
            .requested => {
                std.log.info("grab already requested", .{});
            },
            .enabled => {
                std.log.info("ungrabbing", .{});
                try sink.UngrabPointer(.current_time);
                self.grab = .disabled;
            },
        }
    }
};

fn renderString(
    sink: *x11.RequestSink,
    drawable: x11.Drawable,
    gc: x11.GraphicsContext,
    pos: x11.XY(i16),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    sink.printImageText8(drawable, gc, pos, fmt, args) catch |err| switch (err) {
        error.TextTooLong => @panic("todo: handle render long text"),
        error.WriteFailed => return error.WriteFailed,
    };
}

fn render(
    sink: *x11.RequestSink,
    window_id: x11.Window,
    bg_gc_id: x11.GraphicsContext,
    fg_gc_id: x11.GraphicsContext,
    font_dims: FontDims,
    state: State,
) !void {
    _ = bg_gc_id;
    try sink.ClearArea(
        window_id,
        .{
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
        },
        .{ .exposures = false },
    );
    try renderString(
        sink,
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = font_dims.font_left,
            .y = font_dims.font_ascent + (0 * font_dims.height),
        },
        "root: {} x {}",
        .{
            state.pointer_root_pos.x,
            state.pointer_root_pos.y,
        },
    );
    try renderString(
        sink,
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = font_dims.font_left,
            .y = font_dims.font_ascent + (1 * font_dims.height),
        },
        "event: {} x {}",
        .{
            state.pointer_event_pos.x,
            state.pointer_event_pos.y,
        },
    );
    const grab_suffix: []const u8 = switch (state.grab) {
        .disabled => "",
        .requested => |c| if (c.confined) " confined=true" else " confined=false",
        .enabled => |c| if (c.confined) " confined=true" else " confined=false",
    };
    try renderString(
        sink,
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = font_dims.font_left,
            .y = font_dims.font_ascent + (2 * font_dims.height),
        },
        "(G)rab: {s}{s}",
        .{ @tagName(state.grab), grab_suffix },
    );
    try renderString(
        sink,
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = font_dims.font_left,
            .y = font_dims.font_ascent + (3 * font_dims.height),
        },
        "(C)onfine Grab: {}",
        .{state.confine_grab},
    );
    try renderString(
        sink,
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = font_dims.font_left,
            .y = font_dims.font_ascent + (4 * font_dims.height),
        },
        "(W)arp",
        .{},
    );
    try renderString(
        sink,
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = font_dims.font_left,
            .y = font_dims.font_ascent + (5 * font_dims.height),
        },
        "{s} W(i)ndow",
        .{if (state.window_created) "Destroy" else "Create"},
    );
    {
        const suffix: []const u8 = switch (state.disable_input_device) {
            .initial => "",
            .extension_not_available_yet => " (waiting for XInputExtension...)",
            .extension_missing => " (XInputExtension is missing)",
            .list_devices => " (listing input devices...)",
            .no_pointer_to_disable => " (failed: no pointer to disable)",
            .intern_atom => " (interning atom...)",
            .get_prop => " (getting current property value...)",
            .disabled => " (disabled)",
        };
        try renderString(
            sink,
            window_id.drawable(),
            fg_gc_id,
            .{
                .x = font_dims.font_left,
                .y = font_dims.font_ascent + (6 * font_dims.height),
            },
            "(D)isable Input Device{s}",
            .{suffix},
        );
    }
    {
        const suffix: []const u8 = switch (state.listen_to_raw_events) {
            .initial => "",
            .extension_not_available_yet => " (waiting for XInputExtension...)",
            .extension_missing => " (XInputExtension is missing)",
            .enabled => " (enabled)",
        };
        try renderString(
            sink,
            window_id.drawable(),
            fg_gc_id,
            .{
                .x = font_dims.font_left,
                .y = font_dims.font_ascent + (7 * font_dims.height),
            },
            "(L)isten to raw events{s}",
            .{suffix},
        );
    }
}
