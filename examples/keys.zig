const window_width = 300;
const window_height = 800;

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

pub fn main() !u8 {
    try x11.wsaStartup();

    const Screen = struct {
        window: x11.Window,
        visual: x11.Visual,
        depth: x11.Depth,
    };

    const stream: std.net.Stream, const ids: Ids, const keyrange: x11.KeycodeRange, const screen: Screen = blk: {
        var read_buffer: [1000]u8 = undefined;
        var socket_reader, const used_auth = try x11.draft.connect(&read_buffer);
        errdefer x11.disconnect(socket_reader.getStream());
        _ = used_auth;
        const setup = try x11.readSetupSuccess(socket_reader.interface());
        std.log.info("setup reply {f}", .{setup});
        var source: x11.Source = .initFinishSetup(socket_reader.interface(), &setup);
        const screen = try x11.draft.readSetupDynamic(&source, &setup, .{}) orelse {
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

    const keymap: x11.keymap.Full = try .initSynchronous(&sink, &source, keyrange);

    try sink.CreateWindow(.{
        .window_id = ids.window(),
        .parent_window_id = screen.window,
        .depth = 0, // we don't care, just inherit from the parent
        .x = 0,
        .y = 0,
        .width = window_width,
        .height = window_height,
        .border_width = 0, // TODO: what is this?
        .class = .input_output,
        .visual_id = screen.visual,
    }, .{
        .bg_pixel = 0x332211,
        .bit_gravity = .north_west,
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
    const present_ext = try x11.draft.synchronousQueryExtension(
        &source,
        &sink,
        x11.present.name,
    ) orelse {
        std.log.err("Present extension not available", .{});
        return 0xff;
    };

    try x11.present.selectInput(
        &sink,
        present_ext.opcode_base,
        ids.presentEventId(),
        ids.window(),
        .{ .complete_notify = true },
    );

    try sink.CreatePixmap(ids.pixmap(), ids.window().drawable(), .{
        .depth = screen.depth,
        .width = window_width,
        .height = window_height,
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

    var key_log: x11.BoundedArray(KeyEvent, 80) = .{ .len = 0, .buffer = undefined };
    var key_log_next: usize = 0;
    var present_serial: u32 = 0;
    var render_in_flight = false;
    var dirty = false;

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
                    dirty = true;
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
                _ = try source.read2(.Expose);
                dirty = true;
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
            .MappingNotify => try source.discardRemaining(),
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmtDropError()}),
        }
        if (dirty and !render_in_flight) {
            try render(
                &sink,
                ids.pixmap(),
                ids.gc(),
                &font_dims,
                key_log.slice(),
                key_log_next,
            );
            present_serial +%= 1;
            try x11.present.presentPixmap(&sink, present_ext.opcode_base, ids.window(), ids.pixmap(), present_serial, 0, 0, 0);
            render_in_flight = true;
            dirty = false;
        }
    }
}

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
    pixmap: x11.Pixmap,
    gc_id: x11.GraphicsContext,
    font_dims: *const FontDims,
    key_log: []const KeyEvent,
    key_log_next: usize,
) !void {
    const drawable = pixmap.drawable();
    try sink.ChangeGc(gc_id, .{ .foreground = 0x332211 });
    try sink.PolyFillRectangle(drawable, gc_id, .initAssume(&.{.{
        .x = 0,
        .y = 0,
        .width = window_width,
        .height = window_height,
    }}));
    try sink.ChangeGc(gc_id, .{ .foreground = 0xaabbff });

    const margin_left = 5;
    const margin_top = 5;

    const line_height = font_dims.height;

    {
        const text = x11.SliceWithMaxLen(u8, [*]const u8, 254).initComptime("Idx: Cod Mod    -> Sym");
        try renderString(
            sink,
            drawable,
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
            drawable,
            gc_id,
            text_x11,
            .{
                .x = margin_left,
                .y = @intCast(margin_top + ((row + 2) * line_height)),
            },
        );
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
