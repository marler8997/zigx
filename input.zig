const std = @import("std");
const x = @import("./x.zig");
const common = @import("common.zig");
const Memfd = x.Memfd;
const ContiguousReadBuffer = @import("ContiguousReadBuffer.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 400;
const window_height = 400;

const Key = enum(u8) {
    w = 25,
    g = 42,
    c = 54,
};

const bg_color = 0x231a20;
const fg_color = 0xadccfa;

pub fn main() !u8 {
    const conn = try common.connect(allocator);
    defer std.os.shutdown(conn.sock, .both) catch {};

    const screen = blk: {
        const fixed = conn.setup.fixed();
        inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
            std.log.debug("{s}: {any}", .{field.name, @field(fixed, field.name)});
        }
        std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
        const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        std.log.debug("fmt list off={} limit={}", .{format_list_offset, format_list_limit});
        const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
        for (formats) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{i, format.depth, format.bits_per_pixel, format.scanline_pad});
        }
        var screen = conn.setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{field.name, @field(screen, field.name)});
        }
        break :blk screen;
    };

    // TODO: maybe need to call conn.setup.verify or something?

    const window_id = conn.setup.fixed().resource_id_base;
    {
        var msg_buf: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&msg_buf, .{
            .window_id = window_id,
            .parent_window_id = screen.root,
            .x = 0, .y = 0,
            .width = window_width, .height = window_height,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
//            .bg_pixmap = .copy_from_parent,
            .bg_pixel = bg_color,
//            //.border_pixmap =
//            .border_pixel = 0x01fa8ec9,
//            .bit_gravity = .north_west,
//            .win_gravity = .east,
//            .backing_store = .when_mapped,
//            .backing_planes = 0x1234,
//            .backing_pixel = 0xbbeeeeff,
//            .override_redirect = true,
//            .save_under = true,
            .event_mask =
                  x.event.key_press
                | x.event.key_release
                | x.event.button_press
                | x.event.button_release
                | x.event.enter_window
                | x.event.leave_window
                | x.event.pointer_motion
//                | x.event.pointer_motion_hint WHAT THIS DO?
//                | x.event.button1_motion  WHAT THIS DO?
//                | x.event.button2_motion  WHAT THIS DO?
//                | x.event.button3_motion  WHAT THIS DO?
//                | x.event.button4_motion  WHAT THIS DO?
//                | x.event.button5_motion  WHAT THIS DO?
//                | x.event.button_motion  WHAT THIS DO?
                | x.event.keymap_state
                | x.event.exposure
                ,
//            .dont_propagate = 1,
        });
        try conn.send(msg_buf[0..len]);
    }

    const bg_gc_id = window_id + 1;
    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = bg_gc_id,
            .drawable_id = screen.root,
        }, .{
            .foreground = fg_color,
        });
        try conn.send(msg_buf[0..len]);
    }
    const fg_gc_id = window_id + 2;
    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = fg_gc_id,
            .drawable_id = screen.root,
        }, .{
            .background = bg_color,
            .foreground = fg_color,
        });
        try conn.send(msg_buf[0..len]);
    }

    // get some font information
    {
        const text_literal = [_]u16 { 'm' };
        const text = x.Slice(u16, [*]const u16) { .ptr = &text_literal, .len = text_literal.len };
        var msg: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&msg, fg_gc_id, text);
        try conn.send(&msg);
    }

    const buf_memfd = try Memfd.init("ZigX11DoubleBuffer");
    // no need to deinit
    const buffer_capacity = std.mem.alignForward(1000, std.mem.page_size);
    std.log.info("buffer capacity is {}", .{buffer_capacity});
    var buf = ContiguousReadBuffer { .double_buffer_ptr = try buf_memfd.toDoubleBuffer(buffer_capacity), .half_size = buffer_capacity };

    const font_dims: FontDims = blk: {
        _ = try x.readOneMsg(conn.reader(), @alignCast(4, buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(4, buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg = @ptrCast(*x.ServerMsg.QueryTextExtents, msg_reply);
                break :blk .{
                    .width = @intCast(u8, msg.overall_width),
                    .height = @intCast(u8, msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(i16, msg.overall_left),
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
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, window_id);
        try conn.send(&msg);
    }
    var state = State { };

    while (true) {
        {
            const recv_buf = buf.nextReadBuffer();
            if (recv_buf.len == 0) {
                std.log.err("buffer size {} not big enough!", .{buf.half_size});
                return 1;
            }
            const len = try std.os.recv(conn.sock, recv_buf, 0);
            if (len == 0) {
                std.log.info("X server connection closed", .{});
                return 0;
            }
            buf.reserve(len);
        }
        while (true) {
            const data = buf.nextReservedBuffer();
            const msg_len = x.parseMsgLen(@alignCast(4, data));
            if (msg_len == 0)
                break;
            buf.release(msg_len);
            //buf.resetIfEmpty();
            switch (x.serverMsgTaggedUnion(@alignCast(4, data.ptr))) {
                .err => |msg| {
                    std.log.err("{}", .{msg});
                    return 1;
                },
                .reply => |msg| {
                    switch (state.grab) {
                        .requested => |requested_grab| {
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
                                std.log.info("grab failed with '{s}' ({})", .{error_msg, status});
                                state.grab = .disabled;
                            }
                            try render(conn.sock, window_id, bg_gc_id, fg_gc_id, font_dims, state);
                        },
                        else => {
                            std.log.info("todo: handle a reply message {}", .{msg});
                            return error.TodoHandleReplyMessage;
                        },
                    }
                },
                .key_press => |msg| {
                    std.log.info("key_press: {}", .{msg.detail});
                    var do_render = true;
                    if (msg.detail == @enumToInt(Key.g)) {
                        //try state.toggleGrab(conn.sock, screen.root);
                        try state.toggleGrab(conn.sock, window_id);
                    } else if (msg.detail == @enumToInt(Key.w)) {
                        try warpPointer(conn.sock);
                    } else if (msg.detail == @enumToInt(Key.c)) {
                        state.confine_grab = !state.confine_grab;
                    } else {
                        do_render = false;
                    }

                    if (do_render) {
                        try render(conn.sock, window_id, bg_gc_id, fg_gc_id, font_dims, state);
                    }
                },
                .key_release => |msg| {
                    std.log.info("key_release: {}", .{msg.detail});
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
                    _ = msg;
                    //std.log.info("pointer_motion: {}", .{msg});
                    state.pointer_root_pos.x = msg.root_x;
                    state.pointer_root_pos.y = msg.root_y;
                    state.pointer_event_pos.x = msg.event_x;
                    state.pointer_event_pos.y = msg.event_y;
                    try render(conn.sock, window_id, bg_gc_id, fg_gc_id, font_dims, state);
                },
                .keymap_notify => |msg| {
                    std.log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    try render(conn.sock, window_id, bg_gc_id, fg_gc_id, font_dims, state);
                },
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
            }
        }
    }
}

fn warpPointer(sock: std.os.socket_t) !void {
    std.log.info("warping pointer 20 x 10...", .{});
    var msg: [x.warp_pointer.len]u8 = undefined;
    x.warp_pointer.serialize(&msg, .{
        .src_window = 0,
        .dst_window = 0,
        .src_x = 0,
        .src_y = 0,
        .src_width = 0,
        .src_height = 0,
        .dst_x = 20,
        .dst_y = 10,
    });
    try common.send(sock, &msg);
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
    pointer_root_pos: Pos(i16) = .{ .x = -1, .y = -1},
    pointer_event_pos: Pos(i16) = .{ .x = -1, .y = -1},
    grab: union(enum) {
        disabled: void,
        requested: struct { confined: bool },
        enabled: struct { confined: bool },
    } = .disabled,
    confine_grab: bool = false,

    fn toggleGrab(self: *State, sock: std.os.socket_t, grab_window: u32) !void {
        switch (self.grab) {
            .disabled => {
                std.log.info("requesting grab...", .{});
                var msg: [x.grab_pointer.len]u8 = undefined;
                x.grab_pointer.serialize(&msg, .{
                    .owner_events = true,
                    .grab_window = grab_window,
                    .event_mask = x.pointer_event.pointer_motion,
                    .pointer_mode = .synchronous,
                    .keyboard_mode = .asynchronous,
                    .confine_to = if (self.confine_grab) grab_window else 0,
                    .cursor = 0,
                    .time = 0,
                });
                try common.send(sock, &msg);
                self.grab = .{ .requested = .{ .confined = self.confine_grab } };
            },
            .requested => {
                std.log.info("grab already requested", .{});
            },
            .enabled => {
                std.log.info("ungrabbing", .{});
                var msg: [x.ungrab_pointer.len]u8 = undefined;
                x.ungrab_pointer.serialize(&msg, .{
                    .time = 0,
                });
                try common.send(sock, &msg);
                self.grab = .disabled;
            },
        }
    }
};

fn renderString(
    sock: std.os.socket_t,
    drawable_id: u32,
    fg_gc_id: u32,
    pos_x: i16,
    pos_y: i16,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var msg: [x.image_text8.max_len]u8 = undefined;
    const text_buf = msg[x.image_text8.text_offset .. x.image_text8.text_offset + 0xff];
    const text_len = @intCast(u8, (std.fmt.bufPrint(text_buf, fmt, args) catch @panic("string too long")).len);
    x.image_text8.serializeNoTextCopy(&msg, .{
        .drawable_id = drawable_id,
        .gc_id = fg_gc_id,
        .x = pos_x,
        .y = pos_y,
        .text = x.Slice(u8, [*]const u8) { .ptr = undefined, .len = text_len },
    });
    try common.send(sock, msg[0 .. x.image_text8.getLen(text_len)]);
}

fn render(
    sock: std.os.socket_t,
    drawable_id: u32,
    bg_gc_id: u32,
    fg_gc_id: u32,
    font_dims: FontDims,
    state: State,
) !void {
    _ = bg_gc_id;
    {
        var msg: [x.clear_area.len]u8 = undefined;
        x.clear_area.serialize(&msg, false, drawable_id, .{
            .x = 0, .y = 0, .width = window_width, .height = window_height,
        });
        try common.send(sock, &msg);
    }
    try renderString(
        sock,
        drawable_id,
        fg_gc_id,
        font_dims.font_left,
        font_dims.font_ascent + (0 * font_dims.height),
        "root: {} x {}", .{
            state.pointer_root_pos.x,
            state.pointer_root_pos.y,
        },
    );
    try renderString(
        sock,
        drawable_id,
        fg_gc_id,
        font_dims.font_left,
        font_dims.font_ascent + (1 * font_dims.height),
        "event: {} x {}", .{
            state.pointer_event_pos.x,
            state.pointer_event_pos.y,
        },
    );
    const grab_suffix: []const u8 = switch (state.grab) {
        .disabled => "",
        .requested => |c| if (c.confined) " confined=true" else " confined=false",
        .enabled   => |c| if (c.confined) " confined=true" else " confined=false",
    };
    try renderString(
        sock,
        drawable_id,
        fg_gc_id,
        font_dims.font_left,
        font_dims.font_ascent + (2 * font_dims.height),
        "(G)rab: {s}{s}", .{ @tagName(state.grab), grab_suffix },
    );
    try renderString(
        sock,
        drawable_id,
        fg_gc_id,
        font_dims.font_left,
        font_dims.font_ascent + (3 * font_dims.height),
        "(C)onfine Grab: {}", .{ state.confine_grab },
    );
    try renderString(
        sock,
        drawable_id,
        fg_gc_id,
        font_dims.font_left,
        font_dims.font_ascent + (4 * font_dims.height),
        "(W)arp", .{},
    );
}
