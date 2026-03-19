const Ids = struct {
    range: x11.IdRange,

    pub fn window(self: Ids) x11.Window {
        return self.range.addAssumeCapacity(0).window();
    }
    // Glyph IDs are placed right after the window ID, just to demonstrate that
    // they don't have to be at the beginning or end of the range.
    const glyph_offset = 1;
    const after_glyphs = glyph_offset + Font.max_glyphs;
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.range.addAssumeCapacity(after_glyphs + 0).graphicsContext();
    }
    pub fn pixmap(self: Ids) x11.Pixmap {
        return self.range.addAssumeCapacity(after_glyphs + 1).pixmap();
    }
    pub fn glyphGc(self: Ids) x11.GraphicsContext {
        return self.range.addAssumeCapacity(after_glyphs + 2).graphicsContext();
    }
    pub fn presentEventId(self: Ids) u32 {
        return @intFromEnum(self.range.addAssumeCapacity(after_glyphs + 3));
    }
    pub fn font(self: Ids) Font.Ids {
        return .{
            .window = self.window(),
            .glyph_gc = self.glyphGc(),
            .range = self.range,
            .glyph_offset = glyph_offset,
        };
    }
    const needed_capacity = after_glyphs + 4;
};

const Root = struct {
    window: x11.Window,
    visual: x11.Visual,
    depth: x11.Depth,
};

const Options = struct {
    font_file: ?[]const u8 = null,
    size: f32 = 24.0,
};

pub fn main() !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // no need to deinit
    const cmdline = try Cmdline.alloc(arena_instance.allocator());

    var opt: Options = .{};

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

    const stream: std.net.Stream, const ids: Ids, const root: Root = blk: {
        var read_buffer: [1000]u8 = undefined;
        var socket_reader, const used_auth = try x11.draft.connect(&read_buffer);
        errdefer x11.disconnect(socket_reader.getStream());
        _ = used_auth;
        const setup = x11.readSetupSuccess(socket_reader.interface()) catch |err| switch (err) {
            error.ReadFailed => return socket_reader.getError().?,
            error.EndOfStream, error.Protocol => |e| return e,
        };
        std.log.info("setup reply {f}", .{setup});
        var source: x11.Source = .initFinishSetup(socket_reader.interface(), &setup);
        const screen = (x11.draft.readSetupDynamic(&source, &setup, .{}) catch |err| switch (err) {
            error.ReadFailed => return socket_reader.getError().?,
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
            socket_reader.getStream(), .{ .range = id_range }, .{
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
    run(ids, &root, &sink, &source, &arena_instance, opt) catch |err| switch (err) {
        error.WriteFailed => |e| return x11.onWriteError(e, socket_writer.err.?),
        error.ReadFailed, error.EndOfStream, error.Protocol => |e| return source.onReadError(e, socket_reader.getError()),
        error.UnexpectedMessage => |e| return e,
    };
}

fn run(
    ids: Ids,
    root: *const Root,
    sink: *x11.RequestSink,
    source: *x11.Source,
    arena_instance: *std.heap.ArenaAllocator,
    opt: Options,
) error{ WriteFailed, ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!void {
    var window_size: XY(u16) = .{ .x = 600, .y = 700 };

    try sink.CreateWindow(
        .{
            .window_id = ids.window(),
            .parent_window_id = root.window,
            .depth = 0,
            .x = 0,
            .y = 0,
            .width = window_size.x,
            .height = window_size.y,
            .border_width = 0,
            .class = .input_output,
            .visual_id = root.visual,
        },
        .{
            .bg_pixel = root.depth.rgbFrom24(0),
            .event_mask = .{
                .ButtonPress = 1,
                .ButtonRelease = 1,
                .PointerMotion = 1,
                .Exposure = 1,
                .StructureNotify = 1,
            },
        },
    );

    try sink.CreateGc(
        ids.gc(),
        ids.window().drawable(),
        .{
            .background = root.depth.rgbFrom24(0),
            .foreground = root.depth.rgbFrom24(0xffffff),
            .line_width = 4,
            // prevent NoExposure events when we send CopyArea
            .graphics_exposures = false,
        },
    );
    const present_ext = try x11.draft.synchronousQueryExtension(source, sink, x11.present.name) orelse {
        std.log.err("Present extension not available", .{});
        std.process.exit(0xff);
    };

    try x11.present.selectInput(
        sink,
        present_ext.opcode_base,
        ids.presentEventId(),
        ids.window(),
        .{ .complete_notify = true },
    );

    try sink.CreatePixmap(ids.pixmap(), ids.window().drawable(), .{
        .depth = root.depth,
        .width = window_size.x,
        .height = window_size.y,
    });

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
    const ttf: TrueType = TrueType.load(ttf_content) catch |e| @panic(@errorName(e));
    var font_size: f32 = opt.size;
    var cached_glyphs_store: Font.GlyphSet = undefined;
    var font: Font = Font.init(&ttf, font_ids, .{
        .size = font_size,
        .color = 0xffffff,
    }, &cached_glyphs_store) catch |e| @panic(@errorName(e));
    defer font.deinit(sink) catch |err| @panic(@errorName(err));
    var glyph_arena: ArenaAllocator = .init(std.heap.page_allocator);

    var sliding: bool = false;
    var layout: Layout = .{
        .slider = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
    var present_serial: u32 = 0;
    var render_in_flight = false;
    var dirty = false;

    while (true) {
        try sink.writer.flush();
        const msg_kind = try source.readKind();

        switch (msg_kind) {
            .ButtonPress => {
                const msg = try source.read2(.ButtonPress);
                if (msg.button == 1) {
                    const pt: XY(i16) = .{ .x = msg.event_x, .y = msg.event_y };
                    if (rectContains(layout.slider, pt)) {
                        sliding = true;
                        if (try updateFontSize(sink, &font_size, &font, layout.slider, pt.x))
                            dirty = true;
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
                    if (try updateFontSize(sink, &font_size, &font, layout.slider, pt.x))
                        dirty = true;
                }
            },
            .Expose => {
                _ = try source.read2(.Expose);
                dirty = true;
            },
            .ConfigureNotify => {
                const msg = try source.read2(.ConfigureNotify);
                std.debug.assert(msg.event == ids.window());
                std.debug.assert(msg.window == ids.window());
                if (window_size.x != msg.width or window_size.y != msg.height) {
                    std.log.info("WindowSize {}x{}", .{ msg.width, msg.height });
                    window_size = .{ .x = msg.width, .y = msg.height };
                    try sink.FreePixmap(ids.pixmap());
                    try sink.CreatePixmap(ids.pixmap(), ids.window().drawable(), .{
                        .depth = root.depth,
                        .width = window_size.x,
                        .height = window_size.y,
                    });
                    dirty = true;
                }
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
            .MapNotify,
            .ReparentNotify,
            .MappingNotify,
            => try source.discardRemaining(),
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmtDropError()}),
        }
        if (dirty and !render_in_flight) {
            layout = render(
                &glyph_arena,
                sink,
                ids,
                &font,
                window_size,
                font_size,
                opt.font_file,
            ) catch |err| switch (err) {
                error.WriteFailed => return error.WriteFailed,
            };
            present_serial +%= 1;
            try x11.present.presentPixmap(sink, present_ext.opcode_base, ids.window(), ids.pixmap(), present_serial, 0, 0, 0);
            render_in_flight = true;
            dirty = false;
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
    try font.change(sink, .{ .size = new_font_size });
    font_size.* = new_font_size;
    return true;
}

const font_min: f32 = 1.0;
const font_max: f32 = 200.0;

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
    font: *Font,
    window_size: XY(u16),
    font_size: f32,
    font_file: ?[]const u8,
) error{WriteFailed}!Layout {
    const gc = ids.gc();
    const drawable = ids.pixmap().drawable();

    try sink.ChangeGc(gc, .{ .foreground = 0 });
    try sink.PolyFillRectangle(drawable, gc, .initAssume(&.{.{
        .x = 0,
        .y = 0,
        .width = window_size.x,
        .height = window_size.y,
    }}));
    try sink.ChangeGc(gc, .{ .foreground = 0xffffff });

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
    renderText(&writer, margin, font_size, font_file) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        else => |e| std.debug.panic("render text error: {s}", .{@errorName(e)}),
    };

    return layout;
}

fn renderText(
    writer: *Font.TextWriter,
    margin: i16,
    font_size: f32,
    font_file: ?[]const u8,
) (error{WriteFailed} || Font.Error)!void {
    try writer.newline();
    try writer.interface.print("size: {d}", .{font_size});
    try underline(writer, margin);
    try writer.newline();
    if (font_file) |f| {
        try writer.interface.print("{s}", .{f});
    } else {
        try writer.interface.writeAll("builtin font InterVariable.ttf");
    }
    try underline(writer, margin);
    try writer.newline();
    try writer.interface.print("Hello, {s}! These glyphs are missing: こんにちは", .{"World"});
    try underline(writer, margin);
    try writer.newline();
    try writer.newline();
    try writer.interface.writeAll("0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    try underline(writer, margin);
    try writer.newline();
    try writer.interface.writeAll("abcdefghijklmnopqrstuvwxyz");
    try underline(writer, margin);
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

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");
const x11 = @import("x11");
const XY = x11.XY;
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;
const Font = @import("Font");
const TrueType = Font.TrueType;
const Cmdline = @import("Cmdline.zig");
