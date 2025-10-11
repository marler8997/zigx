const std = @import("std");
const x11 = @import("x11");

const window_width = 400;
const window_height = 400;

const Ids = struct {
    base: x11.ResourceBase,
    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn bg_gc(self: Ids) x11.GraphicsContext {
        return self.base.add(1).graphicsContext();
    }
    pub fn fg_gc(self: Ids) x11.GraphicsContext {
        return self.base.add(2).graphicsContext();
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

    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = screen.root,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
            .border_width = 0,
            .class = .input_output,
            .visual_id = screen.root_visual,
        },
        .{
            .bg_pixel = x11.rgbFrom24(screen.root_depth, 0xbbccdd),
            .event_mask = .{ .Exposure = 1 },
        },
    );

    try sink.CreateGc(
        ids.bg_gc(),
        ids.window().drawable(),
        .{ .foreground = screen.black_pixel },
    );
    try sink.CreateGc(
        ids.fg_gc(),
        ids.window().drawable(),
        .{
            .background = screen.black_pixel,
            .foreground = x11.rgbFrom24(screen.root_depth, 0xffaadd),
        },
    );

    const font_dims: FontDims = blk: {
        try sink.QueryTextExtents(ids.fg_gc().fontable(), .initComptime(&[_]u16{'m'}));
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
                try render(&sink, ids.window(), ids.bg_gc(), ids.fg_gc(), font_dims);
            },
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
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
    bg_gc_id: x11.GraphicsContext,
    fg_gc_id: x11.GraphicsContext,
    font_dims: FontDims,
) !void {
    try sink.PolyFillRectangle(
        window_id.drawable(),
        bg_gc_id,
        .initComptime(&[_]x11.Rectangle{
            .{ .x = 100, .y = 100, .width = 200, .height = 200 },
        }),
    );
    try sink.ClearArea(
        window_id,
        .{
            .x = 150,
            .y = 150,
            .width = 100,
            .height = 100,
        },
        .{ .exposures = false },
    );
    const text = "Hello X!";
    const text_width = font_dims.width * text.len;
    try sink.ImageText8(
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = @divTrunc((window_width - @as(i16, @intCast(text_width))), 2) + font_dims.font_left,
            .y = @divTrunc((window_height - @as(i16, @intCast(font_dims.height))), 2) + font_dims.font_ascent,
        },
        .initComptime(text),
    );
}
