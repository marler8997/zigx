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
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // no need to deinit
    const cmdline = try Cmdline.alloc(arena_instance.allocator());

    var opt: struct {
        font_file: ?[]const u8 = null,
        size: f32 = 24.0,
    } = .{};

    {
        var i: usize = 1;
        while (i < cmdline.len()) : (i += 1) {
            const arg = cmdline.arg(i);
            if (std.mem.eql(u8, arg, "--font")) {
                i += 1;
                if (i == cmdline.len()) errExit("--font missing arg", .{});
                opt.font_file = cmdline.arg(i);
            } else if (std.mem.eql(u8, arg, "--size")) {
                i += 1;
                if (i == cmdline.len()) errExit("--size missing arg", .{});
                const size_str = cmdline.arg(i);
                opt.size = std.fmt.parseFloat(f32, size_str) catch errExit("invalid --size '{s}'", .{size_str});
            } else errExit("unknown cmdline option '{s}'", .{arg});
        }
    }

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

    var window_size: XY(u16) = .{ .x = 600, .y = 700 };

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

    const ttf_content = blk: {
        if (opt.font_file) |font_file| {
            break :blk std.fs.cwd().readFileAlloc(
                arena_instance.allocator(),
                font_file,
                std.math.maxInt(usize),
            ) catch |e| errExit(
                "read '{s}' failed with {s}",
                .{ font_file, @errorName(e) },
            );
        }
        break :blk @embedFile("InterVariable.ttf");
    };
    const ttf: TrueType = try .load(ttf_content);
    var font_size: f32 = opt.size;
    var font: Font = try .init(std.heap.page_allocator, &ttf, font_ids, .{
        .size = font_size,
        .color = 0xffffff,
    });
    defer font.deinit(std.heap.page_allocator, &sink) catch |err| @panic(@errorName(err));
    var glyph_arena: ArenaAllocator = .init(std.heap.page_allocator);

    var sliding: bool = false;
    var layout: Layout = .{
        .slider = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };

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
            .ButtonPress => {
                const msg = try source.read2(.ButtonPress);
                if (msg.button == 1) {
                    const pt: XY(i16) = .{ .x = msg.event_x, .y = msg.event_y };
                    if (rectContains(layout.slider, pt)) {
                        sliding = true;
                        do_render = try updateFontSize(&sink, &font_size, &font, layout.slider, pt.x);
                    }
                }
            },
            .ButtonRelease => {
                const msg = try source.read2(.ButtonRelease);
                if (msg.button == 1) {
                    sliding = false;
                }
            },
            .MotionNotify => {
                const msg = try source.read2(.MotionNotify);
                if (sliding) {
                    const pt: XY(i16) = .{ .x = msg.event_x, .y = msg.event_y };
                    do_render = try updateFontSize(&sink, &font_size, &font, layout.slider, pt.x);
                }
            },
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
            .MapNotify,
            .MappingNotify,
            .ReparentNotify,
            => try source.discardRemaining(),
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
        }
        if (do_render) {
            layout = try render(
                &glyph_arena,
                &sink,
                ids,
                dbe,
                &font,
                window_size,
                font_size,
                opt.font_file,
            );
        }
    }
}

fn updateFontSize(
    sink: *x11.RequestSink,
    font_size: *f32,
    font: *Font,
    slider_rect: x11.Rectangle,
    x: i16,
) !bool {
    const new_font_size: f32 = blk: {
        const offset: i32 = if (x < slider_rect.x) 0 else @intCast(x - slider_rect.x);
        const slot = if (offset >= slider_rect.width) slider_rect.width else offset;
        const ratio = @as(f32, @floatFromInt(slot)) / @as(f32, @floatFromInt(slider_rect.width));
        break :blk font_min + (ratio * (font_max - font_min));
    };
    if (new_font_size == font_size.*) return false;
    try font.reset(sink, .{ .new_size = new_font_size });
    font_size.* = new_font_size;
    return true;
}

const font_min: f32 = 1.0;
const font_max: f32 = 100.0;

fn rectContains(rect: x11.Rectangle, pt: XY(i16)) bool {
    return pt.x >= rect.x and
        pt.x < (rect.x + @as(i16, @intCast(rect.width))) and
        pt.y >= rect.y and
        pt.y < (rect.y + @as(i16, @intCast(rect.height)));
}

const Layout = struct {
    slider: x11.Rectangle,
};

fn render(
    glyph_arena: *ArenaAllocator,
    sink: *x11.RequestSink,
    ids: Ids,
    dbe: Dbe,
    font: *Font,
    window_size: XY(u16),
    font_size: f32,
    font_file: ?[]const u8,
) !Layout {
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
    const drawable: x11.Drawable = if (dbe.backBuffer()) |back_buffer| back_buffer else window.drawable();

    const slider_margin_left = 10;
    const slider_rail_half_height = 2;
    const slider_half_height = 9;
    const slider_margin_top = 10;
    const slider_width = 300;
    const layout: Layout = .{
        .slider = .{
            .x = slider_margin_left,
            .y = slider_margin_top,
            .width = slider_width,
            .height = slider_half_height * 2,
        },
    };
    const slider_ratio: f32 = (font_size - font_min) / font_max;
    const slider_pos: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(layout.slider.width)) * slider_ratio));
    const slider_rail_y = layout.slider.y + slider_half_height - slider_rail_half_height;
    try sink.PolyFillRectangle(drawable, gc, .initAssume(&[_]x11.Rectangle{
        .{ .x = layout.slider.x, .y = slider_rail_y, .width = layout.slider.width, .height = slider_rail_half_height * 2 },
        .{ .x = @intCast(slider_margin_left + slider_pos - 1), .y = 10, .width = 3, .height = slider_half_height * 2 },
    }));

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
    try writer.newline();
    try writer.interface.print("size: {d}", .{font_size});
    try underline(&writer, margin);
    try writer.newline();
    if (font_file) |f| {
        try writer.interface.print("{s}", .{f});
    } else {
        try writer.interface.writeAll("builtin font InterVariable.ttf");
    }
    try underline(&writer, margin);
    try writer.newline();
    try writer.interface.print("Hello, {s}! These glyphs are missing: こんにちは", .{"World"});
    try underline(&writer, margin);
    try writer.newline();
    try writer.newline();
    try writer.interface.writeAll("0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    try underline(&writer, margin);
    try writer.newline();
    try writer.interface.writeAll("abcdefghijklmnopqrstuvwxyz");
    try underline(&writer, margin);
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
    return layout;
}

fn underline(
    writer: *Font.TextWriter,
    left: i16,
) !void {
    try writer.interface.flush();
    try writer.sink.PolyFillRectangle(writer.drawable, writer.gc, .initAssume(&[_]x11.Rectangle{
        .{ .x = left, .y = @intCast(writer.cursor.y), .width = @intCast(writer.cursor.x - left), .height = 1 },
    }));
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

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

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
const Font = @import("Font");
const TrueType = Font.TrueType;
const Cmdline = @import("Cmdline.zig");
