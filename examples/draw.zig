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

pub fn main() !void {
    try x11.wsaStartup();

    const display = x11.getDisplay();
    std.log.info("DISPLAY '{s}'", .{display});
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
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .{ .reader = socket_reader.interface() };

    const setup = switch (try x11.ext.authenticate(sink.writer, &source, .{
        .display_num = parsed_display.display_num,
        .socket = stream.handle,
    })) {
        .failed => |reason| {
            x11.log.err("auth failed: {f}", .{reason});
            std.process.exit(0xff);
        },
        .success => |reply_len| reply_len,
    };
    std.log.info("setup reply {}", .{setup});
    const screen = try x11.ext.readSetupDynamic(&source, &setup, .{}) orelse {
        std.log.err("no screen?", .{});
        std.process.exit(0xff);
    };

    const ids: Ids = .{ .base = setup.resource_id_base };

    var window_size: XY(u16) = .{ .x = 400, .y = 400 };

    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = screen.root,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = window_size.x,
            .height = window_size.y,
            .border_width = 0,
            .class = .input_output,
            .visual_id = screen.root_visual,
        },
        .{
            .bg_pixel = x11.rgbFrom24(screen.root_depth, 0),
            .event_mask = .{
                .ButtonPress = 1,
                .ButtonRelease = 1,
                .PointerMotion = 1,
                .Exposure = 1,
                .StructureNotify = 1,
            },
        },
    );

    const dbe: Dbe = blk: {
        const ext = try x11.ext.synchronousQueryExtension(&source, &sink, x11.dbe.name) orelse break :blk .unsupported;
        try x11.dbe.Allocate(&sink, ext.opcode, ids.window(), ids.backBuffer(), .background);
        break :blk .{ .enabled = .{ .opcode = ext.opcode, .back_buffer = ids.backBuffer() } };
    };

    try sink.CreateGc(
        ids.gc(),
        ids.window().drawable(),
        .{
            .background = screen.black_pixel,
            .foreground = screen.white_pixel,
            .line_width = 4,
        },
    );

    const font_dims: FontDims = blk: {
        try sink.QueryTextExtents(ids.gc().fontable(), .initComptime(&[_]u16{'m'}));
        try sink.writer.flush();
        const extents, _ = try source.readSynchronousReplyFull(sink.sequence, .QueryTextExtents);
        std.log.info("text extents: {}", .{extents});
        break :blk .{
            .width = @intCast(extents.overall_width),
            .height = @intCast(extents.font_ascent + extents.font_descent),
            .font_left = @intCast(extents.overall_left),
            .font_ascent = extents.font_ascent,
        };
    };

    try sink.MapWindow(ids.window());

    var point_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var points: x11.ArrayListManaged(XY(i16)) = .init(point_arena.allocator());
    var mouse_state: MouseState = .{};

    while (true) {
        try sink.writer.flush();
        const msg_kind = source.readKind() catch |err| return switch (err) {
            error.EndOfStream => {
                std.log.info("X11 connection closed (EndOfStream)", .{});
                std.process.exit(0);
            },
            else => |e| switch (socket_reader.getError() orelse e) {
                error.ConnectionResetByPeer => {
                    std.log.info("X11 connection closed (ConnectionReset)", .{});
                    return std.process.exit(0);
                },
                else => |e2| e2,
            },
        };

        var do_render = false;
        switch (msg_kind) {
            .ButtonPress => {
                std.log.info("ButtonPress", .{});
                const msg = try source.read2(.ButtonPress);
                do_render = onMouseEvent(&points, &mouse_state, msg.asCommon());
                if (msg.button == 3) {
                    points.clearRetainingCapacity();
                    do_render = true;
                }
            },
            .ButtonRelease => {
                std.log.info("ButtonRelease", .{});
                try source.discardRemaining();
                mouse_state.buttonRelease();
            },
            .MotionNotify => {
                const msg = try source.read2(.MotionNotify);
                do_render = onMouseEvent(&points, &mouse_state, msg.asCommon());
            },
            .Expose => {
                const expose = try source.read2(.Expose);
                std.log.info("X11 {}", .{expose});
                do_render = true;
            },
            .ConfigureNotify => {
                const msg = try source.read2(.ConfigureNotify);
                std.debug.assert(msg.event == ids.window());
                std.debug.assert(msg.window == ids.window());
                if (window_size.x != msg.width or window_size.y != msg.height) {
                    std.log.info("WindowSize {}x{}", .{ msg.width, msg.height });
                    window_size = .{ .x = msg.width, .y = msg.height };
                    do_render = true;
                }
            },
            .MapNotify,
            .ReparentNotify,
            => {
                try source.discardRemaining();
            },
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
        }
        if (do_render) {
            try render(
                &sink,
                ids.window(),
                ids.gc(),
                font_dims,
                dbe,
                window_size,
                points.items,
            );
        }
    }
}

fn onMouseEvent(
    points: *x11.ArrayListManaged(XY(i16)),
    mouse_state: *MouseState,
    event: x11.CommonEvent,
) bool {
    const len_before = points.items.len;
    mouse_state.update(
        points,
        event.state.button1,
        .{ .x = event.event_x, .y = event.event_y },
    );
    return len_before != points.items.len;
}

// An array of annotation points should always starts with two valid
// points.  After that, at some point there will be a special "lift pen"
// points.  Following every lift pen point should always be two non lift-
// pen points.
const lift_pen: XY(i16) = .{ .x = -1, .y = -1 };

pub fn getDrawState(points: []const XY(i16)) union(enum) {
    lifted,
    last_point: XY(i16),
} {
    if (points.len == 0) return .lifted;
}

const MouseState = struct {
    last_down_position: ?XY(i16) = null,

    pub fn buttonRelease(state: *MouseState) void {
        state.last_down_position = null;
    }
    pub fn update(
        state: *MouseState,
        points: *x11.ArrayListManaged(XY(i16)),
        button_down: bool,
        new_pos: XY(i16),
    ) void {
        if (!button_down) {
            state.last_down_position = null;
            return;
        }

        if (state.last_down_position) |last_pos| {
            if (!last_pos.eql(new_pos)) {
                if (points.items.len == 0) {
                    points.append(last_pos) catch |e| oom(e);
                } else if (points.items[points.items.len - 1].eql(last_pos)) {
                    // drawing the same line, just add the new point
                } else {
                    points.append(lift_pen) catch |e| oom(e);
                    points.append(last_pos) catch |e| oom(e);
                }
                points.append(new_pos) catch |e| oom(e);
            }
        }

        state.last_down_position = new_pos;
    }
};

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

fn render(
    sink: *x11.RequestSink,
    window: x11.Window,
    gc: x11.GraphicsContext,
    font_dims: FontDims,
    dbe: Dbe,
    window_size: XY(u16),
    lines: []const XY(i16),
) !void {
    if (null == dbe.backBuffer()) {
        try sink.ClearArea(
            window,
            .{
                .x = 0,
                .y = 0,
                .width = window_size.x,
                .height = window_size.y,
            },
            .{ .exposures = false },
        );
    }
    const drawable = if (dbe.backBuffer()) |back_buffer| back_buffer else window.drawable();
    try renderLines(sink, drawable, gc, lines);

    const text = "Draw on me!";
    const text_width = font_dims.width * text.len;
    try sink.ImageText8(
        drawable,
        gc,
        .{
            .x = @truncate(@divTrunc((@as(i32, @intCast(window_size.x)) - @as(i32, @intCast(text_width))), 2) + font_dims.font_left),
            .y = @truncate(@divTrunc((@as(i32, @intCast(window_size.y)) - @as(i32, @intCast(font_dims.height))), 2) + font_dims.font_ascent),
        },
        .initComptime(text),
    );
    switch (dbe) {
        .unsupported => {},
        .enabled => |enabled| try x11.dbe.Swap(sink, enabled.opcode, .initAssume(&.{
            .{ .window = window, .action = .background },
        })),
    }
}

fn renderLines(
    sink: *x11.RequestSink,
    drawable: x11.Drawable,
    gc: x11.GraphicsContext,
    lines: []const XY(i16),
) x11.Writer.Error!void {
    if (lines.len == 0) return;
    var i: usize = 0;
    blk_segment: while (true) {
        // every line should start with at least two non lift-pen points
        std.debug.assert(i + 2 <= lines.len);
        std.debug.assert(!lines[i].eql(lift_pen));
        std.debug.assert(!lines[i + 1].eql(lift_pen));
        var point_sink: x11.PolyPointSink = .{
            .kind = .Line,
            .coordinate_mode = .origin,
            .drawable = drawable,
            .gc = gc,
        };
        defer point_sink.endSetMsgSize(sink.writer);
        try point_sink.write(sink, lines[i]);
        while (true) {
            try point_sink.write(sink, lines[i + 1]);
            i += 1;
            if (i + 1 == lines.len) break :blk_segment;
            if (lines[i + 1].eql(lift_pen)) break;
        }
        i += 2;
    }
}

const Dbe = union(enum) {
    unsupported,
    enabled: struct {
        opcode: u8,
        back_buffer: x11.Drawable,
    },
    pub fn backBuffer(self: Dbe) ?x11.Drawable {
        return switch (self) {
            .unsupported => null,
            .enabled => |enabled| enabled.back_buffer,
        };
    }
};

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const std = @import("std");
const x11 = @import("x11");
const XY = x11.XY;
