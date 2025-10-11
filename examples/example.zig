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
    var sink: x11.RequestSink = .{ .writer = writer };

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
            .bg_pixel = 0xaabbccdd,
            .event_mask = .{
                .KeyPress = 1,
                .KeyRelease = 1,
                .ButtonPress = 1,
                .ButtonRelease = 1,
                .EnterWindow = 1,
                .LeaveWindow = 1,
                .PointerMotion = 1,
                .Exposure = 1,
            },
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
            .foreground = 0xffaadd,
        },
    );

    const font_dims: FontDims = blk: {
        try sink.QueryTextExtents(ids.fg_gc().fontable(), .initComptime(&[_]u16{'m'}));
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
            .KeyPress,
            .KeyRelease,
            .ButtonPress,
            .ButtonRelease,
            .EnterNotify,
            .LeaveNotify,
            => {
                std.log.info("{f}", .{msg1.readFmt(reader)});
            },
            .MotionNotify => {
                const motion_notify = try msg1.read2(.MotionNotify, reader);
                // too much logging
                if (false) std.log.info("{}", .{motion_notify});
            },
            .Expose => {
                const expose = try msg1.read2(.Expose, reader);
                std.log.info("{}", .{expose});
                try render(&sink, ids.window(), ids.bg_gc(), ids.fg_gc(), font_dims);
            },
            else => std.debug.panic("unexpected message {f}", .{msg1.readFmt(reader)}),
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
