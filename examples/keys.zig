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
    try x11.draft.authenticate(display, parsed_display, address, &io);
    var sink: x11.RequestSink = .{ .writer = &io.socket_writer.interface };
    var source: x11.Source = .{ .reader = io.socket_reader.interface() };
    const setup = try source.readSetup();
    std.log.info("setup reply {f}", .{setup});
    const screen = try x11.draft.readSetupDynamic(&source, &setup, .{}) orelse {
        std.log.err("no screen?", .{});
        std.process.exit(0xff);
    };

    const ids: Ids = .{ .base = setup.resource_id_base };

    const keymap: x11.keymap.Full = try .initSynchronous(&sink, &source, try .init(
        setup.min_keycode,
        setup.max_keycode,
    ));

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

    const dbe: Dbe = blk: {
        const ext = try x11.draft.synchronousQueryExtension(&source, &sink, x11.dbe.name) orelse break :blk .unsupported;
        try x11.dbe.Allocate(&sink, ext.opcode_base, ids.window(), ids.backBuffer(), .background);
        break :blk .{ .enabled = .{ .opcode = ext.opcode_base, .back_buffer = ids.backBuffer() } };
    };

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

    var key_log: x11.BoundedArray(KeyEvent, 80) = .{ .len = 0, .buffer = undefined };
    var key_log_next: usize = 0;

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
            .KeyPress => {
                const event = try source.read2(.KeyPress);
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
            // NOTE: server will send us KeyRelease when the user holds down a key
            //       even though we didn't register for the KeyRelease event
            .KeyRelease => _ = try source.read2(.KeyRelease),
            .Expose => {
                const expose = try source.read2(.Expose);
                std.log.info("X11 {}", .{expose});
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
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
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
        const text = std.fmt.bufPrint(&text_buf, "{: >3}: {: >3} {s} -> {f}", .{
            row,
            key_log[key_log_index].keycode,
            mod_string,
            x11.fmtEnum(key_log[key_log_index].keysym),
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
