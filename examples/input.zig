const std = @import("std");
const x11 = @import("x11");
const common = @import("common.zig");

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
    const conn = try common.connect(allocator);
    defer std.posix.shutdown(conn.sock, .both) catch {};

    var sequence: u16 = 0;

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

        const keymap = try x11.keymap.request(allocator, conn.sock, &sequence, conn.setup.fixed().*);
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

    const double_buf = try x11.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.heap.pageSize()),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    // double_buf.deinit() (not necessary)
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    const wm_protocol_atoms: WmProtocolAtoms = .{
        .WM_PROTOCOLS = try internAtom(conn.sock, &buf, &sequence, "WM_PROTOCOLS"),
        .WM_DELETE_WINDOW = try internAtom(conn.sock, &buf, &sequence, "WM_DELETE_WINDOW"),
    };

    // TODO: maybe need to call conn.setup.verify or something?
    const ids: Ids = .{ .base = conn.setup.fixed().resource_id_base };

    {
        var msg_buf: [x11.create_window.max_len]u8 = undefined;
        const len = x11.create_window.serialize(&msg_buf, .{
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
        try common.sendOne(conn.sock, &sequence, msg_buf[0..len]);
    }

    try setupWmProtocols(conn.sock, &sequence, ids.window(), wm_protocol_atoms);

    {
        var msg_buf: [x11.create_gc.max_len]u8 = undefined;
        const len = x11.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.bg(),
            .drawable_id = ids.window().drawable(),
        }, .{
            .foreground = fg_color,
        });
        try common.sendOne(conn.sock, &sequence, msg_buf[0..len]);
    }
    {
        var msg_buf: [x11.create_gc.max_len]u8 = undefined;
        const len = x11.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.fg(),
            .drawable_id = ids.window().drawable(),
        }, .{
            .background = bg_color,
            .foreground = fg_color,
        });
        try common.sendOne(conn.sock, &sequence, msg_buf[0..len]);
    }

    // get some font information
    {
        const text_literal = [_]u16{'m'};
        const text = x11.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        var msg: [x11.query_text_extents.getLen(text.len)]u8 = undefined;
        x11.query_text_extents.serialize(&msg, ids.fg().fontable(), text);
        try common.sendOne(conn.sock, &sequence, &msg);
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
        try common.sendOne(conn.sock, &sequence, &msg);
    }
    var state = State{};

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
                    const handled = try handleReply(
                        conn.sock,
                        &sequence,
                        &state,
                        msg,
                        ids.window(),
                        ids.bg(),
                        ids.fg(),
                        font_dims,
                    );
                    if (!handled) {
                        std.log.info("unexpected reply message {}", .{msg});
                        std.process.exit(0xff);
                    }
                    // just always do another render, it's *probably* needed
                    try render(conn.sock, &sequence, ids.window(), ids.bg(), ids.fg(), font_dims, state);
                },
                .key_press => |msg| {
                    var do_render = true;
                    if (keycode_map.get(msg.keycode)) |key| switch (key) {
                        .g => {
                            //try state.toggleGrab(conn.sock, screen.root);
                            try state.toggleGrab(conn.sock, &sequence, ids.window());
                        },
                        .w => {
                            try warpPointer(conn.sock, &sequence);
                        },
                        .c => {
                            state.confine_grab = !state.confine_grab;
                        },
                        .i => if (state.window_created) {
                            try destroyWindow(conn.sock, &sequence, ids.childWindow());
                            state.window_created = false;
                        } else {
                            try createWindow(conn.sock, &sequence, screen.root, ids.childWindow(), wm_protocol_atoms);
                            state.window_created = true;
                        },
                        .d => {
                            try disableInputDevice(conn.sock, &sequence, &state);
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
                        try render(conn.sock, &sequence, ids.window(), ids.bg(), ids.fg(), font_dims, state);
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
                    try render(conn.sock, &sequence, ids.window(), ids.bg(), ids.fg(), font_dims, state);
                },
                .keymap_notify => |msg| {
                    std.log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    try render(conn.sock, &sequence, ids.window(), ids.bg(), ids.fg(), font_dims, state);
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

fn internAtom(
    sock: std.posix.socket_t,
    buf: *x11.ContiguousReadBuffer,
    sequence: *u16,
    comptime name: []const u8,
) !u32 {
    const name_x11 = comptime x11.Slice(u16, [*]const u8).initComptime(name);
    var msg: [x11.intern_atom.getLen(name_x11.len)]u8 = undefined;
    x11.intern_atom.serialize(&msg, .{
        .only_if_exists = false,
        .name = name_x11,
    });
    return internAtom2(sock, buf, &msg, sequence);
}
fn internAtom2(
    sock: std.posix.socket_t,
    buf: *x11.ContiguousReadBuffer,
    request_msg: []const u8,
    sequence: *u16,
) !u32 {
    const intern_sequence = sequence.*;
    try common.sendOne(sock, sequence, request_msg);
    const reader = common.SocketReader{ .context = sock };
    _ = try x11.readOneMsg(reader, @alignCast(buf.nextReadBuffer()));
    switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
        .reply => |reply| {
            if (reply.sequence != intern_sequence) {
                std.log.err("expected reply to sequence {} but got {}", .{ intern_sequence, reply });
                return 1;
            }
            return x11.readIntNative(u32, reply.reserve_min[0..]);
        },
        else => |msg_server| {
            std.log.err("expected a reply but got {}", .{msg_server});
            return 1;
        },
    }

    if (true) @panic("todo: intern atoms for WM_PROTOCOLS and WM_DELETE_WINDOW");
}

fn setupWmProtocols(
    sock: std.posix.socket_t,
    sequence: *u16,
    window_id: x11.Window,
    wm_protocol_atoms: WmProtocolAtoms,
) !void {
    const change_prop_u32 = x11.change_property.withFormat(u32);
    var msg: [change_prop_u32.getLen(1)]u8 = undefined;
    change_prop_u32.serialize(&msg, .{
        .mode = .replace,
        .window_id = window_id,
        .property = @enumFromInt(wm_protocol_atoms.WM_PROTOCOLS),
        .type = @enumFromInt(@intFromEnum(x11.Atom.ATOM)),
        .values = x11.Slice(u16, [*]const u32){
            .ptr = @ptrCast(&wm_protocol_atoms.WM_DELETE_WINDOW),
            .len = 1,
        },
    });
    try common.sendOne(sock, sequence, &msg);
}

fn handleReply(
    sock: std.posix.socket_t,
    sequence: *u16,
    state: *State,
    msg: *const x11.ServerMsg.Reply,
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
            try render(sock, sequence, window_id, bg_gc_id, fg_gc_id, font_dims, state.*);
            return true; // handled
        },
        .enabled => {},
    }

    switch (state.disable_input_device) {
        .initial, .extension_missing, .no_pointer_to_disable, .disabled => {},
        .query_extension => |query_sequence| if (msg.sequence == query_sequence) {
            const msg_ext: *const x11.ServerMsg.QueryExtension = @ptrCast(msg);
            if (msg_ext.present == 0) {
                state.disable_input_device = .extension_missing;
            } else {
                std.debug.assert(msg_ext.present == 1);
                const name = comptime x11.Slice(u16, [*]const u8).initComptime("XInputExtension");
                var get_version_msg: [x11.inputext.get_extension_version.getLen(name.len)]u8 = undefined;
                x11.inputext.get_extension_version.serialize(&get_version_msg, msg_ext.major_opcode, name);
                try common.sendOne(sock, sequence, &get_version_msg);
                state.disable_input_device = .{ .get_version = .{
                    .sequence = sequence.*,
                    .ext_opcode = msg_ext.major_opcode,
                } };
            }
            return true; // handled
        },
        .get_version => |info| if (msg.sequence == info.sequence) {
            const opcode = msg.flexible;
            const ptr: [*]const u8 = &msg.reserve_min;
            const major = x11.readIntNative(u16, ptr + 0);
            const minor = x11.readIntNative(u16, ptr + 2);
            const present = msg.reserve_min[4];
            if (opcode != @intFromEnum(x11.inputext.ExtOpcode.get_extension_version))
                std.debug.panic("invalid opcode in reply {}, expected {}", .{ opcode, @intFromEnum(x11.inputext.ExtOpcode.get_extension_version) });
            if (present == 0)
                std.debug.panic("XInputExtension is not present, but it was before?", .{});
            if (major != 2)
                std.debug.panic("XInputExtension major version is {} but need {}", .{ major, 2 });
            if (minor < 3)
                std.debug.panic("XInputExtension minor version is {} but I've only tested >= {}", .{ minor, 3 });
            var list_devices_msg: [x11.inputext.list_input_devices.len]u8 = undefined;
            x11.inputext.list_input_devices.serialize(&list_devices_msg, info.ext_opcode);
            try common.sendOne(sock, sequence, &list_devices_msg);
            state.disable_input_device = .{ .list_devices = .{
                .sequence = sequence.*,
                .ext_opcode = info.ext_opcode,
            } };
            return true; // handled
        },
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
                std.log.info("Device {} '{s}', type={}, use={s}:", .{ device.id, name, device.device_type, @tagName(device.use) });
                var info_index: u8 = 0;
                while (info_index < device.class_count) : (info_index += 1) {
                    std.log.info("  Input: {}", .{input_info_it.front()});
                    input_info_it.pop();
                }
            }
            std.debug.assert((try names_it.next()) == null);

            if (selected_pointer_id) |pointer_id| {
                const name = comptime x11.Slice(u16, [*]const u8).initComptime("Device Enabled");
                var intern_atom_msg: [x11.intern_atom.getLen(name.len)]u8 = undefined;
                x11.intern_atom.serialize(&intern_atom_msg, .{
                    .only_if_exists = false,
                    .name = name,
                });
                try common.sendOne(sock, sequence, &intern_atom_msg);
                state.disable_input_device = .{ .intern_atom = .{
                    .sequence = sequence.*,
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
            var get_prop_msg: [x11.inputext.get_property.len]u8 = undefined;
            x11.inputext.get_property.serialize(&get_prop_msg, info.ext_opcode, .{
                .device_id = info.pointer_id,
                .property = atom,
                .type = 0,
                .offset = 0,
                .len = 0,
                .delete = false,
            });
            try common.sendOne(sock, sequence, &get_prop_msg);
            state.disable_input_device = .{ .get_prop = .{
                .sequence = sequence.*,
                .ext_opcode = info.ext_opcode,
                .pointer_id = info.pointer_id,
                .atom = atom,
            } };
            return true;
        },
        .get_prop => |info| if (msg.sequence == info.sequence) {
            const reply: *const x11.inputext.get_property.Reply = @ptrCast(msg);
            std.log.info("get_property returned {}", .{reply});

            const change_prop_u8 = x11.inputext.change_property.withFormat(u8);
            var change_prop_msg: [change_prop_u8.getLen(1)]u8 = undefined;
            change_prop_u8.serialize(&change_prop_msg, info.ext_opcode, .{
                .device_id = info.pointer_id,
                .mode = .replace,
                .property = info.atom,
                .type = @intFromEnum(x11.Atom.INTEGER),
                .values = x11.Slice(u16, [*]const u8).initComptime(&[_]u8{0}),
            });
            try common.sendOne(sock, sequence, &change_prop_msg);
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

fn warpPointer(sock: std.posix.socket_t, sequence: *u16) !void {
    std.log.info("warping pointer 20 x 10...", .{});
    var msg: [x11.warp_pointer.len]u8 = undefined;
    x11.warp_pointer.serialize(&msg, .{
        .src_window = .none,
        .dst_window = .none,
        .src_x = 0,
        .src_y = 0,
        .src_width = 0,
        .src_height = 0,
        .dst_x = 20,
        .dst_y = 10,
    });
    try common.sendOne(sock, sequence, &msg);
}

const WmProtocolAtoms = struct {
    WM_PROTOCOLS: u32,
    WM_DELETE_WINDOW: u32,
};

fn createWindow(
    sock: std.posix.socket_t,
    sequence: *u16,
    parent_window_id: x11.Window,
    window_id: x11.Window,
    wm_protocol_atoms: WmProtocolAtoms,
) !void {
    {
        var msg_buf: [x11.create_window.max_len]u8 = undefined;
        const len = x11.create_window.serialize(&msg_buf, .{
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
            //            .bg_pixmap = .copy_from_parent,
            //            .bg_pixel = bg_color,
            //            //.border_pixmap =
            //            .border_pixel = 0x01fa8ec9,
            //            .bit_gravity = .north_west,
            //            .win_gravity = .east,
            //            .backing_store = .when_mapped,
            //            .backing_planes = 0x1234,
            //            .backing_pixel = 0xbbeeeeff,
            //            .override_redirect = true,
            //            .save_under = true,
            //            .event_mask =
            //                  x11.event.key_press
            //                | x11.event.key_release
            //                | x11.event.button_press
            //                | x11.event.button_release
            //                | x11.event.enter_window
            //                | x11.event.leave_window
            //                | x11.event.pointer_motion
            ////                | x11.event.pointer_motion_hint WHAT THIS DO?
            ////                | x11.event.button1_motion  WHAT THIS DO?
            ////                | x11.event.button2_motion  WHAT THIS DO?
            ////                | x11.event.button3_motion  WHAT THIS DO?
            ////                | x11.event.button4_motion  WHAT THIS DO?
            ////                | x11.event.button5_motion  WHAT THIS DO?
            ////                | x11.event.button_motion  WHAT THIS DO?
            //                | x11.event.keymap_state
            //                | x11.event.exposure
            //                ,
            ////            .dont_propagate = 1,
        });
        try common.sendOne(sock, sequence, msg_buf[0..len]);
    }

    try setupWmProtocols(sock, sequence, window_id, wm_protocol_atoms);

    {
        var msg: [x11.map_window.len]u8 = undefined;
        x11.map_window.serialize(&msg, window_id);
        try common.sendOne(sock, sequence, &msg);
    }
}

fn destroyWindow(sock: std.posix.socket_t, sequence: *u16, window_id: x11.Window) !void {
    var msg: [x11.destroy_window.len]u8 = undefined;
    x11.destroy_window.serialize(&msg, window_id);
    try common.sendOne(sock, sequence, &msg);
}

fn disableInputDevice(sock: std.posix.socket_t, sequence: *u16, state: *State) !void {
    const already_fmt = "disable input device already requested, {s}...";
    switch (state.disable_input_device) {
        .initial, .no_pointer_to_disable => {
            const name = comptime x11.Slice(u16, [*]const u8).initComptime("XInputExtension");
            var msg: [x11.query_extension.getLen(name.len)]u8 = undefined;
            x11.query_extension.serialize(&msg, name);
            try common.sendOne(sock, sequence, &msg);
            state.disable_input_device = .{ .query_extension = sequence.* };
        },
        .query_extension => std.log.info(already_fmt, .{"querying extension"}),
        .extension_missing => std.log.info("can't disable input device, XInputExtension is missing", .{}),
        .get_version => std.log.info(already_fmt, .{"getting extension version"}),
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
    disable_input_device: union(enum) {
        initial: void,
        query_extension: u16,
        extension_missing: void,
        get_version: struct {
            sequence: u16,
            ext_opcode: u8,
        },
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

    fn toggleGrab(self: *State, sock: std.posix.socket_t, sequence: *u16, grab_window: x11.Window) !void {
        switch (self.grab) {
            .disabled => {
                std.log.info("requesting grab...", .{});
                var msg: [x11.grab_pointer.len]u8 = undefined;
                x11.grab_pointer.serialize(&msg, .{
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
                try common.sendOne(sock, sequence, &msg);
                self.grab = .{ .requested = .{
                    .confined = self.confine_grab,
                    .sequence = sequence.*,
                } };
            },
            .requested => {
                std.log.info("grab already requested", .{});
            },
            .enabled => {
                std.log.info("ungrabbing", .{});
                var msg: [x11.ungrab_pointer.len]u8 = undefined;
                x11.ungrab_pointer.serialize(&msg, .{
                    .time = .current_time,
                });
                try common.sendOne(sock, sequence, &msg);
                self.grab = .disabled;
            },
        }
    }
};

fn renderString(
    sock: std.posix.socket_t,
    sequence: *u16,
    drawable_id: x11.Drawable,
    fg_gc_id: x11.GraphicsContext,
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
        .gc_id = fg_gc_id,
        .x = pos_x,
        .y = pos_y,
    });
    try common.sendOne(sock, sequence, msg[0..x11.image_text8.getLen(text_len)]);
}

fn render(
    sock: std.posix.socket_t,
    sequence: *u16,
    window_id: x11.Window,
    bg_gc_id: x11.GraphicsContext,
    fg_gc_id: x11.GraphicsContext,
    font_dims: FontDims,
    state: State,
) !void {
    _ = bg_gc_id;
    {
        var msg: [x11.clear_area.len]u8 = undefined;
        x11.clear_area.serialize(&msg, false, window_id, .{
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
        });
        try common.sendOne(sock, sequence, &msg);
    }
    try renderString(
        sock,
        sequence,
        window_id.drawable(),
        fg_gc_id,
        font_dims.font_left,
        font_dims.font_ascent + (0 * font_dims.height),
        "root: {} x {}",
        .{
            state.pointer_root_pos.x,
            state.pointer_root_pos.y,
        },
    );
    try renderString(
        sock,
        sequence,
        window_id.drawable(),
        fg_gc_id,
        font_dims.font_left,
        font_dims.font_ascent + (1 * font_dims.height),
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
        sock,
        sequence,
        window_id.drawable(),
        fg_gc_id,
        font_dims.font_left,
        font_dims.font_ascent + (2 * font_dims.height),
        "(G)rab: {s}{s}",
        .{ @tagName(state.grab), grab_suffix },
    );
    try renderString(
        sock,
        sequence,
        window_id.drawable(),
        fg_gc_id,
        font_dims.font_left,
        font_dims.font_ascent + (3 * font_dims.height),
        "(C)onfine Grab: {}",
        .{state.confine_grab},
    );
    try renderString(
        sock,
        sequence,
        window_id.drawable(),
        fg_gc_id,
        font_dims.font_left,
        font_dims.font_ascent + (4 * font_dims.height),
        "(W)arp",
        .{},
    );
    try renderString(
        sock,
        sequence,
        window_id.drawable(),
        fg_gc_id,
        font_dims.font_left,
        font_dims.font_ascent + (5 * font_dims.height),
        "{s} W(i)ndow",
        .{if (state.window_created) "Destroy" else "Create"},
    );
    {
        const suffix: []const u8 = switch (state.disable_input_device) {
            .initial => "",
            .query_extension => " (query extension sent...)",
            .extension_missing => " (XInputExtension is missing)",
            .get_version => " (getting extension version...)",
            .list_devices => " (listing input devices...)",
            .no_pointer_to_disable => " (failed: no pointer to disable)",
            .intern_atom => " (interning atom...)",
            .get_prop => " (getting current property value...)",
            .disabled => " (disabled)",
        };
        try renderString(
            sock,
            sequence,
            window_id.drawable(),
            fg_gc_id,
            font_dims.font_left,
            font_dims.font_ascent + (6 * font_dims.height),
            "(D)isable Input Device{s}",
            .{suffix},
        );
    }
}
