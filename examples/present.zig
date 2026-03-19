//! An example of using the "Present" extension for frame-synchronized animation.
//! Renders into a Pixmap off-screen, then uses PresentPixmap to atomically
//! display the frame. The server sends a CompleteNotify event when the frame
//! has been displayed, which triggers the next frame — providing vsync-driven
//! animation with no manual timers.
const initial_window_width = 800;
const initial_window_height = 400;

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

const Key = enum {
    zoom_in, // + or =
    zoom_out, // -
    pub fn fromSym(sym: x11.charset.Combined) ?Key {
        return switch (sym) {
            .latin_plus_sign, .latin_equals_sign => .zoom_in,
            .latin_minus_sign => .zoom_out,
            else => null,
        };
    }
};

const bg_rgb: u24 = 0x1a1a1a;

const Root = struct {
    window: x11.Window,
    visual: x11.Visual,
    depth: x11.Depth,
};

pub fn main() !void {
    try x11.wsaStartup();

    const stream: std.net.Stream, const ids: Ids, const keyrange: x11.KeycodeRange, const root: Root = blk: {
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
            socket_reader.getStream(),
            .{ .range = id_range },
            try .init(setup.min_keycode, setup.max_keycode),
            .{
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
    run(ids, &root, &sink, &source, keyrange) catch |err| switch (err) {
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
    keyrange: x11.KeycodeRange,
) error{ WriteFailed, ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!void {
    var keycode_map = [1]?Key{null} ** std.math.maxInt(u8);

    {
        var it = try x11.synchronousGetKeyboardMapping(sink, source, keyrange);
        for (keyrange.min..@as(usize, keyrange.max) + 1) |keycode| {
            for (try it.readSyms(source)) |sym| {
                if (Key.fromSym(sym)) |key| {
                    keycode_map[keycode] = key;
                }
            }
        }
    }

    try sink.CreateWindow(.{
        .window_id = ids.window(),
        .parent_window_id = root.window,
        .depth = 0, // we don't care, just inherit from the parent
        .x = 0,
        .y = 0,
        .width = initial_window_width,
        .height = initial_window_height,
        .border_width = 0, // TODO: what is this?
        .class = .input_output,
        .visual_id = root.visual,
    }, .{
        .bg_pixel = bg_rgb,
        .bit_gravity = .north_west,
        .event_mask = .{ .KeyPress = 1, .Exposure = 1, .StructureNotify = 1 },
    });

    try sink.CreateGc(
        ids.gc(),
        ids.window().drawable(),
        .{
            .background = bg_rgb,
            .foreground = 0xcccccc,
        },
    );

    const font_dims: FrameTimeGraph.FontDims = blk: {
        try sink.QueryTextExtents(ids.gc().fontable(), .initComptime(&[_]u16{'m'}));
        try sink.writer.flush();
        const extents, _ = try source.readSynchronousReplyFull(sink.sequence, .QueryTextExtents);
        std.log.info("text extents: {}", .{extents});
        break :blk .{
            .width = @intCast(extents.overall_width),
            .font_ascent = extents.font_ascent,
            .font_descent = @intCast(extents.font_descent),
        };
    };

    const present_ext = try x11.draft.synchronousQueryExtension(source, sink, x11.present.name) orelse {
        std.log.err("Present extension not available", .{});
        std.process.exit(0xff);
    };

    try x11.present.selectInput(
        sink,
        present_ext.opcode_base,
        ids.presentEventId(),
        ids.window(),
        .{ .complete_notify = true },
    );

    var window_width: u16 = initial_window_width;
    var window_height: u16 = initial_window_height;

    try sink.CreatePixmap(ids.pixmap(), ids.window().drawable(), .{
        .depth = root.depth,
        .width = window_width,
        .height = window_height,
    });

    try sink.MapWindow(ids.window());

    var frame_time_graph: FrameTimeGraph = .{ .font_dims = font_dims };
    var present_serial: u32 = 0;
    var do_render = false;

    while (true) {
        try sink.writer.flush();
        const msg_kind = try source.readKind();

        switch (msg_kind) {
            .Expose => {
                _ = try source.read2(.Expose);
                do_render = true;
            },
            .KeyPress => {
                const event = try source.read2(.KeyPress);
                if (keycode_map[event.keycode]) |key| switch (key) {
                    .zoom_in => frame_time_graph.max_ms = @max(1.0, frame_time_graph.max_ms / 2.0),
                    .zoom_out => frame_time_graph.max_ms *= 2.0,
                };
            },
            .KeyRelease => _ = try source.read2(.KeyRelease),
            .GenericEvent => {
                const event = try source.read2(.GenericEvent);
                if (event.isPresentCompleteNotify(present_ext.opcode_base)) {
                    const complete = try source.read3Full(.present_CompleteNotify);
                    std.debug.assert(complete.event_id == ids.presentEventId());
                    std.debug.assert(complete.window == ids.window());
                    if (complete.serial == present_serial) {
                        do_render = true;
                    }
                } else std.debug.panic("unexpected GenericEvent {}", .{event});
            },
            .ConfigureNotify => {
                const event = try source.read2(.ConfigureNotify);
                if (event.width != window_width or event.height != window_height) {
                    window_width = event.width;
                    window_height = event.height;
                    try writeFreeCreatePixmap(
                        sink,
                        ids,
                        root.depth,
                        window_width,
                        window_height,
                    );
                }
            },
            // StructureNotify events:
            .DestroyNotify,
            .UnmapNotify,
            .MapNotify,
            .ReparentNotify,
            .GravityNotify,
            .CirculateNotify,
            // Sent to all clients regardless of event mask:
            .MappingNotify,
            => try source.discardRemaining(),
            else => std.debug.panic("unexpected message {f}", .{source.readFmtDropError()}),
        }

        if (do_render) {
            present_serial +%= 1;
            try sink.ChangeGc(ids.gc(), .{ .foreground = bg_rgb });
            try sink.PolyFillRectangle(ids.pixmap().drawable(), ids.gc(), .initAssume(&.{.{
                .x = 0,
                .y = 0,
                .width = window_width,
                .height = window_height,
            }}));
            frame_time_graph.writeRender(
                sink,
                ids.pixmap().drawable(),
                ids.gc(),
                window_width,
                window_height,
            ) catch |err| switch (err) {
                error.WriteFailed => return error.WriteFailed,
                error.TextTooLong => @panic("todo: handle longer text"),
            };
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
            do_render = false;
        }
    }
}

fn writeFreeCreatePixmap(
    sink: *x11.RequestSink,
    ids: Ids,
    depth: x11.Depth,
    width: u16,
    height: u16,
) error{WriteFailed}!void {
    try sink.FreePixmap(ids.pixmap());
    try sink.CreatePixmap(ids.pixmap(), ids.window().drawable(), .{
        .depth = depth,
        .width = width,
        .height = height,
    });
}

const std = @import("std");
const x11 = @import("x11");
const FrameTimeGraph = @import("FrameTimeGraph.zig");
