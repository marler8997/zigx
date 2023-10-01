const std = @import("std");
const x = @import("x.zig");
const common = @import("common.zig");

pub const log_level = std.log.Level.info;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 600;
const window_height = 400;

const Ids = struct {
    base: u32,
    pub fn window(self: Ids) u32 { return self.base; }
    pub fn font(self: Ids) u32 { return self.base + 1; }
    pub fn gcBackground(self: Ids) u32 { return self.base + 2; }
    pub fn gcText(self: Ids) u32 { return self.base + 3; }
};

pub fn main() !u8 {
    try x.wsaStartup();
    const conn = try common.connect(allocator);
    defer std.os.shutdown(conn.sock, .both) catch {};

    const Key = enum {
        left, right,
    };
    var keycode_map = std.AutoHashMapUnmanaged(u8, Key){};
    {
        const keymap = try x.keymap.request(allocator, conn.sock, conn.setup.fixed().*);
        defer keymap.deinit(allocator);
        std.log.info("Keymap: syms_per_code={} total_syms={}", .{keymap.syms_per_code, keymap.syms.len});
        {
            var i: usize = 0;
            var sym_offset: usize = 0;
            while (i < keymap.keycode_count) : (i += 1) {
                const keycode: u8 = @intCast(conn.setup.fixed().min_keycode + i);
                var j: usize = 0;
                while (j < keymap.syms_per_code) : (j += 1) {
                    const sym = keymap.syms[sym_offset];
                    if (sym == @intFromEnum(x.charset.Combined.kbd_left)) {
                        std.log.info("keycode {} is left", .{keycode});
                        try keycode_map.put(allocator, keycode, .left);
                    } else if (sym == @intFromEnum(x.charset.Combined.kbd_right)) {
                        std.log.info("keycode {} is right", .{keycode});
                        try keycode_map.put(allocator, keycode, .right);
                    }
                    sym_offset += 1;
                }
            }
        }
    }


    {
        const pattern_string = "*";
        const pattern = x.Slice(u16, [*]const u8) { .ptr = pattern_string, .len = pattern_string.len };
        var msg: [x.list_fonts.getLen(pattern.len)]u8 = undefined;
        x.list_fonts.serialize(&msg, 0xffff, pattern);
        try conn.send(&msg);
    }

    const fonts = blk: {
        const msg_bytes = try x.readOneMsgAlloc(allocator, conn.reader());
        const msg = try common.asReply(x.ServerMsg.ListFonts, msg_bytes);
        const fonts = try allocator.alloc(x.Slice(u8, [*]const u8), msg.string_count);
        var it = msg.iterator();
        var i: usize = 0;
        while (try it.next()) |str| : (i += 1) {
            fonts[i] = str;
        }
        break :blk fonts;
    };
    std.log.info("server has {} fonts", .{fonts.len});

    const screen = blk: {
        const fixed = conn.setup.fixed();
        const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        break :blk conn.setup.getFirstScreenPtr(format_list_limit);
    };

    const ids = Ids { .base = conn.setup.fixed().resource_id_base };

    {
        var msg_buf: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&msg_buf, .{
            .window_id = ids.window(),
            .parent_window_id = screen.root,
            .depth = 0, // don't care, inherit from the parent
            .x = 0, .y = 0,
            .width = window_width, .height = window_height,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
            .bg_pixel = 0xffffff,
            .event_mask =
                  x.event.key_press
                | x.event.exposure
                ,
        });
        try conn.send(msg_buf[0..len]);
    }

    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.gcBackground(),
            .drawable_id = ids.window(),
        }, .{
            .background = 0xffffff,
            .foreground = 0xffffff,
        });
        try conn.send(msg_buf[0..len]);
    }

    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.gcText(),
            .drawable_id = ids.window(),
        }, .{
            .background = 0xffffff,
            .foreground = 0,
        });
        try conn.send(msg_buf[0..len]);
    }

    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, ids.window());
        try conn.send(&msg);
    }

    var state = State{ .desired_font_index = 0, .exposed = .no };

    const double_buf = try x.DoubleBuffer.init(
        // some of the QueryFont replies are huge!
        std.mem.alignForward(usize, 1024 * 1024, std.mem.page_size),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    // double_buf.deinit() (not necessary)
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();

    while (true) {
        {
            const recv_buf = buf.nextReadBuffer();
            if (recv_buf.len == 0) {
                std.log.err("buffer size {} not big enough!", .{buf.half_len});
                return 1;
            }
            const len = try x.readSock(conn.sock, recv_buf, 0);
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
            const msg_len = x.parseMsgLen(data[0..32].*);
            if (data.len < msg_len)
                break;
            buf.release(msg_len);
            switch (x.serverMsgTaggedUnion(@alignCast(data.ptr))) {
                .err => |generic_msg| {
                    var error_handled = false;
                    switch (generic_msg.code) {
                        .name => {
                            const msg: *x.ServerMsg.Error.Name = @ptrCast(generic_msg);
                            if (msg.major_opcode == .open_font) {
                                try state.onOpenFontError(msg);
                                error_handled = true;
                            }
                        },
                        .font => {
                            const msg: *x.ServerMsg.Error.Font = @ptrCast(generic_msg);
                            if (msg.major_opcode == .query_font) {
                                try state.onQueryFontError(msg, conn.sock, ids, fonts);
                                error_handled = true;
                            }
                            if (!error_handled) {
                                std.log.err("{}", .{msg});
                                return 1;
                            }
                        },
                        else => {},
                    }
                    if (!error_handled) {
                        std.log.err("{}", .{generic_msg});
                        return 1;
                    }
                },
                .reply => |msg| {
                    try state.onReply(msg, conn.sock, ids, fonts);
                },
                .key_press => |msg| {
                    std.log.info("key_press: {}", .{msg.keycode});
                    const diff: isize = if (keycode_map.get(msg.keycode)) |key| switch (key) {
                        .left => @as(isize, -1),
                        .right => @as(isize, 1),
                    } else 0;
                    if (diff != 0) {
                        const new_font_index = @mod(@as(isize, @intCast(state.desired_font_index)) + diff, @as(isize, @intCast(fonts.len)));
                        try state.updateDesiredFont(conn.sock, ids, fonts, @intCast(new_font_index));
                    }
                },
                .key_release => {}, // NOTE: still get key_release events even though we didn't ask for them
                .expose => |msg| try state.onExpose(msg, conn.sock, ids, fonts),
                else => {
                    const msg: *x.ServerMsg.Generic = @ptrCast(data.ptr);
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
            }
        }
    }
}

const State = struct {
    desired_font_index: usize,
    exposed: union(enum) {
        no: void,
        yes: union(enum) {
            idle: Idle,
            getting_font: struct {
                still_open: bool,
                font_index: usize,
            },
        },
    },

    const Idle = struct {
        open_font_index: ?usize,
    };

    pub fn onExpose(
        self: *State,
        msg: *x.Event.Expose,
        sock: std.os.socket_t,
        ids: Ids,
        fonts: []x.Slice(u8, [*]const u8),
    ) !void {
        switch (self.exposed) {
            .yes => @panic("not impl"),
            .no => {
                std.log.info("expose: {}", .{msg});
                self.exposed = .{ .yes = .{ .idle = .{ .open_font_index = null } } };
                try self.getDesiredFont(sock, ids, fonts);
            },
        }
    }

    fn getDesiredFont(
        self: *State,
        sock: std.os.socket_t,
        ids: Ids,
        fonts: []x.Slice(u8, [*]const u8),
    ) !void {
       const open_font_index = switch (self.exposed) {
           .no => @panic("codebug"),
           .yes => |*exposed| switch (exposed.*) {
               .getting_font => @panic("codebug"),
               .idle => |info| info.open_font_index,
           },
       };
       if (open_font_index) |_| {
           // TODO: do we need to remove it from the gc??
           var close_msg: [x.close_font.len]u8 = undefined;
           x.close_font.serialize(&close_msg, ids.font());
           try common.send(sock, &close_msg);
       }
       try openAndQueryFont(sock, ids.font(), fonts[self.desired_font_index]);
       self.exposed = .{ .yes = .{ .getting_font = .{ .still_open = true, .font_index = self.desired_font_index } } };
    }

    pub fn onOpenFontError(self: *State, msg: *x.ServerMsg.Error.Name) !void {
        switch (self.exposed) {
            .no => @panic("codebug"),
            .yes => |*exposed| switch (exposed.*) {
                .idle => @panic("codebug"),
                .getting_font => |info| {
                    if (!info.still_open) @panic("unexpected");
                    _ = msg;
                    self.exposed.yes.getting_font.still_open = false;
                },
            },
        }
    }

    pub fn onQueryFontError(self: *State,
        msg: *x.ServerMsg.Error.Font,
        sock: std.os.socket_t,
        ids: Ids,
        fonts: []x.Slice(u8, [*]const u8),
    ) !void {
        switch (self.exposed) {
            .no => @panic("codebug"),
            .yes => |*exposed| switch (exposed.*) {
                .idle => @panic("codebug"),
                .getting_font => |info| {
                    _ = msg;
                    try renderNoFontInfo(sock, ids, fonts, info.font_index, info.still_open);
                    self.exposed = .{ .yes = .{ .idle = .{ .open_font_index = null } } };
                },
            },
        }
    }

    pub fn onReply(
        self: *State,
        reply_msg: *align(4) x.ServerMsg.Reply,
        sock: std.os.socket_t,
        ids: Ids,
        fonts: []x.Slice(u8, [*]const u8),
    ) !void {
        const msg: *x.ServerMsg.QueryFont = @ptrCast(reply_msg);
        //std.log.info("{}", .{msg});
        switch (self.exposed) {
            .no => @panic("codebug"),
            .yes => |*exposed| switch (exposed.*) {
                .idle => @panic("codebug"),
                .getting_font => |info| {
                    if (!info.still_open) @panic("unexpected");
                    try render(sock, ids, fonts, info.font_index, msg);
                    self.exposed = .{ .yes = .{ .idle = .{ .open_font_index = info.font_index } } };
                    try self.atIdleCheckDesiredFont(self.exposed.yes.idle, sock, ids, fonts);
                },
            },
        }
    }

    fn atIdleCheckDesiredFont(
        self: *State,
        idle: Idle,
        sock: std.os.socket_t,
        ids: Ids,
        fonts: []x.Slice(u8, [*]const u8),
    ) !void {
        if ((idle.open_font_index == null) or (idle.open_font_index.? != self.desired_font_index)) {
            try self.getDesiredFont(sock, ids, fonts);
        }
    }

    pub fn updateDesiredFont(
        self: *State,
        sock: std.os.socket_t,
        ids: Ids,
        fonts: []x.Slice(u8, [*]const u8),
        new_desired_font_index: usize,
    ) !void {
        self.desired_font_index = new_desired_font_index;
        switch (self.exposed) {
            .no => {},
            .yes => |*exposed| switch (exposed.*) {
                .idle => |*idle| try self.atIdleCheckDesiredFont(idle.*, sock, ids, fonts),
                .getting_font => {},
            },
        }
    }
};

fn render(sock: std.os.socket_t, ids: Ids, fonts: []x.Slice(u8, [*]const u8), font_index: usize, font_info: *const x.ServerMsg.QueryFont) !void {

    const font_name = fonts[font_index];
    //std.log.info("rendering font '{s}'", .{font_name});

    {
        var msg: [x.poly_fill_rectangle.getLen(1)]u8 = undefined;
        x.poly_fill_rectangle.serialize(&msg, .{
            .drawable_id = ids.window(),
            .gc_id = ids.gcBackground(),
        }, &[_]x.Rectangle {
            .{ .x = 0, .y = 0, .width = window_width, .height = window_height },
        });
        try common.send(sock, &msg);
    }

    {
        var msg_buf: [x.change_gc.max_len]u8 = undefined;
        const len = x.change_gc.serialize(&msg_buf, ids.gcText(), .{
            .font = ids.font(),
        });
        try common.send(sock, msg_buf[0..len]);
    }

    const font_height = font_info.font_ascent + font_info.font_descent;

    try renderText(sock, ids.window(), ids.gcText(), 10, 10 + (font_height * 1), "font {}/{}", .{font_index+1, fonts.len});
    try renderText(sock, ids.window(), ids.gcText(), 10, 10 + (font_height * 2), "{s}", .{font_name});
    try renderText(sock, ids.window(), ids.gcText(), 10, 10 + (font_height * 3), "property_count={} char_info_count={}", .{
        font_info.property_count, font_info.info_count});
    try renderText(sock, ids.window(), ids.gcText(), 10, 10 + (font_height * 4), "The quick brown fox jumped over the lazy dog", .{});
    try renderText(sock, ids.window(), ids.gcText(), 10, 10 + (font_height * 5), "ABCDEFGHIJKLMNOPQRSTUVWXYZ", .{});
    try renderText(sock, ids.window(), ids.gcText(), 10, 10 + (font_height * 6), "abcdefghijklmnopqrstuvwxyz", .{});
}

fn renderNoFontInfo(sock: std.os.socket_t, ids: Ids, fonts: []x.Slice(u8, [*]const u8), font_index: usize, still_open: bool) !void {
    _ = still_open;
    const font_name = fonts[font_index];
    _ = font_name;

    {
        var msg: [x.poly_fill_rectangle.getLen(1)]u8 = undefined;
        x.poly_fill_rectangle.serialize(&msg, .{
            .drawable_id = ids.window(),
            .gc_id = ids.gcBackground(),
        }, &[_]x.Rectangle {
            .{ .x = 0, .y = 0, .width = window_width, .height = window_height },
        });
        try common.send(sock, &msg);
    }

//    {
//        var msg_buf: [x.change_gc.max_len]u8 = undefined;
//        const len = x.change_gc.serialize(&msg_buf, ids.gcText(), .{
//            .font = ids.font(),
//        });
//        try common.send(sock, msg_buf[0..len]);
//    }

    //try renderText(sock, ids.window(), ids.gcText(), 10, 30, "font {}/{}", .{font_index+1, fonts.len});
    //try renderText(sock, ids.window(), ids.gcText(), 10, 60, "{s}", .{font_name});
    //try renderText(sock, ids.window(), ids.gcText(), 10, 90, "Failed to query font info", .{});
}

fn renderText(sock: std.os.socket_t, drawable_id: u32, gc_id: u32, x_coord: i16, y: i16, comptime fmt: []const u8, args: anytype) !void {
    const str_len_u64 = std.fmt.count(fmt, args);
    const str_len = std.math.cast(u8, str_len_u64) orelse
        std.debug.panic("render large string {} not implemented", .{str_len_u64});
    
    const msg_len = x.image_text8.getLen(str_len);
    const msg = try allocator.alloc(u8, msg_len);
    defer allocator.free(msg);
    x.image_text8.serializeNoTextCopy(msg.ptr, str_len, .{
        .drawable_id = drawable_id,
        .gc_id = gc_id,
        .x = x_coord, .y = y,
    });
    const final_len = (std.fmt.bufPrint((msg.ptr + x.image_text8.text_offset)[0 .. str_len], fmt, args) catch unreachable).len;
    std.debug.assert(final_len == str_len);
    try common.send(sock, msg);
}

fn openAndQueryFont(sock: std.os.socket_t, font_id: u32, font_name: x.Slice(u8, [*]const u8)) !void {
    // TODO: combine these into 1 send
    std.log.info("open and query '{s}'", .{font_name});
    {
        const msg = try allocator.alloc(u8, x.open_font.getLen(font_name.len));
        defer allocator.free(msg);
        x.open_font.serialize(msg.ptr, font_id, font_name.lenCast(u16));
        try common.send(sock, msg);
    }
    {
        var msg: [x.query_font.len]u8 = undefined;
        x.query_font.serialize(&msg, font_id);
        try common.send(sock, &msg);
    }
}
