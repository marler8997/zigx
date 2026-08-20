const std = @import("std");
const std16 = if (zig_atleast_16) std else @import("std16");
const x11 = @import("x11");

const zig_atleast_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

const window_width = 400;
const window_height = 400;

const Ids = struct {
    range: x11.IdRange,
    pub fn window(self: Ids) x11.Window {
        return self.range.addAssumeCapacity(0).window();
    }
    pub fn bg_gc(self: Ids) x11.GraphicsContext {
        return self.range.addAssumeCapacity(1).graphicsContext();
    }
    pub fn fg_gc(self: Ids) x11.GraphicsContext {
        return self.range.addAssumeCapacity(2).graphicsContext();
    }
    const needed_capacity = 3;
};

const Root = struct {
    window: x11.Window,
    visual: x11.Visual,
    depth: x11.Depth,
};

pub const main = if (zig_atleast_16) mainAtleast16 else mainBefore16;
fn mainAtleast16(init: std.process.Init.Minimal) !void {
    var t: @import("Threaded") = .init_single_threaded;
    try mainCompat(init.environ, t.io());
}
fn mainBefore16() !void {
    try mainCompat(.{}, .legacy);
}
pub fn mainCompat(environ: std16.process.Environ, io: std16.Io) !void {
    try x11.wsaStartup();

    const socket: x11.Socket, const ids: Ids, const root: Root = blk: {
        var read_buffer: [1000]u8 = undefined;
        var socket_reader, const used_auth = try x11.draft.connect(io, environ, &read_buffer);
        errdefer x11.disconnect(io, socket_reader.socket);
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
            socket_reader.socket, .{ .range = id_range },
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
    defer x11.disconnect(io, socket);

    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = x11.socketWriter(io, socket, &write_buffer);
    var socket_reader = x11.socketReader(io, socket, &read_buffer);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .initAfterSetup(&socket_reader.interface);
    run(ids, &root, &sink, &source) catch |err| switch (err) {
        error.WriteFailed => |e| return x11.onWriteError(e, socket_writer.err.?),
        error.ReadFailed, error.EndOfStream, error.Protocol => |e| return source.onReadError(e, socket_reader.err),
        error.UnexpectedMessage => |e| return e,
    };
}

fn run(
    ids: Ids,
    root: *const Root,
    sink: *x11.RequestSink,
    source: *x11.Source,
) error{ WriteFailed, ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!void {
    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = root.window,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
            .border_width = 0,
            .class = .input_output,
            .visual_id = root.visual,
        },
        .{
            .bg_pixel = root.depth.rgbFrom24(0xbbccdd),
            .event_mask = .{ .Exposure = 1 },
        },
    );

    try sink.CreateGc(
        ids.bg_gc(),
        ids.window().drawable(),
        .{ .foreground = root.depth.rgbFrom24(0) },
    );
    try sink.CreateGc(
        ids.fg_gc(),
        ids.window().drawable(),
        .{
            .background = root.depth.rgbFrom24(0),
            .foreground = root.depth.rgbFrom24(0xffaadd),
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
        const msg_kind = try source.readKind();
        switch (msg_kind) {
            .Expose => {
                const expose = try source.read2(.Expose);
                std.log.info("X11 {}", .{expose});
                try render(sink, ids.window(), ids.bg_gc(), ids.fg_gc(), font_dims);
            },
            .MappingNotify => {
                const notify = try source.read2(.MappingNotify);
                std.log.info("ignoring {}", .{notify});
            },
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmtDropError()}),
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
