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
    const display = x11.getDisplay();
    const parsed_display = x11.parseDisplay(display) catch |err| {
        std.log.err("invalid display '{s}': {s}", .{ display, @errorName(err) });
        std.process.exit(0xff);
    };

    const stream = x11.connect(display, parsed_display) catch |err| {
        std.log.err("failed to connect to display '{s}': {s}", .{ display, @errorName(err) });
        std.process.exit(0xff);
    };
    defer std.posix.shutdown(stream.handle, .both) catch {};

    var write_buf: [1000]u8 = undefined;
    var read_buf: [1000]u8 = undefined;
    var socket_writer = x11.socketWriter(stream, &write_buf);
    var socket_reader = x11.socketReader(stream, &read_buf);
    const writer = &socket_writer.interface;
    const reader = socket_reader.interface();

    const reply_len = switch (try x11.ext.authenticate(writer, reader, .{
        .display_num = parsed_display.display_num,
        .socket = stream.handle,
    })) {
        .failed => |reason| {
            x11.log.err("auth failed: {f}", .{reason});
            std.process.exit(0xff);
        },
        .success => |reply_len| reply_len,
    };
    const fixed = try x11.ext.readConnectSetupFixed(reader);
    std.log.info("fixed is {}", .{fixed});
    const screen = try x11.ext.readConnectSetupDynamic(reader, reply_len, &fixed) orelse {
        std.log.err("no screen?", .{});
        std.process.exit(0xff);
    };

    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };

    const Key = enum {
        left,
        right,
    };
    var keycode_map = std.AutoHashMapUnmanaged(u8, Key){};
    {
        const keymap = try x11.keymap.request(allocator, &sink, reader, &fixed);
        defer keymap.deinit(allocator);
        std.log.info("Keymap: syms_per_code={} total_syms={}", .{ keymap.syms_per_code, keymap.syms.len });
        {
            var i: usize = 0;
            var sym_offset: usize = 0;
            while (i < keymap.keycode_count) : (i += 1) {
                const keycode: u8 = @intCast(fixed.min_keycode + i);
                var j: usize = 0;
                while (j < keymap.syms_per_code) : (j += 1) {
                    const sym = keymap.syms[sym_offset];
                    if (sym == @intFromEnum(x11.charset.Combined.kbd_left)) {
                        std.log.info("keycode {} is left", .{keycode});
                        try keycode_map.put(allocator, keycode, .left);
                    } else if (sym == @intFromEnum(x11.charset.Combined.kbd_right)) {
                        std.log.info("keycode {} is right", .{keycode});
                        try keycode_map.put(allocator, keycode, .right);
                    }
                    sym_offset += 1;
                }
            }
        }
    }

    try sink.ListFonts(0xffff, .initComptime("*"));
    const list_fonts_sequence = sink.sequence;
    try sink.writer.flush();

    const fonts = blk: {
        const msg1 = try x11.read1(reader);
        if (msg1.kind != .Reply) std.debug.panic(
            "expected Reply but got {f}",
            .{msg1.readFmt(reader)},
        );
        const reply = try msg1.read2(.Reply, reader);
        if (reply.sequence != list_fonts_sequence) std.debug.panic(
            "expected sequence {} but got {f}",
            .{ list_fonts_sequence, reply.readFmt(reader) },
        );
        const list = try x11.read3(.ListFonts, reader);
        const font_mem = try allocator.alloc(u8, reply.bodySize());
        try reader.readSliceAll(font_mem);
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

    const ids = Ids{ .base = fixed.resource_id_base };

    try sink.CreateWindow(.{
        .window_id = ids.window(),
        .parent_window_id = screen.root,
        .depth = 0, // don't care, inherit from the parent
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
            .background = 0xffffff,
            .foreground = 0xffffff,
        },
    );
    try sink.CreateGc(
        ids.gcText(),
        ids.window().drawable(),
        .{
            .background = 0xffffff,
            .foreground = 0,
        },
    );

    try sink.MapWindow(ids.window());

    var state = State{ .desired_font_index = 0, .exposed = .no };

    while (true) {
        try sink.writer.flush();
        const msg1 = x11.read1(reader) catch |err| switch (err) {
            error.EndOfStream => {
                std.log.info("X11 connection closed", .{});
                return std.process.exit(0);
            },
            error.ReadFailed => |e| return socket_reader.getError() orelse e,
        };
        switch (msg1.kind) {
            .Error => {
                const err = try msg1.read2(.Error, reader);
                std.debug.panic("{}", .{err});
            },
            .Reply => try state.onReply(reader, &sink, ids, fonts),
            .KeyPress => {
                const event = try msg1.read2(.KeyPress, reader);
                const diff: isize = if (keycode_map.get(event.keycode)) |key| switch (key) {
                    .left => @as(isize, -1),
                    .right => @as(isize, 1),
                } else 0;
                if (diff != 0) {
                    const new_font_index = @mod(@as(isize, @intCast(state.desired_font_index)) + diff, @as(isize, @intCast(fonts.len)));
                    try state.updateDesiredFont(&sink, ids, fonts, @intCast(new_font_index));
                }
            },
            .KeyRelease => try msg1.discard2(reader), // NOTE: still get key_release events even though we didn't ask for them
            .Expose => {
                const expose = try msg1.read2(.Expose, reader);
                std.log.info("{}", .{expose});
                try state.onExpose(&expose, &sink, ids, fonts);
            },
            else => std.debug.panic("unexpected message {f}", .{msg1.readFmt(reader)}),
        }

        // switch (x11.serverMsgTaggedUnion(@alignCast(data.ptr))) {
        //     .err => |generic_msg| {
        //         var error_handled = false;
        //         switch (generic_msg.code) {
        //             .name => {
        //                 const msg: *x11.ServerMsg.Error.Name = @ptrCast(generic_msg);
        //                 if (msg.major_opcode == .open_font) {
        //                     try state.onOpenFontError(msg);
        //                     error_handled = true;
        //                 }
        //             },
        //             .font => {
        //                 const msg: *x11.ServerMsg.Error.FontError = @ptrCast(generic_msg);
        //                 if (msg.major_opcode == .query_font) {
        //                     try state.onQueryFontError(msg, &sink, ids, fonts);
        //                     error_handled = true;
        //                 }
        //                 if (!error_handled) {
        //                     std.log.err("{}", .{msg});
        //                     return 1;
        //                 }
        //             },
        //             else => {},
        //         }
        //         if (!error_handled) {
        //             std.log.err("{f}", .{generic_msg});
        //             return 1;
        //         }
        //     },
        // }
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
        msg: *const x11.ServerMsg1.Expose,
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

    pub fn onOpenFontError(self: *State, msg: *x11.ServerMsg.Error.Name) !void {
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

    pub fn onQueryFontError(
        self: *State,
        msg: *x11.ServerMsg.Error.FontError,
        sink: *x11.RequestSink,
        ids: Ids,
        fonts: []x11.Slice(u8, [*]const u8),
    ) !void {
        switch (self.exposed) {
            .no => @panic("codebug"),
            .yes => |*exposed| switch (exposed.*) {
                .idle => @panic("codebug"),
                .getting_font => |info| {
                    _ = msg;
                    try renderNoFontInfo(sink, ids, fonts, info.font_index, info.still_open);
                    self.exposed = .{ .yes = .{ .idle = .{ .open_font_index = null } } };
                },
            },
        }
    }

    pub fn onReply(
        self: *State,
        reader: *x11.Reader,
        sink: *x11.RequestSink,
        ids: Ids,
        fonts: []x11.Slice(u8, [*]const u8),
    ) !void {
        const reply = try (x11.ServerMsg1{ .kind = .Reply }).read2(.Reply, reader);
        switch (self.exposed) {
            .no => @panic("codebug"),
            .yes => |*exposed| switch (exposed.*) {
                .idle => @panic("codebug"),
                .getting_font => |info| {
                    if (reply.sequence != info.query_sequence) std.debug.panic(
                        "expected sequence {} but got {f}",
                        .{ info.query_sequence, reply.readFmt(reader) },
                    );
                    if (!info.still_open) @panic("unexpected");
                    const result = try x11.read3(.QueryFont, reader);
                    const msg_remaining_size = x11.stage3.QueryFont.remainingSize(reply.word_count);
                    const required_remaining_size: u35 =
                        (@as(u35, result.property_count) * @sizeOf(x11.FontProp)) +
                        (@as(u35, result.info_count) * @sizeOf(x11.CharInfo));
                    if (required_remaining_size > msg_remaining_size) std.debug.panic(
                        "msg size is {} but fields require {}",
                        .{ msg_remaining_size, required_remaining_size },
                    );
                    try reader.discardAll(msg_remaining_size);
                    const font_info: FontInfo = .{
                        .font_ascent = result.font_ascent,
                        .font_descent = result.font_descent,
                        .property_count = result.property_count,
                        .info_count = result.info_count,
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
