//! An example of using the "Double Buffer Extension" (DBE)
const std = @import("std");
const x11 = @import("x11");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 400;
const window_height = 400;

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

    var keycode_map = std.AutoHashMapUnmanaged(u8, Key){};
    {
        var it = try x11.synchronousGetKeyboardMapping(&sink, &source, try .init(
            setup.min_keycode,
            setup.max_keycode,
        ));
        for (setup.min_keycode..@as(usize, setup.max_keycode) + 1) |keycode| {
            for (try it.readSyms(&source)) |sym| {
                if (Key.fromSym(sym)) |key| {
                    std.log.info("key {s} code is {}", .{ @tagName(key), keycode });
                    try keycode_map.put(allocator, @intCast(keycode), key);
                }
            }
        }
    }

    const ids: Ids = .{ .base = setup.resource_id_base };

    try sink.CreateWindow(.{
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
        .event_mask = .{ .KeyPress = 1, .Exposure = 1 },
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
        const ext = try x11.ext.synchronousQueryExtension(&source, &sink, x11.dbe.name) orelse break :blk .unsupported;
        try x11.dbe.Allocate(&sink, ext.opcode_base, ids.window(), ids.backBuffer(), .background);
        break :blk .{ .enabled = .{ .opcode = ext.opcode_base, .back_buffer = ids.backBuffer() } };
    };

    try sink.MapWindow(ids.window());

    var animate: Animate = .{ .previous_time = try std.time.Instant.now() };
    var animate_frame_ms: i32 = 15;

    while (true) {
        try sink.writer.flush();

        const action: enum { timeout, socket } = switch (try pollSocketReader(&io.socket_reader, 0)) {
            .ready => .socket,
            .timeout => if (try getTimeout(animate.previous_time, animate_frame_ms)) |timeout_ms| switch (try pollSocketReader(&io.socket_reader, timeout_ms)) {
                .ready => .socket,
                .timeout => .timeout,
            } else .timeout,
        };

        switch (action) {
            .timeout => {
                try render(
                    &sink,
                    ids.window(),
                    ids.gc(),
                    dbe,
                    &animate,
                    animate_frame_ms,
                );
                continue;
            },
            .socket => {},
        }

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
            .KeyPress => {
                const event = try source.read2(.KeyPress);

                var do_render = true;
                if (keycode_map.get(event.keycode)) |key| switch (key) {
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
                                &sink,
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
                                &sink,
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
                        &sink,
                        ids.window(),
                        ids.gc(),
                        dbe,
                        &animate,
                        animate_frame_ms,
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
                    &sink,
                    ids.window(),
                    ids.gc(),
                    dbe,
                    &animate,
                    animate_frame_ms,
                );
            },
            else => std.debug.panic("unexpected message {f}", .{source.readFmt()}),
        }
    }
}

fn pollSocketReader(socket_reader: *x11.SocketReader, timeout_ms: i32) !enum { ready, timeout } {
    if (socket_reader.interface().bufferedLen() > 0) return .ready;
    var poll_fds = [_]std.posix.pollfd{
        .{
            .fd = socket_reader.getStream().handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    return switch (try std.posix.poll(&poll_fds, timeout_ms)) {
        0 => .timeout,
        1 => .ready,
        else => unreachable,
    };
}

pub fn getTimeout(start: std.time.Instant, duration_ms: i32) !?u31 {
    const now = try std.time.Instant.now();
    const since_ms = @divTrunc(now.since(start), std.time.ns_per_ms);
    if (since_ms >= duration_ms) return null;
    return @intCast(duration_ms - @as(i32, @intCast(since_ms)));
}

const Animate = struct {
    previous_time: std.time.Instant,
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
    sink: *x11.RequestSink,
    window: x11.Window,
    gc_id: x11.GraphicsContext,
    dbe: Dbe,
    animate: *Animate,
    animate_frame_ms: i32,
) !void {
    const elapsed_ms = blk: {
        const now = try std.time.Instant.now();
        const elapsed_ms = now.since(animate.previous_time);
        animate.previous_time = now;
        break :blk elapsed_ms;
    };

    const animation_duration_ms: f32 = 2000.0; // 2 seconds for full cycle
    const elapsed_ms_f32: f32 = @floatFromInt(elapsed_ms / std.time.ns_per_ms);
    const progress_increment: f32 = elapsed_ms_f32 / animation_duration_ms;
    animate.progress = @mod(animate.progress + progress_increment, 1.0);

    if (null == dbe.backBuffer()) {
        try sink.ClearArea(
            window,
            .{
                .x = 0,
                .y = 0,
                .width = window_width,
                .height = window_height,
            },
            .{ .exposures = false },
        );
    }

    const target_drawable = if (dbe.backBuffer()) |back_buffer| back_buffer else window.drawable();

    try sink.PolyFillRectangle(
        target_drawable,
        gc_id,
        .initAssume(&.{.{
            .x = @intFromFloat(@round(@as(f32, window_width) * animate.progress)),
            .y = @intFromFloat(@round(@as(f32, window_width) * animate.progress)),
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
