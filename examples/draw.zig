const Ids = struct {
    range: x11.IdRange,
    pub fn window(self: Ids) x11.Window {
        return self.range.addAssumeCapacity(0).window();
    }
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.range.addAssumeCapacity(1).graphicsContext();
    }
    pub fn pixmap(self: Ids) x11.Pixmap {
        return self.range.addAssumeCapacity(2).pixmap();
    }
    pub fn presentEventId(self: Ids) u32 {
        return @intFromEnum(self.range.addAssumeCapacity(3));
    }
    const needed_capacity = 4;
};

const Root = struct {
    window: x11.Window,
    visual: x11.Visual,
    depth: x11.Depth,
};

pub fn main() !void {
    try x11.wsaStartup();

    const stream: std.net.Stream, const ids: Ids, const root: Root = blk: {
        var read_buffer: [1000]u8 = undefined;
        var socket_reader, const used_auth = try x11.draft.connect(&read_buffer);
        errdefer x11.disconnect(socket_reader.getStream());
        _ = used_auth;
        const setup = x11.readSetupSuccess(socket_reader.interface()) catch |err| switch (err) {
            error.ReadFailed => return socket_reader.getError().?,
            error.EndOfStream, error.Protocol => |e| return e,
        };
        std.log.info("setup reply {f}", .{setup});
        var source: x11.Source = .initFinishSetup(socket_reader.interface(), &setup);
        const screen = (x11.draft.readSetupDynamic(&source, &setup, .{}) catch |err| switch (err) {
            error.ReadFailed => return socket_reader.getError().?,
            error.EndOfStream, error.Protocol => |e| return e,
        }) orelse {
            std.log.err("no screen?", .{});
            std.process.exit(0xff);
        };
        const id_range = try x11.IdRange.init(setup.resource_id_base, setup.resource_id_mask);
        if (id_range.capacity() < Ids.needed_capacity) {
            std.log.err("X server id range capacity {} is less than needed {}", .{ id_range.capacity(), Ids.needed_capacity });
            std.process.exit(0xff);
        }
        break :blk .{
            socket_reader.getStream(), .{ .range = id_range }, .{
                .window = screen.root,
                .visual = screen.root_visual,
                .depth = x11.Depth.init(screen.root_depth) orelse std.debug.panic(
                    "unsupported depth {}",
                    .{screen.root_depth},
                ),
            },
        };
    };
    defer x11.disconnect(stream);

    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = x11.socketWriter(stream, &write_buffer);
    var socket_reader = x11.socketReader(stream, &read_buffer);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .initAfterSetup(socket_reader.interface());
    run(ids, &root, &sink, &source) catch |err| switch (err) {
        error.WriteFailed => |e| return x11.onWriteError(e, socket_writer.err.?),
        error.ReadFailed, error.EndOfStream, error.Protocol => |e| return source.onReadError(e, socket_reader.getError()),
        error.UnexpectedMessage => |e| return e,
    };
}

fn run(
    ids: Ids,
    root: *const Root,
    sink: *x11.RequestSink,
    source: *x11.Source,
) error{ WriteFailed, ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!void {
    var window_size: XY(u16) = .{ .x = 400, .y = 400 };

    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = root.window,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = window_size.x,
            .height = window_size.y,
            .border_width = 0,
            .class = .input_output,
            .visual_id = root.visual,
        },
        .{
            .bg_pixel = root.depth.rgbFrom24(0),
            .bit_gravity = .north_west,
            .event_mask = .{
                .ButtonPress = 1,
                .ButtonRelease = 1,
                .PointerMotion = 1,
                .Exposure = 1,
                .StructureNotify = 1,
            },
        },
    );

    const present_ext = try x11.draft.synchronousQueryExtension(
        source,
        sink,
        x11.present.name,
    ) orelse {
        std.log.err("Present extension not available", .{});
        std.process.exit(0xff);
    };

    try sink.CreateGc(
        ids.gc(),
        ids.window().drawable(),
        .{
            .background = root.depth.rgbFrom24(0),
            .foreground = root.depth.rgbFrom24(0xffffff),
            .line_width = 4,
        },
    );

    try x11.present.selectInput(
        sink,
        present_ext.opcode_base,
        ids.presentEventId(),
        ids.window(),
        .{ .complete_notify = true },
    );

    try sink.CreatePixmap(ids.pixmap(), ids.window().drawable(), .{
        .depth = root.depth,
        .width = window_size.x,
        .height = window_size.y,
    });

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
    var points: std.array_list.Managed(XY(i16)) = .init(point_arena.allocator());
    var mouse_state: MouseState = .{};
    var mode: Mode = .line;
    var present_serial: u32 = 0;
    var render_in_flight = false;
    var dirty = false;

    while (true) {
        try sink.writer.flush();
        const msg_kind = try source.readKind();

        switch (msg_kind) {
            .ButtonPress => {
                const msg = try source.read2(.ButtonPress);
                std.log.info("ButtonPress {}", .{msg.button});
                const button1_down = (msg.button == 1) or msg.state.button1;
                if (onMouseEvent(
                    &points,
                    &mouse_state,
                    .{ .x = msg.event_x, .y = msg.event_y },
                    button1_down,
                )) dirty = true;
                switch (msg.button) {
                    1 => {},
                    3 => {
                        // usually right click
                        points.clearRetainingCapacity();
                        dirty = true;
                    },
                    2, 5 => {
                        // usually middle button and scroll
                        mode = mode.next();
                        dirty = true;
                    },
                    4 => {
                        // usually the other scroll direction
                        mode = mode.prev();
                        dirty = true;
                    },
                    else => {},
                }
            },
            .ButtonRelease => {
                const msg = try source.read2(.ButtonRelease);
                std.log.info("ButtonRelease {}", .{msg.button});
                const button1_down = (msg.button != 1) and msg.state.button1;
                if (onMouseEvent(
                    &points,
                    &mouse_state,
                    .{ .x = msg.event_x, .y = msg.event_y },
                    button1_down,
                )) dirty = true;
            },
            .MotionNotify => {
                const msg = try source.read2(.MotionNotify);
                if (onMouseEvent(
                    &points,
                    &mouse_state,
                    .{ .x = msg.event_x, .y = msg.event_y },
                    msg.state.button1,
                )) dirty = true;
            },
            .Expose => {
                _ = try source.read2(.Expose);
                dirty = true;
            },
            .ConfigureNotify => {
                const msg = try source.read2(.ConfigureNotify);
                std.debug.assert(msg.event == ids.window());
                std.debug.assert(msg.window == ids.window());
                if (window_size.x != msg.width or window_size.y != msg.height) {
                    std.log.info("WindowSize {}x{}", .{ msg.width, msg.height });
                    window_size = .{ .x = msg.width, .y = msg.height };
                    try sink.FreePixmap(ids.pixmap());
                    try sink.CreatePixmap(ids.pixmap(), ids.window().drawable(), .{
                        .depth = root.depth,
                        .width = window_size.x,
                        .height = window_size.y,
                    });
                    dirty = true;
                }
            },
            .GenericEvent => {
                const event = try source.read2(.GenericEvent);
                if (event.isPresentCompleteNotify(present_ext.opcode_base)) {
                    const complete = try source.read3Full(.present_CompleteNotify);
                    std.debug.assert(complete.event_id == ids.presentEventId());
                    std.debug.assert(complete.window == ids.window());
                    if (complete.serial == present_serial) {
                        std.debug.assert(render_in_flight);
                        render_in_flight = false;
                    }
                } else std.debug.panic("unexpected GenericEvent {}", .{event});
            },
            .MapNotify,
            .ReparentNotify,
            .MappingNotify,
            => {
                try source.discardRemaining();
            },
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmtDropError()}),
        }
        if (dirty and !render_in_flight) {
            try render(
                sink,
                ids.pixmap(),
                ids.gc(),
                font_dims,
                window_size,
                points.items,
                mode,
            );
            present_serial +%= 1;
            try x11.present.presentPixmap(
                sink,
                present_ext.opcode_base,
                ids.window(),
                ids.pixmap(),
                present_serial,
                0,
                0,
                0,
            );
            render_in_flight = true;
            dirty = false;
        }
    }
}

const Mode = enum {
    line,
    fill_complex,
    fill_non_convex,
    fill_convex,

    fn add(mode: Mode, value: u32) Mode {
        return @enumFromInt((@as(u32, @intFromEnum(mode)) + value) % std.meta.fields(Mode).len);
    }
    pub fn next(mode: Mode) Mode {
        return mode.add(1);
    }
    pub fn prev(mode: Mode) Mode {
        return mode.add(std.meta.fields(Mode).len - 1);
    }
};

fn onMouseEvent(
    points: *std.array_list.Managed(XY(i16)),
    mouse_state: *MouseState,
    pos: XY(i16),
    button1_down: bool,
) bool {
    const len_before = points.items.len;
    mouse_state.update(points, button1_down, pos);
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
        points: *std.array_list.Managed(XY(i16)),
        button1_down: bool,
        new_pos: XY(i16),
    ) void {
        if (!button1_down) {
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
    pixmap: x11.Pixmap,
    gc: x11.GraphicsContext,
    font_dims: FontDims,
    window_size: XY(u16),
    lines: []const XY(i16),
    mode: Mode,
) !void {
    const drawable = pixmap.drawable();
    try sink.ChangeGc(gc, .{ .foreground = 0 });
    try sink.PolyFillRectangle(drawable, gc, .initAssume(&.{.{
        .x = 0,
        .y = 0,
        .width = window_size.x,
        .height = window_size.y,
    }}));

    try sink.ChangeGc(gc, .{ .foreground = 0xffffff });
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
    try renderLines(sink, drawable, gc, lines, mode);
    try sink.PolyText8(drawable, gc, .{ .x = 5, .y = 5 + font_dims.height }, &[_]x11.TextItem8{
        .{ .text_element = .{ .delta = 0, .string = switch (mode) {
            inline else => |name| .initComptime(@tagName(name)),
        } } },
    });
    try sink.PolyText8(drawable, gc, .{ .x = 5, .y = 5 + font_dims.height * 2 }, &[_]x11.TextItem8{
        .{ .text_element = .{
            .delta = 0,
            .string = .initComptime("Mouse wheel to change mode"),
        } },
    });
}

fn renderLines(
    sink: *x11.RequestSink,
    drawable: x11.Drawable,
    gc: x11.GraphicsContext,
    lines: []const XY(i16),
    mode: Mode,
) error{WriteFailed}!void {
    if (lines.len == 0) return;
    var i: usize = 0;
    blk_segment: while (true) {
        // every line should start with at least two non lift-pen points
        std.debug.assert(i + 2 <= lines.len);
        std.debug.assert(!lines[i].eql(lift_pen));
        std.debug.assert(!lines[i + 1].eql(lift_pen));
        var point_sink: x11.PolyPointSink = .{
            .kind = switch (mode) {
                .line => .line,
                .fill_complex => .{ .fill = .complex },
                .fill_non_convex => .{ .fill = .non_convex },
                .fill_convex => .{ .fill = .convex },
            },
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

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const std = @import("std");
const x11 = @import("x11");
const XY = x11.XY;
