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
    pub fn glyphGc(self: Ids) x11.GraphicsContext {
        return self.base.add(3).graphicsContext();
    }
    pub fn glyphPixmap(self: Ids, index: Font.GlyphIndex) x11.Pixmap {
        const offset = 4;
        comptime assert(offset + std.math.maxInt(@typeInfo(Font.GlyphIndex).@"enum".tag_type) < std.math.maxInt(u32));
        return self.base.add(offset + @intFromEnum(index)).pixmap();
    }
    pub fn font(self: Ids) Font.Ids {
        return .{
            .window = self.window(),
            .glyph_gc = self.base.add(4).graphicsContext(),
            .glyphs_base = @enumFromInt(@intFromEnum(self.base.add(5))),
            .glyphs_len = 4096,
        };
    }
};

pub fn main() !void {
    try x11.wsaStartup();

    const Screen = struct {
        window: x11.Window,
        visual: x11.Visual,
        depth: x11.Depth,
    };
    const stream: std.net.Stream, const ids: Ids, const screen: Screen = blk: {
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
        break :blk .{
            socket_reader.getStream(), .{ .base = setup.resource_id_base }, .{
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

    var window_size: XY(u16) = .{ .x = 600, .y = 300 };

    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = screen.window,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = window_size.x,
            .height = window_size.y,
            .border_width = 0,
            .class = .input_output,
            .visual_id = screen.visual,
        },
        .{
            .bg_pixel = screen.depth.rgbFrom24(0),
            .event_mask = .{
                .ButtonPress = 1,
                .ButtonRelease = 1,
                .PointerMotion = 1,
                .Exposure = 1,
                .StructureNotify = 1,
            },
        },
    );

    const dbe: Dbe = blk: {
        const ext = try x11.draft.synchronousQueryExtension(&source, &sink, x11.dbe.name) orelse break :blk .unsupported;
        try x11.dbe.Allocate(&sink, ext.opcode_base, ids.window(), ids.backBuffer(), .background);
        break :blk .{ .enabled = .{ .opcode_base = ext.opcode_base, .back_buffer = ids.backBuffer() } };
    };

    try sink.CreateGc(
        ids.gc(),
        ids.window().drawable(),
        .{
            .background = screen.depth.rgbFrom24(0),
            .foreground = screen.depth.rgbFrom24(0xffffff),
            .line_width = 4,
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
        },
    );

    try sink.MapWindow(ids.window());
    const font_ids = ids.font();
    const ttf: TrueType = try .load(@embedFile("InterVariable.ttf"));
    var font: Font = try .init(std.heap.page_allocator, &ttf, font_ids, .{
        .size = 24,
        .color = 0xffffff,
    });
    defer font.deinit(std.heap.page_allocator, &sink) catch |err| @panic(@errorName(err));
    var glyph_arena: ArenaAllocator = .init(std.heap.page_allocator);

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

        var do_render = false;
        switch (msg_kind) {
            .Expose => {
                const expose = try source.read2(.Expose);
                std.log.info("X11 {}", .{expose});
                do_render = true;
            },
            .ConfigureNotify => {
                const msg = try source.read2(.ConfigureNotify);
                std.debug.assert(msg.event == ids.window());
                std.debug.assert(msg.window == ids.window());
                if (window_size.x != msg.width or window_size.y != msg.height) {
                    std.log.info("WindowSize {}x{}", .{ msg.width, msg.height });
                    window_size = .{ .x = msg.width, .y = msg.height };
                    do_render = true;
                }
            },
            .MotionNotify,
            .ButtonPress,
            .ButtonRelease,
            .MapNotify,
            .MappingNotify,
            .ReparentNotify,
            => try source.discardRemaining(),
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
        }
        if (do_render) {
            try render(
                &glyph_arena,
                &sink,
                ids,
                dbe,
                &font,
                window_size,
            );
        }
    }
}

fn render(
    glyph_arena: *ArenaAllocator,
    sink: *x11.RequestSink,
    ids: Ids,
    dbe: Dbe,
    font: *Font,
    window_size: XY(u16),
) !void {
    const window = ids.window();
    const gc = ids.gc();

    if (null == dbe.backBuffer()) {
        try sink.ClearArea(
            window,
            .{
                .x = 0,
                .y = 0,
                .width = window_size.x,
                .height = window_size.y,
            },
            .{ .exposures = false },
        );
    }
    const drawable = if (dbe.backBuffer()) |back_buffer| back_buffer else window.drawable();
    const margin = 50;

    var writer_buf: [16]u8 = undefined;
    var writer: Font.TextWriter = .init(.{
        .font = font,
        .gpa = glyph_arena.allocator(),
        .sink = sink,
        .gc = gc,
        .drawable = drawable,
        .cursor = .{
            .x = margin,
            .y = 30,
        },
        .left_margin = margin,
        .buffer = &writer_buf,
    });

    try writer.interface.print("Hello, {s}! These glyphs are missing: こんにちは", .{"World"});
    try writer.newline();
    try writer.interface.writeAll("The quick brown fox jumped over the lazy dog");
    try writer.newline();
    try writer.interface.writeAll("0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    try writer.newline();
    try writer.interface.writeAll("abcdefghijklmnopqrstuvwxyz");
    try writer.newline();

    writer.left_margin = 300;
    try writer.newline();

    try writer.setAlignment(.right);
    try writer.interface.writeAll("This text is not");
    try writer.interface.writeAll(" centered -- ");
    try writer.setAlignment(.left);
    try writer.interface.writeAll("it");
    try writer.newline();

    try writer.setAlignment(.right);
    try writer.interface.print("is {s} -- ", .{"aligned"});
    try writer.setAlignment(.left);
    try writer.interface.writeAll("so that");
    try writer.newline();

    try writer.setAlignment(.right);
    try writer.interface.writeAll("all the -- ");
    try writer.setAlignment(.left);
    try writer.interface.writeAll("line up.");
    try writer.newline();

    try writer.newline();

    try writer.setAlignment(.center);
    try writer.interface.writeAll("On the other");
    try writer.interface.writeAll("hand...");
    try writer.newline();
    try writer.interface.print("this {s}", .{"text"});
    try writer.newline();
    try writer.interface.writeAll("is centered, and also the last bit is longer than the buffer.");
    try writer.newline();

    switch (dbe) {
        .unsupported => {},
        .enabled => |enabled| try x11.dbe.Swap(sink, enabled.opcode_base, .initAssume(&.{
            .{ .window = window, .action = .background },
        })),
    }
}

const Dbe = union(enum) {
    unsupported,
    enabled: struct {
        opcode_base: u8,
        back_buffer: x11.Drawable,
    },
    pub fn backBuffer(self: Dbe) ?x11.Drawable {
        return switch (self) {
            .unsupported => null,
            .enabled => |enabled| enabled.back_buffer,
        };
    }
};

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const std = @import("std");
const x11 = @import("x11");
const XY = x11.XY;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const TrueType = @import("TrueType");
const Font = @import("Font.zig");
