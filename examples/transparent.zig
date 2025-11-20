const std = @import("std");
const x11 = @import("x11");

const window_width = 400;
const window_height = 400;

const global = struct {
    var transparent_visual: x11.Visual = .copy_from_parent;
};

const Ids = struct {
    base: x11.ResourceBase,
    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.base.add(1).graphicsContext();
    }
    pub fn colormap(self: Ids) x11.Colormap {
        return self.base.add(3).colormap();
    }
};

pub fn main() !void {
    try x11.wsaStartup();

    const stream: std.net.Stream, const ids: Ids, const root_window: x11.Window = blk: {
        var read_buffer: [1000]u8 = undefined;
        var socket_reader, const used_auth = try x11.draft.connect(&read_buffer);
        errdefer x11.disconnect(socket_reader.getStream());
        _ = used_auth;
        const setup = try x11.readSetupSuccess(socket_reader.interface());
        std.log.info("setup reply {f}", .{setup});
        var source: x11.Source = .initFinishSetup(socket_reader.interface(), &setup);
        const screen = try x11.draft.readSetupDynamic(&source, &setup, .{
            .on_visual = onVisual,
        }) orelse {
            std.log.err("no screen?", .{});
            std.process.exit(0xff);
        };
        if (global.transparent_visual == .copy_from_parent) {
            std.log.info("no visual compatible with transparency", .{});
            std.process.exit(0xff);
        }
        break :blk .{
            socket_reader.getStream(),
            .{ .base = setup.resource_id_base },
            screen.root,
        };
    };
    defer x11.disconnect(stream);

    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = x11.socketWriter(stream, &write_buffer);
    var socket_reader = x11.socketReader(stream, &read_buffer);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .initAfterSetup(socket_reader.interface());

    if (global.transparent_visual == .copy_from_parent) {
        std.log.info("TransparentVisual: none", .{});
    } else {
        std.log.info("TransparentVisual: {}", .{@intFromEnum(global.transparent_visual)});
    }

    try sink.CreateColormap(
        .none,
        ids.colormap(),
        root_window,
        global.transparent_visual,
    );

    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = root_window,
            .depth = 32,
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
            .border_width = 0,
            .class = .input_output,
            .visual_id = global.transparent_visual,
        },
        .{
            .bg_pixel = 0, // fully transparent background
            .border_pixel = 0, // transparent border
            .colormap = ids.colormap(),
            .event_mask = .{ .Exposure = 1 },
        },
    );

    try sink.CreateGc(ids.gc(), ids.window().drawable(), .{});

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
            .Expose => {
                const expose = try source.read2(.Expose);
                std.log.info("X11 {}", .{expose});
                try render(&sink, ids.window(), ids.gc(), font_dims);
            },
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
        }
    }
}

fn onVisual(
    screen_index: u8,
    depth: u8,
    visual_index: u16,
    visual: *const x11.VisualType,
) void {
    std.log.info(
        "X11 Visual screen[{}] depth {} visual[{}] id={} class={f} bits-per-ch={} map_cnt={} red=0x{x} grn=0x{x} blu=0x{x}",
        .{
            screen_index,
            depth,
            visual_index,
            @intFromEnum(visual.id),
            x11.fmtEnum(visual.class),
            visual.bits_per_rgb_value,
            visual.colormap_entries,
            visual.red_mask,
            visual.green_mask,
            visual.blue_mask,
        },
    );
    if (global.transparent_visual == .copy_from_parent) {
        if (screen_index == 0 and
            depth == 32 and
            visual.class == .true_color and
            visual.bits_per_rgb_value == 8 and
            visual.colormap_entries == 256 and
            visual.red_mask == 0xff0000 and
            visual.green_mask == 0xff00 and
            visual.blue_mask == 0xff)
        {
            global.transparent_visual = visual.id;
        }
    }
}

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

fn render(
    sink: *x11.RequestSink,
    window_id: x11.Window,
    gc: x11.GraphicsContext,
    font_dims: FontDims,
) !void {
    try sink.ChangeGc(gc, .{
        .background = 0,
        .foreground = 0xffffff,
    });
    const text = "Hello X!";
    const text_width = font_dims.width * text.len;
    try sink.ImageText8(
        window_id.drawable(),
        gc,
        .{
            .x = @divTrunc((window_width - @as(i16, @intCast(text_width))), 2) + font_dims.font_left,
            .y = @divTrunc((window_height - @as(i16, @intCast(font_dims.height))), 2) + font_dims.font_ascent,
        },
        .initComptime(text),
    );
}
