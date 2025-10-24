const std = @import("std");
const x11 = @import("x11");

pub const log_level = std.log.Level.info;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 600;
const window_height = 400;

const Ids = struct {
    base: x11.ResourceBase,

    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn font(self: Ids) x11.Font {
        return self.base.add(1).font();
    }
    pub fn gcBackground(self: Ids) x11.GraphicsContext {
        return self.base.add(2).graphicsContext();
    }
    pub fn gcText(self: Ids) x11.GraphicsContext {
        return self.base.add(3).graphicsContext();
    }
};

pub fn main() !u8 {
    try x11.wsaStartup();

    const display = try x11.getDisplay();
    std.log.info("DISPLAY {f}", .{display});
    const parsed_display = x11.parseDisplay(display) catch |err| {
        std.log.err("invalid DISPLAY {f}: {s}", .{ display, @errorName(err) });
        std.process.exit(0xff);
    };
    const address = try x11.getAddress(display, &parsed_display);
    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var io = x11.connect(address, &write_buffer, &read_buffer) catch |err| {
        std.log.err("connect to {f} failed with {s}", .{ address, @errorName(err) });
        std.process.exit(0xff);
    };
    defer io.shutdown(); // no need to close as well
    std.log.info("connected to {f}", .{address});
    try x11.ext.authenticate(display, parsed_display, address, &io);
    var sink: x11.RequestSink = .{ .writer = &io.socket_writer.interface };
    var source: x11.Source = .{ .reader = io.socket_reader.interface() };
    const setup = try source.readSetup();
    std.log.info("setup reply {f}", .{setup});
    const screen = try x11.ext.readSetupDynamic(&source, &setup, .{}) orelse {
        std.log.err("no screen?", .{});
        std.process.exit(0xff);
    };

    const Key = enum {
        left,
        right,
    };
    var keycode_map = std.AutoHashMapUnmanaged(u8, Key){};

    {
        var it = try x11.synchronousGetKeyboardMapping(&sink, &source, try .init(
            setup.min_keycode,
            setup.max_keycode,
        ));
        for (setup.min_keycode..@as(usize, setup.max_keycode) + 1) |keycode| {
            for (try it.readSyms(&source)) |sym| switch (sym) {
                .kbd_left => {
                    std.log.info("keycode {} is left", .{keycode});
                    try keycode_map.put(allocator, @intCast(keycode), .left);
                },
                .kbd_right => {
                    std.log.info("keycode {} is right", .{keycode});
                    try keycode_map.put(allocator, @intCast(keycode), .right);
                },
                else => {},
            };
        }
    }

    try sink.ListFonts(0xffff, .initComptime("*"));
    try sink.writer.flush();
    const fonts = blk: {
        const list, _ = try source.readSynchronousReplyHeader(sink.sequence, .ListFonts);
        std.log.info("font count {}", .{list.count});
        const remaining_size = source.replyRemainingSize();
        const font_mem = try allocator.alloc(u8, remaining_size);
        try source.readReply(font_mem);
        const fonts = try allocator.alloc(x11.Slice(u8, [*]const u8), list.count);
        var font_mem_index: u34 = 0;
        for (fonts.ptr[0..list.count]) |*font| {
            if (font_mem_index == font_mem.len) @panic("fonts truncated");
            const len = font_mem[font_mem_index];
            font_mem_index += 1;
            if (font_mem_index + len > font_mem.len) @panic("fonts truncated");
            font.* = .initAssume(font_mem[font_mem_index..][0..len]);
            font_mem_index += len;
        }
        break :blk fonts;
    };

    const ids = Ids{ .base = setup.resource_id_base };

    try sink.CreateWindow(.{
        .window_id = ids.window(),
        .parent_window_id = screen.root,
        .depth = 0,
        .x = 0,
        .y = 0,
        .width = window_width,
        .height = window_height,
        .border_width = 0, // TODO: what is this?
        .class = .input_output,
        .visual_id = screen.root_visual,
    }, .{
        .bg_pixel = 0xffffff,
        .event_mask = .{ .KeyPress = 1, .Exposure = 1 },
    });

    try sink.CreateGc(
        ids.gcBackground(),
        ids.window().drawable(),
        .{
            .background = x11.rgbFrom24(screen.root_depth, 0xffffff),
            .foreground = x11.rgbFrom24(screen.root_depth, 0xffffff),
        },
    );
    try sink.CreateGc(
        ids.gcText(),
        ids.window().drawable(),
        .{
            .background = x11.rgbFrom24(screen.root_depth, 0xffffff),
            .foreground = x11.rgbFrom24(screen.root_depth, 0),
        },
    );

    try sink.MapWindow(ids.window());

    var state = State{ .desired_font_index = 0, .exposed = .no };

    while (true) {
        try sink.writer.flush();
        const msg_kind = source.readKind() catch |err| return switch (err) {
            error.EndOfStream => {
                std.log.info("X11 connection closed (EndOfStream)", .{});
                std.process.exit(0);
            },
            else => |e| switch (io.socket_reader.getError() orelse e) {
                error.ConnectionResetByPeer => {
                    std.log.info("X11 connection closed (ConnectionReset)", .{});
                    return std.process.exit(0);
                },
                else => |e2| e2,
            },
        };
        switch (msg_kind) {
            .Error => {
                const err = try source.read2(.Error);
                var error_handled = false;
                switch (err.code) {
                    .name => {
                        if (err.major_opcode == .open_font) {
                            try state.onOpenFontError(&err);
                            error_handled = true;
                        }
                    },
                    .font => {
                        if (err.major_opcode == .query_font) {
                            try state.onQueryFontError(&err, &sink, ids, fonts);
                            error_handled = true;
                        }
                    },
                    else => {},
                }
                if (!error_handled) std.debug.panic("X11 {f}", .{err});
            },
            .Reply => try state.onReply(&source, &sink, ids, fonts),
            .KeyPress => {
                const event = try source.read2(.KeyPress);
                const diff: isize = if (keycode_map.get(event.keycode)) |key| switch (key) {
                    .left => @as(isize, -1),
                    .right => @as(isize, 1),
                } else 0;
                if (diff != 0) {
                    const new_font_index = @mod(@as(isize, @intCast(state.desired_font_index)) + diff, @as(isize, @intCast(fonts.len)));
                    try state.updateDesiredFont(&sink, ids, fonts, @intCast(new_font_index));
                }
            },
            // NOTE: server will send us KeyRelease when the user holds down a key
            //       even though we didn't register for the KeyRelease event
            .KeyRelease => _ = try source.discardRemaining(),
            .Expose => {
                const expose = try source.read2(.Expose);
                std.log.info("X11 {}", .{expose});
                try state.onExpose(&expose, &sink, ids, fonts);
            },
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
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
                query_sequence: u16,
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
        msg: *const x11.servermsg.Expose,
        sink: *x11.RequestSink,
        ids: Ids,
        fonts: []x11.Slice(u8, [*]const u8),
    ) !void {
        switch (self.exposed) {
            .yes => {},
            .no => {
                std.log.info("expose: {}", .{msg});
                self.exposed = .{ .yes = .{ .idle = .{ .open_font_index = null } } };
                try self.getDesiredFont(sink, ids, fonts);
            },
        }
    }

    fn getDesiredFont(
        self: *State,
        sink: *x11.RequestSink,
        ids: Ids,
        fonts: []x11.Slice(u8, [*]const u8),
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
            try sink.CloseFont(ids.font());
        }
        try openAndQueryFont(sink, ids.font(), fonts[self.desired_font_index]);
        self.exposed = .{ .yes = .{ .getting_font = .{
            .query_sequence = sink.sequence,
            .still_open = true,
            .font_index = self.desired_font_index,
        } } };
    }

    pub fn onOpenFontError(self: *State, err: *const x11.servermsg.Error) !void {
        switch (self.exposed) {
            .no => @panic("codebug"),
            .yes => |*exposed| switch (exposed.*) {
                .idle => @panic("codebug"),
                .getting_font => |info| {
                    if (!info.still_open) @panic("unexpected");
                    _ = err;
                    self.exposed.yes.getting_font.still_open = false;
                },
            },
        }
    }

    pub fn onQueryFontError(
        self: *State,
        err: *const x11.servermsg.Error,
        sink: *x11.RequestSink,
        ids: Ids,
        fonts: []x11.Slice(u8, [*]const u8),
    ) !void {
        switch (self.exposed) {
            .no => @panic("codebug"),
            .yes => |*exposed| switch (exposed.*) {
                .idle => @panic("codebug"),
                .getting_font => |info| {
                    _ = err;
                    try renderNoFontInfo(sink, ids, fonts, info.font_index, info.still_open);
                    self.exposed = .{ .yes = .{ .idle = .{ .open_font_index = null } } };
                },
            },
        }
    }

    pub fn onReply(
        self: *State,
        source: *x11.Source,
        sink: *x11.RequestSink,
        ids: Ids,
        fonts: []x11.Slice(u8, [*]const u8),
    ) !void {
        const reply = try source.read2(.Reply);
        switch (self.exposed) {
            .no => @panic("codebug"),
            .yes => |*exposed| switch (exposed.*) {
                .idle => @panic("codebug"),
                .getting_font => |info| {
                    if (reply.sequence != info.query_sequence) std.debug.panic(
                        "expected sequence {} but got {f}",
                        .{ info.query_sequence, source.readFmt() },
                    );
                    if (!info.still_open) @panic("unexpected");
                    const font = try source.read3Header(.QueryFont);
                    const msg_remaining_size = x11.stage3.QueryFont.remainingSize(reply.word_count);
                    const required_remaining_size: u35 =
                        (@as(u35, font.property_count) * @sizeOf(x11.FontProp)) +
                        (@as(u35, font.info_count) * @sizeOf(x11.CharInfo));
                    if (required_remaining_size > msg_remaining_size) std.debug.panic(
                        "msg size is {} but fields require {}",
                        .{ msg_remaining_size, required_remaining_size },
                    );
                    try source.replyDiscard(msg_remaining_size);
                    const font_info: FontInfo = .{
                        .font_ascent = font.font_ascent,
                        .font_descent = font.font_descent,
                        .property_count = font.property_count,
                        .info_count = font.info_count,
                    };
                    try render(sink, ids, fonts, info.font_index, font_info);
                    self.exposed = .{ .yes = .{ .idle = .{ .open_font_index = info.font_index } } };
                    try self.atIdleCheckDesiredFont(self.exposed.yes.idle, sink, ids, fonts);
                },
            },
        }
    }

    fn atIdleCheckDesiredFont(
        self: *State,
        idle: Idle,
        sink: *x11.RequestSink,
        ids: Ids,
        fonts: []x11.Slice(u8, [*]const u8),
    ) !void {
        if ((idle.open_font_index == null) or (idle.open_font_index.? != self.desired_font_index)) {
            try self.getDesiredFont(sink, ids, fonts);
        }
    }

    pub fn updateDesiredFont(
        self: *State,
        sink: *x11.RequestSink,
        ids: Ids,
        fonts: []x11.Slice(u8, [*]const u8),
        new_desired_font_index: usize,
    ) !void {
        self.desired_font_index = new_desired_font_index;
        switch (self.exposed) {
            .no => {},
            .yes => |*exposed| switch (exposed.*) {
                .idle => |*idle| try self.atIdleCheckDesiredFont(idle.*, sink, ids, fonts),
                .getting_font => {},
            },
        }
    }
};

const FontInfo = struct {
    font_ascent: i16,
    font_descent: i16,
    property_count: u16,
    info_count: u32,
};

fn render(
    sink: *x11.RequestSink,
    ids: Ids,
    fonts: []x11.Slice(u8, [*]const u8),
    font_index: usize,
    font_info: FontInfo,
) !void {
    const font_name = fonts[font_index];
    //std.log.info("rendering font '{s}'", .{font_name});

    try sink.PolyFillRectangle(
        ids.window().drawable(),
        ids.gcBackground(),
        .initComptime(&[_]x11.Rectangle{
            .{ .x = 0, .y = 0, .width = window_width, .height = window_height },
        }),
    );

    try sink.ChangeGc(ids.gcText(), .{ .font = ids.font() });

    const font_height = font_info.font_ascent + font_info.font_descent;

    try renderText(sink, ids.window().drawable(), ids.gcText(), .{ .x = 10, .y = 10 + (font_height * 1) }, "font {}/{}", .{ font_index + 1, fonts.len });
    try renderText(sink, ids.window().drawable(), ids.gcText(), .{ .x = 10, .y = 10 + (font_height * 2) }, "{f}", .{font_name});
    try renderText(sink, ids.window().drawable(), ids.gcText(), .{ .x = 10, .y = 10 + (font_height * 3) }, "property_count={} char_info_count={}", .{ font_info.property_count, font_info.info_count });
    try renderText(sink, ids.window().drawable(), ids.gcText(), .{ .x = 10, .y = 10 + (font_height * 4) }, "The quick brown fox jumped over the lazy dog", .{});
    try renderText(sink, ids.window().drawable(), ids.gcText(), .{ .x = 10, .y = 10 + (font_height * 5) }, "ABCDEFGHIJKLMNOPQRSTUVWXYZ", .{});
    try renderText(sink, ids.window().drawable(), ids.gcText(), .{ .x = 10, .y = 10 + (font_height * 6) }, "abcdefghijklmnopqrstuvwxyz", .{});
    try sink.writer.flush();
}

fn renderNoFontInfo(sink: *x11.RequestSink, ids: Ids, fonts: []x11.Slice(u8, [*]const u8), font_index: usize, still_open: bool) !void {
    _ = still_open;
    const font_name = fonts[font_index];
    _ = font_name;

    try sink.PolyFillRectangle(
        ids.window().drawable(),
        ids.gcBackground(),
        .initComptime(&[_]x11.Rectangle{
            .{ .x = 0, .y = 0, .width = window_width, .height = window_height },
        }),
    );

    //    {
    //        var msg_buf: [x11.change_gc.max_len]u8 = undefined;
    //        const len = x11.change_gc.serialize(&msg_buf, ids.gcText(), .{
    //            .font = ids.font(),
    //        });
    //        try x11.ext.send(sock, msg_buf[0..len]);
    //    }

    //try renderText(sock, ids.window(), ids.gcText(), 10, 30, "font {}/{}", .{font_index+1, fonts.len});
    //try renderText(sock, ids.window(), ids.gcText(), 10, 60, "{s}", .{font_name});
    //try renderText(sock, ids.window(), ids.gcText(), 10, 90, "Failed to query font info", .{});
}

fn renderText(
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

fn openAndQueryFont(
    sink: *x11.RequestSink,
    font_id: x11.Font,
    font_name: x11.Slice(u8, [*]const u8),
) !void {
    // TODO: combine these into 1 send
    std.log.info("open and query '{f}'", .{font_name});
    const font_name_slice = x11.Slice(u16, [*]const u8){ .ptr = font_name.ptr, .len = font_name.len };
    try sink.OpenFont(font_id, font_name_slice);
    try sink.QueryFont(font_id.fontable());
}
