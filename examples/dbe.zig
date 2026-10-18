//! An example of using the "Double Buffer Extension" (DBE).
//! Consider using the Present extension instead, which supersedes DBE by
//! providing both off-screen rendering (via Pixmaps) and frame synchronization
//! (via CompleteNotify events). See examples/present.zig. This example only
//! exists to test/ensure the DBE extension code remains working.
const std = @import("std");
const x11 = @import("x11");

pub const std_options: std.Options = .{ .io_vtable = .threaded };

const initial_window_width = 400;
const initial_window_height = 400;

const Key = enum {
    f, // faster
    s, // slower
    d, // toggle double buffering
    pub fn fromSym(sym: x11.charset.Combined) ?Key {
        return switch (sym) {
            .latin_f, .latin_F => .f,
            .latin_s, .latin_S => .s,
            .latin_d, .latin_D => .d,
            else => null,
        };
    }
};

const Ids = struct {
    range: x11.IdRange,
    pub fn window(self: Ids) x11.Window {
        return self.range.addAssumeCapacity(0).window();
    }
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.range.addAssumeCapacity(1).graphicsContext();
    }
    pub fn backBuffer(self: Ids) x11.Drawable {
        return self.range.addAssumeCapacity(2).drawable();
    }
    const needed_capacity = 3;
};

const Root = struct {
    window: x11.Window,
    visual: x11.Visual,
    depth: x11.Depth,
};

pub fn main(init: std.process.Init.Minimal) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const stream: std.Io.net.Stream, const ids: Ids, const keyrange: x11.KeycodeRange, const root: Root = blk: {
        var read_buffer: [1000]u8 = undefined;
        var socket_reader, const used_auth = try x11.draft.connect(io, init.environ, &read_buffer);
        errdefer x11.disconnect(io, socket_reader.stream);
        _ = used_auth;
        const setup = x11.readSetupSuccess(&socket_reader.interface) catch |err| switch (err) {
            error.ReadFailed => return socket_reader.err.?,
            error.EndOfStream, error.Protocol => |e| return e,
        };
        std.log.info("setup reply {f}", .{setup});
        var source: x11.Source = .initFinishSetup(&socket_reader.interface, &setup);
        const screen = (x11.draft.readSetupDynamic(&source, &setup, .{}) catch |err| switch (err) {
            error.ReadFailed => return socket_reader.err.?,
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
            socket_reader.stream,
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
    defer x11.disconnect(io, stream);

    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = stream.writer(io, &write_buffer);
    var socket_reader = stream.reader(io, &read_buffer);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .initAfterSetup(&socket_reader.interface);
    run(io, ids, &root, &sink, &socket_reader, &source, keyrange) catch |err| switch (err) {
        error.WriteFailed => |e| return x11.onWriteError(e, socket_writer.err.?),
        error.ReadFailed, error.EndOfStream, error.Protocol => |e| return source.onReadError(e, socket_reader.err),
        error.UnexpectedMessage => |e| return e,
    };
}

fn run(
    io: std.Io,
    ids: Ids,
    root: *const Root,
    sink: *x11.RequestSink,
    socket_reader: *std.Io.net.Stream.Reader,
    source: *x11.Source,
    keyrange: x11.KeycodeRange,
) error{ WriteFailed, ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!void {
    var keycode_map: [std.math.maxInt(u8)]?Key = @splat(null);
    {
        var it = try x11.synchronousGetKeyboardMapping(sink, source, keyrange);
        for (keyrange.min..@as(usize, keyrange.max) + 1) |keycode| {
            for (try it.readSyms(source)) |sym| {
                if (Key.fromSym(sym)) |key| {
                    if (keycode_map[keycode]) |existing| {
                        std.log.info("keycode {} maps to {s}", .{ keycode, @tagName(key) });
                        if (existing != key) {
                            std.log.err(
                                "keycode {} maps to {s} and {s} (need to improve keymap)",
                                .{ keycode, @tagName(existing), @tagName(key) },
                            );
                            std.process.exit(0xff);
                        }
                    } else {
                        keycode_map[keycode] = key;
                    }
                }
            }
        }
    }

    // queried before creating the window so no events can arrive while we wait for the reply
    const opt_dbe_ext = try x11.draft.synchronousQueryExtension(source, sink, x11.dbe.name);

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
        .bg_pixel = 0x332211,
        .bit_gravity = .north_west,
        .event_mask = .{ .KeyPress = 1, .Exposure = 1, .StructureNotify = 1 },
    });

    try sink.CreateGc(
        ids.gc(),
        ids.window().drawable(),
        .{
            .background = 0x332211,
            .foreground = 0xaabbff,
        },
    );
    try sink.writer.flush();

    var dbe: Dbe = blk: {
        const ext = opt_dbe_ext orelse break :blk .unsupported;
        try x11.dbe.Allocate(sink, ext.opcode_base, ids.window(), ids.backBuffer(), .background);
        break :blk .{ .enabled = .{ .opcode = ext.opcode_base, .back_buffer = ids.backBuffer() } };
    };

    try sink.MapWindow(ids.window());

    var window_width: u16 = initial_window_width;
    var window_height: u16 = initial_window_height;
    var animate: Animate = .{ .previous_time = .now(io, .awake) };
    var animate_frame_ms: i32 = 15;

    while (true) {
        try sink.writer.flush();

        const action: enum { timeout, socket } = switch (pollSocketReader(io, socket_reader, 0)) {
            .ready => .socket,
            .timeout => if (getTimeout(io, animate.previous_time, animate_frame_ms)) |timeout_ms| switch (pollSocketReader(io, socket_reader, timeout_ms)) {
                .ready => .socket,
                // timeouts are allowed to return early, check if it's time to render
                .timeout => continue,
            } else .timeout,
        };

        switch (action) {
            .timeout => {
                try render(
                    io,
                    sink,
                    ids.window(),
                    ids.gc(),
                    dbe,
                    &animate,
                    animate_frame_ms,
                    window_width,
                    window_height,
                );
                continue;
            },
            .socket => {},
        }

        try sink.writer.flush();
        const msg_kind = try source.readKind();
        switch (msg_kind) {
            .KeyPress => {
                const event = try source.read2(.KeyPress);

                var do_render = true;
                if (keycode_map[event.keycode]) |key| switch (key) {
                    .f => {
                        if (animate_frame_ms > 1) {
                            animate_frame_ms -= 1;
                        }
                    },
                    .s => animate_frame_ms += 1,
                    .d => switch (dbe) {
                        .unsupported => {},
                        .disabled => |disabled| {
                            try x11.dbe.Allocate(
                                sink,
                                disabled.opcode,
                                ids.window(),
                                ids.backBuffer(),
                                .background,
                            );
                            dbe = .{ .enabled = .{
                                .opcode = disabled.opcode,
                                .back_buffer = ids.backBuffer(),
                            } };
                        },
                        .enabled => |enabled| {
                            try x11.dbe.Deallocate(
                                sink,
                                enabled.opcode,
                                ids.backBuffer(),
                            );
                            dbe = .{ .disabled = .{ .opcode = enabled.opcode } };
                        },
                    },
                } else {
                    std.log.info("KeyPress: {} (ignored)", .{event.keycode});
                    do_render = false;
                }
                if (do_render) {
                    try render(
                        io,
                        sink,
                        ids.window(),
                        ids.gc(),
                        dbe,
                        &animate,
                        animate_frame_ms,
                        window_width,
                        window_height,
                    );
                }
            },
            // NOTE: server will send us KeyRelease when the user holds down a key
            //       even though we didn't register for the KeyRelease event
            .KeyRelease => _ = try source.read2(.KeyRelease),
            .Expose => {
                const expose = try source.read2(.Expose);
                std.log.info("{}", .{expose});
                try render(
                    io,
                    sink,
                    ids.window(),
                    ids.gc(),
                    dbe,
                    &animate,
                    animate_frame_ms,
                    window_width,
                    window_height,
                );
            },
            .ConfigureNotify => {
                const event = try source.read2(.ConfigureNotify);
                window_width = event.width;
                window_height = event.height;
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
    }
}

fn pollSocketReader(io: std.Io, socket_reader: *std.Io.net.Stream.Reader, timeout_ms: i32) enum { ready, timeout } {
    const reader = &socket_reader.interface;
    if (reader.bufferedLen() > 0) return .ready;
    // read directly into the empty reader buffer so we can wait with a timeout
    reader.seek = 0;
    reader.end = 0;
    var data: [1][]u8 = .{reader.buffer};
    // std rounds the time left down to milliseconds when it polls, add just under
    // 1ms so we wait at least timeout_ms instead of spinning until it's reached
    const timeout: std.Io.Duration = .fromNanoseconds(@as(i96, timeout_ms) * std.time.ns_per_ms + std.time.ns_per_ms - 1);
    const result = io.operateTimeout(.{ .net_read = .{
        .socket_handle = socket_reader.stream.socket.handle,
        .data = &data,
    } }, .{ .duration = .{ .raw = timeout, .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => return .timeout,
        else => |e| std.debug.panic("poll socket failed with {t}", .{e}),
    };
    // on error/EndOfStream the next read from the socket reader will report it
    if (result.net_read) |read_result| {
        reader.end = read_result.data_len;
    } else |_| {}
    return .ready;
}

pub fn getTimeout(io: std.Io, start: std.Io.Timestamp, duration_ms: i32) ?u31 {
    const since_ms = start.untilNow(io, .awake).toMilliseconds();
    if (since_ms >= duration_ms) return null;
    return @intCast(duration_ms - @as(i32, @intCast(since_ms)));
}

const Animate = struct {
    previous_time: std.Io.Timestamp,
    progress: f32 = 0,
};

const Dbe = union(enum) {
    unsupported,
    disabled: struct {
        opcode: u8,
    },
    enabled: struct {
        opcode: u8,
        back_buffer: x11.Drawable,
    },
    pub fn backBuffer(self: Dbe) ?x11.Drawable {
        return switch (self) {
            .unsupported, .disabled => null,
            .enabled => |enabled| enabled.back_buffer,
        };
    }
};

fn render(
    io: std.Io,
    sink: *x11.RequestSink,
    window: x11.Window,
    gc_id: x11.GraphicsContext,
    dbe: Dbe,
    animate: *Animate,
    animate_frame_ms: i32,
    window_width: u16,
    window_height: u16,
) !void {
    const elapsed_ns = blk: {
        const now = std.Io.Timestamp.now(io, .awake);
        const elapsed_ns = animate.previous_time.durationTo(now).toNanoseconds();
        animate.previous_time = now;
        break :blk elapsed_ns;
    };

    const animation_duration_ns: f32 = 2000.0 * std.time.ns_per_ms; // 2 seconds for full cycle
    const elapsed_ns_f32: f32 = @floatFromInt(elapsed_ns);
    const progress_increment: f32 = elapsed_ns_f32 / animation_duration_ns;
    animate.progress = @mod(animate.progress + progress_increment, 1.0);

    if (null == dbe.backBuffer()) {
        try sink.ClearArea(
            window,
            .{
                .x = 0,
                .y = 0,
                .width = 0, // 0 means rest of window
                .height = 0,
            },
            .{ .exposures = false },
        );
    }

    const target_drawable = if (dbe.backBuffer()) |back_buffer| back_buffer else window.drawable();

    try sink.PolyFillRectangle(
        target_drawable,
        gc_id,
        .initAssume(&.{.{
            .x = @intFromFloat(@round(@as(f32, @floatFromInt(window_width)) * animate.progress)),
            .y = @intFromFloat(@round(@as(f32, @floatFromInt(window_height)) * animate.progress)),
            .width = 10,
            .height = 10,
        }}),
    );

    const fps: f32 = @as(f32, 1000.0) / @as(f32, @floatFromInt(animate_frame_ms));
    if (animate_frame_ms == 0) {
        try renderString(sink, target_drawable, gc_id, .{ .x = 10, .y = 10 }, "FPS: <no limit>", .{});
    } else {
        try renderString(sink, target_drawable, gc_id, .{ .x = 10, .y = 10 }, "FPS: {d:.1}", .{fps});
    }
    try renderString(sink, target_drawable, gc_id, .{ .x = 270, .y = 10 }, "f: faster, s: slower", .{});
    try renderString(sink, target_drawable, gc_id, .{ .x = 10, .y = 30 }, "DoubleBuffering: {s}", .{@tagName(dbe)});
    try renderString(sink, target_drawable, gc_id, .{ .x = 270, .y = 30 }, "d: toggle", .{});
    switch (dbe) {
        .unsupported, .disabled => {},
        .enabled => |enabled| try x11.dbe.Swap(sink, enabled.opcode, .initAssume(&.{
            .{ .window = window, .action = .background },
        })),
    }
}

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
