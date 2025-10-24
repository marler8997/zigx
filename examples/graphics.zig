const std = @import("std");
const x11 = @import("x11");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 400;
const window_height = 400;

const Ids = struct {
    base: x11.ResourceBase,
    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn bg(self: Ids) x11.GraphicsContext {
        return self.base.add(1).graphicsContext();
    }
    pub fn fg(self: Ids) x11.GraphicsContext {
        return self.base.add(2).graphicsContext();
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

    const ids: Ids = .{ .base = setup.resource_id_base };

    try sink.CreateWindow(.{
        .window_id = ids.window(),
        .parent_window_id = screen.root,
        .x = 0,
        .y = 0,
        .width = window_width,
        .height = window_height,
        .border_width = 0, // TODO: what is this?
        .class = .input_output,
        .visual_id = screen.root_visual,
        .depth = 0,
    }, .{
        .bg_pixel = x11.rgbFrom24(screen.root_depth, 0xbbccdd),
        .event_mask = .{ .Exposure = 1 },
    });
    try sink.CreateGc(
        ids.bg(),
        ids.window().drawable(),
        .{ .foreground = screen.black_pixel },
    );
    try sink.CreateGc(
        ids.fg(),
        ids.window().drawable(),
        .{
            .background = screen.black_pixel,
            .foreground = x11.rgbFrom24(screen.root_depth, 0x884411),
            .line_width = 10,
        },
    );

    const font_dims: FontDims = blk: {
        try sink.QueryTextExtents(ids.fg().fontable(), .initComptime(&[_]u16{'m'}));
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
            else => |e| switch (io.socket_reader.getError() orelse e) {
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
                try render(&sink, ids.window(), ids.bg(), ids.fg(), font_dims);
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
    //    {
    //        var msg: [x11.poly_fill_rectangle.getLen(1)]u8 = undefined;
    //        x11.poly_fill_rectangle.serialize(&msg, .{
    //            .drawable_id = drawable_id,
    //            .gc_id = bg_gc_id,
    //        }, &[_]x11.Rectangle {
    //            .{ .x = 100, .y = 100, .width = 200, .height = 200 },
    //        });
    //        try x11.ext.send(sock, &msg);
    //    }
    _ = bg_gc_id;
    try sink.ClearArea(
        window_id,
        .{
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
        },
        .{ .exposures = false },
    );

    _ = font_dims;
    try sink.PolyLine(
        .origin,
        window_id.drawable(),
        fg_gc_id,
        .initComptime(&[_]x11.XY(i16){
            .{ .x = 10, .y = 10 },
            .{ .x = 110, .y = 10 },
            .{ .x = 55, .y = 55 },
        }),
    );
}
