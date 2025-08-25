const window_width = 400;
const window_height = 400;

// const Key = enum {
//     f, // faster
//     s, // slower
//     d, // toggle double buffering
// };

const Ids = struct {
    base: x11.ResourceBase,
    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.base.add(1).graphicsContext();
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

    {
        var msg: [x11.map_window.len]u8 = undefined;
        x11.map_window.serialize(&msg, ids.window());
        try conn.sendOne(&sequence, &msg);
    }

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
                    // var do_render = true;
                    // if (keycode_map.get(msg.keycode)) |key| switch (key) {
                    //     .f => {
                    //         if (animate_frame_ms > 1) {
                    //             animate_frame_ms -= 1;
                    //         }
                    //     },
                    //     .s => animate_frame_ms += 1,
                    //     .d => switch (dbe) {
                    //         .unsupported => {},
                    //         .disabled => |disabled| {
                    //             try allocateBackBuffer(
                    //                 conn.sock,
                    //                 &sequence,
                    //                 disabled.opcode,
                    //                 ids.window(),
                    //                 ids.backBuffer(),
                    //             );
                    //             dbe = .{ .enabled = .{
                    //                 .opcode = disabled.opcode,
                    //                 .back_buffer = ids.backBuffer(),
                    //             } };
                    //         },
                    //         .enabled => |enabled| {
                    //             try deallocateBackBuffer(
                    //                 conn.sock,
                    //                 &sequence,
                    //                 enabled.opcode,
                    //                 ids.backBuffer(),
                    //             );
                    //             dbe = .{ .disabled = .{ .opcode = enabled.opcode } };
                    //         },
                    //     },
                    // } else {
                    std.log.info("key_press: {}", .{msg.keycode});
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

fn render(
    sock: std.posix.socket_t,
    sequence: *u16,
    window: x11.Window,
    gc_id: x11.GraphicsContext,
) !void {
    {
        var msg: [x11.clear_area.len]u8 = undefined;
        x11.clear_area.serialize(&msg, false, window, .{
            .x = 150,
            .y = 150,
            .width = 100,
            .height = 100,
        });
        try common.sendOne(sock, sequence, &msg);
    }
    {
        const text_literal: []const u8 = "Hello X!";
        const text = x11.Slice(u8, [*]const u8){ .ptr = text_literal.ptr, .len = text_literal.len };
        var msg: [x11.image_text8.getLen(text.len)]u8 = undefined;

        // const text_width = font_dims.width * text_literal.len;

        x11.image_text8.serialize(&msg, text, .{
            .drawable_id = window.drawable(),
            .gc_id = gc_id,
            .x = 10,
            .y = 30,
        });
        try common.sendOne(sock, sequence, &msg);
    }
}

// fn renderString(
//     sock: std.posix.socket_t,
//     sequence: *u16,
//     drawable_id: x11.Drawable,
//     gc_id: x11.GraphicsContext,
//     pos_x: i16,
//     pos_y: i16,
//     comptime fmt: []const u8,
//     args: anytype,
// ) !void {
//     var msg: [x11.image_text8.max_len]u8 = undefined;
//     const text_buf = msg[x11.image_text8.text_offset .. x11.image_text8.text_offset + 0xff];
//     const text_len: u8 = @intCast((std.fmt.bufPrint(text_buf, fmt, args) catch @panic("string too long")).len);
//     x11.image_text8.serializeNoTextCopy(&msg, text_len, .{
//         .drawable_id = drawable_id,
//         .gc_id = gc_id,
//         .x = pos_x,
//         .y = pos_y,
//     });
//     try common.sendOne(sock, sequence, msg[0..x11.image_text8.getLen(text_len)]);
// }

const std = @import("std");
const x11 = @import("x11");
const common = @import("common.zig");
