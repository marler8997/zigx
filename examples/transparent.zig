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
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.range.addAssumeCapacity(1).graphicsContext();
    }
    pub fn colormap(self: Ids) x11.Colormap {
        return self.range.addAssumeCapacity(2).colormap();
    }
    pub fn region(self: Ids) x11.fixes.Region {
        return self.range.addAssumeCapacity(3).fixesRegion();
    }
    const needed_capacity = 4;
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

    const socket: x11.Socket, const ids: Ids, const root_window: x11.Window, const transparent_visual: x11.Visual = blk: {
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
        var on_visual: OnVisual = .{};
        const screen = (x11.draft.readSetupDynamic(&source, &setup, .{
            .on_visual = &on_visual.base,
        }) catch |err| switch (err) {
            error.ReadFailed => return socket_reader.err.?,
            error.EndOfStream, error.Protocol => |e| return e,
        }) orelse {
            std.log.err("no screen?", .{});
            std.process.exit(0xff);
        };
        if (on_visual.transparent_visual == .copy_from_parent) {
            std.log.info("no visual compatible with transparency", .{});
            std.process.exit(0xff);
        }
        const id_range = try x11.IdRange.init(setup.resource_id_base, setup.resource_id_mask);
        if (id_range.capacity() < Ids.needed_capacity) {
            std.log.err("X server id range capacity {} is less than needed {}", .{ id_range.capacity(), Ids.needed_capacity });
            std.process.exit(0xff);
        }
        break :blk .{
            socket_reader.socket,
            .{ .range = id_range },
            screen.root,
            on_visual.transparent_visual,
        };
    };
    defer x11.disconnect(io, socket);

    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = x11.socketWriter(io, socket, &write_buffer);
    var socket_reader = x11.socketReader(io, socket, &read_buffer);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .initAfterSetup(&socket_reader.interface);
    run(ids, root_window, transparent_visual, &sink, &source) catch |err| switch (err) {
        error.WriteFailed => |e| return x11.onWriteError(e, socket_writer.err.?),
        error.ReadFailed, error.EndOfStream, error.Protocol => |e| return source.onReadError(e, socket_reader.err),
        error.UnexpectedMessage => |e| return e,
    };
}

fn run(
    ids: Ids,
    root_window: x11.Window,
    transparent_visual: x11.Visual,
    sink: *x11.RequestSink,
    source: *x11.Source,
) error{ WriteFailed, ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!void {
    const fixes: Fixes = blk: {
        const ext = try x11.draft.synchronousQueryExtension(source, sink, x11.fixes.name) orelse break :blk .unsupported;
        // need at leaset 2.0 for regions
        try x11.fixes.request.QueryVersion(sink, ext.opcode_base, 2, 0);
        try sink.writer.flush();
        const version, _ = try source.readSynchronousReplyFull(sink.sequence, .fixes_QueryVersion);
        std.log.info("XFIXES version {}.{}", .{ version.major, version.minor });
        if (version.major < 2) break :blk .unsupported;
        break :blk .{ .enabled = .{ .opcode_base = ext.opcode_base } };
    };

    std.log.info("TransparentVisual: {}", .{@intFromEnum(transparent_visual)});

    try sink.CreateColormap(
        .none,
        ids.colormap(),
        root_window,
        transparent_visual,
    );

    const make_overlay = false;

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
            .visual_id = transparent_visual,
        },
        .{
            .bg_pixel = 0, // fully transparent background
            .border_pixel = 0, // transparent border
            .colormap = ids.colormap(),
            .event_mask = .{ .Exposure = 1 },
            // circumvents the window manager, no title bar, allows input passthrough
            .override_redirect = make_overlay,
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

    switch (fixes) {
        .unsupported => {},
        .enabled => |enabled| {
            try x11.fixes.request.CreateRegion(sink, enabled.opcode_base, ids.region(), &.{});
            try x11.fixes.request.SetWindowShapeRegion(
                sink,
                enabled.opcode_base,
                ids.window(),
                .input, // shape kind for input
                0, // x offset
                0, // y offset
                ids.region(),
            );
        },
    }

    try sink.MapWindow(ids.window());

    while (true) {
        try sink.writer.flush();
        const msg_kind = try source.readKind();
        switch (msg_kind) {
            .Expose => {
                const expose = try source.read2(.Expose);
                std.log.info("X11 {}", .{expose});
                try render(sink, ids.window(), ids.gc(), font_dims);
            },
            .MappingNotify => try source.discardRemaining(),
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmtDropError()}),
        }
    }
}

const Fixes = union(enum) {
    unsupported,
    enabled: struct {
        opcode_base: u8,
    },
};

const OnVisual = struct {
    base: x11.draft.OnVisual = .{ .func = onVisual },
    transparent_visual: x11.Visual = .copy_from_parent,
    fn onVisual(
        base: *x11.draft.OnVisual,
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

        const on: *OnVisual = @fieldParentPtr("base", base);

        if (on.transparent_visual == .copy_from_parent) {
            if (screen_index == 0 and
                depth == 32 and
                visual.class == .true_color and
                visual.bits_per_rgb_value == 8 and
                visual.colormap_entries == 256 and
                visual.red_mask == 0xff0000 and
                visual.green_mask == 0xff00 and
                visual.blue_mask == 0xff)
            {
                on.transparent_visual = visual.id;
            }
        }
    }
};

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
