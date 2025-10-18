const window_width = 300;
const window_height = 800;

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

    const ids: Ids = .{ .base = fixed.resource_id_base };
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };

    var keymap: x11.keymap.Full = .initVoid();

    {
        var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena_instance.deinit();
        const arena = arena_instance.allocator();
        const keymap_response = try x11.keymap.request(arena, &sink, reader, &fixed);
        defer keymap_response.deinit(arena);
        try keymap.load(fixed.min_keycode, keymap_response);
    }

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
        .event_mask = .{
            .KeyPress = 1,
            .KeyRelease = 1,
            // .keymap_state = 1,
            .Exposure = 1,
        },
    });

    try sink.CreateGc(
        ids.gc(),
        ids.window().drawable(),
        .{
            .background = 0x332211,
            .foreground = 0xaabbff,
        },
    );

    try sink.QueryExtension(x11.dbe.name);
    const dbe: Dbe = blk: {
        const sequence = sink.sequence;
        try sink.writer.flush();
        const msg1 = try x11.read1(reader);
        if (msg1.kind != .Reply) std.debug.panic(
            "expected Reply but got {f}",
            .{msg1.readFmt(reader)},
        );
        const reply = try msg1.read2(.Reply, reader);
        if (reply.sequence != sequence) std.debug.panic(
            "expected sequence {} but got {f}",
            .{ sequence, reply.readFmt(reader) },
        );
        const remaining_size = reply.remainingSize();
        if (remaining_size != @sizeOf(x11.stage3.QueryExtension)) std.debug.panic(
            "expected size {} but got {}",
            .{ @sizeOf(x11.stage3.QueryExtension), remaining_size },
        );
        const maybe_ext: ?x11.Extension = try .init(try x11.read3(.QueryExtension, reader));
        std.log.info("extension '{s}': {?}", .{ x11.dbe.name.nativeSlice(), maybe_ext });
        break :blk if (maybe_ext) |ext|
            .{ .enabled = .{ .opcode = ext.opcode, .back_buffer = ids.backBuffer() } }
        else
            .unsupported;
    };

    const font_dims: FontDims = blk: {
        try sink.QueryTextExtents(ids.gc().fontable(), .initComptime(&[_]u16{'m'}));
        const sequence = sink.sequence;
        try sink.writer.flush();
        const msg1 = try x11.read1(reader);
        if (msg1.kind != .Reply) std.debug.panic(
            "expected Reply but got {f}",
            .{msg1.readFmt(reader)},
        );
        const reply = try msg1.read2(.Reply, reader);
        if (reply.sequence != sequence) std.debug.panic(
            "expected sequence {} but got {f}",
            .{ sequence, reply.readFmt(reader) },
        );
        const remaining_size = reply.remainingSize();
        if (remaining_size != @sizeOf(x11.stage3.QueryTextExtents)) std.debug.panic(
            "expected size {} but got {}",
            .{ @sizeOf(x11.stage3.QueryTextExtents), remaining_size },
        );
        const extents = try x11.read3(.QueryTextExtents, reader);
        std.log.info("text extents: {}", .{extents});
        break :blk .{
            .width = @intCast(extents.overall_width),
            .height = @intCast(extents.font_ascent + extents.font_descent),
            .font_left = @intCast(extents.overall_left),
            .font_ascent = extents.font_ascent,
        };
    };

    try sink.MapWindow(ids.window());

    var key_log: x11.BoundedArray(KeyEvent, 80) = .{ .len = 0, .buffer = undefined };
    var key_log_next: usize = 0;

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
            .KeyPress => {
                const event = try msg1.read2(.KeyPress, reader);
                if (keymap.getKeysym(event.keycode, event.state.mod())) |keysym| {
                    // std.log.info("key_press: mod={} sym={} {}", .{ event.state.mod(), keysym, event.keycode });
                    key_log.buffer[key_log_next] = .{
                        .keycode = event.keycode,
                        .mask = event.state,
                        .keysym = keysym,
                    };
                    key_log_next = (key_log_next + 1) % key_log.buffer.len;
                    key_log.len = @max(key_log_next, key_log.len);
                    try render(
                        &sink,
                        ids.window(),
                        ids.gc(),
                        dbe,
                        &font_dims,
                        key_log.slice(),
                        key_log_next,
                    );
                } else |err| switch (err) {
                    error.KeycodeTooSmall => {
                        std.log.err("keycode {} is too small", .{event.keycode});
                    },
                }
            },
            .KeyRelease => {
                const event = try msg1.read2(.KeyRelease, reader);
                _ = event;
                std.log.err("TODO: handle key release", .{});
            },
            .Expose => {
                const expose = try msg1.read2(.Expose, reader);
                std.log.info("expose: {}", .{expose});
                try render(
                    &sink,
                    ids.window(),
                    ids.gc(),
                    dbe,
                    &font_dims,
                    key_log.slice(),
                    key_log_next,
                );
            },
            else => std.debug.panic("unexpected message {f}", .{msg1.readFmt(reader)}),
        }
    }
}

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

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

const KeyEvent = struct {
    keycode: u8,
    mask: x11.KeyButtonMask,
    keysym: x11.charset.Combined,
};

fn render(
    sink: *x11.RequestSink,
    window: x11.Window,
    gc_id: x11.GraphicsContext,
    dbe: Dbe,
    font_dims: *const FontDims,
    key_log: []const KeyEvent,
    key_log_next: usize,
) !void {
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

    const margin_left = 5;
    const margin_top = 5;

    const line_height = font_dims.height;

    {
        const text = x11.SliceWithMaxLen(u8, [*]const u8, 254).initComptime("Idx: Cod Mod    -> Sym");
        try renderString(
            sink,
            target_drawable,
            gc_id,
            text,
            .{
                .x = margin_left,
                .y = @intCast(margin_top + line_height),
            },
        );
    }

    var key_log_previous_index = key_log_next;
    for (0..key_log.len) |row| {
        var text_buf: [254]u8 = undefined;

        const key_log_index = blk: {
            if (key_log_previous_index == 0) break :blk key_log.len - 1;
            break :blk key_log_previous_index - 1;
        };
        key_log_previous_index = key_log_index;
        const mod_string: []const u8 = switch (key_log[key_log_index].mask.mod()) {
            .lower => "lower0",
            .upper => "upper0",
            .lower_mod => "lower1",
            .upper_mod => "upper1",
        };
        const text = std.fmt.bufPrint(&text_buf, "{: >3}: {: >3} {s} -> {s}", .{
            row,
            key_log[key_log_index].keycode,
            mod_string,
            @tagName(key_log[key_log_index].keysym),
        }) catch unreachable;
        const text_x11 = x11.SliceWithMaxLen(u8, [*]const u8, text_buf.len){
            .ptr = text.ptr,
            .len = std.math.cast(u8, text.len) orelse std.debug.panic("TODO: handle text with {} bytes", .{text.len}),
        };
        try renderString(
            sink,
            target_drawable,
            gc_id,
            text_x11,
            .{
                .x = margin_left,
                .y = @intCast(margin_top + ((row + 2) * line_height)),
            },
        );
    }

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
    text: x11.SliceWithMaxLen(u8, [*]const u8, 254),
    pos: x11.XY(i16),
) !void {
    try sink.PolyText8(
        drawable,
        gc,
        pos,
        &[_]x11.TextItem8{
            .{ .text_element = .{ .delta = 0, .string = text } },
        },
    );
}

const std = @import("std");
const x11 = @import("x11");
