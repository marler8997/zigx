const Ids = struct {
    range: x11.IdRange,

    pub fn window(self: Ids) x11.Window {
        return self.range.addAssumeCapacity(0).window();
    }
    pub fn gc(self: Ids) x11.GraphicsContext {
        return self.range.addAssumeCapacity(1).graphicsContext();
    }
    pub fn presentPixmaps(self: Ids) [2]x11.Pixmap {
        return .{
            self.range.addAssumeCapacity(2).pixmap(),
            self.range.addAssumeCapacity(3).pixmap(),
        };
    }
    pub fn presentEventId(self: Ids) u32 {
        return @intFromEnum(self.range.addAssumeCapacity(4));
    }
    pub fn glyphset(self: Ids) x11.render.GlyphSet {
        return self.range.addAssumeCapacity(5).glyphSet();
    }
    pub fn dstPictures(self: Ids) [2]x11.render.Picture {
        return .{
            self.range.addAssumeCapacity(6).picture(),
            self.range.addAssumeCapacity(7).picture(),
        };
    }
    pub fn srcPicture(self: Ids) x11.render.Picture {
        return self.range.addAssumeCapacity(8).picture();
    }
    const needed_capacity = 9;
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

const ArgsIterator = if (zig_atleast_16) std.process.Args.Iterator else std.process.ArgIterator;

pub const main = if (zig_atleast_16) mainAtleast16 else mainBefore16;
fn mainAtleast16(init: std.process.Init) !void {
    var args_it = init.minimal.args.iterate();
    try mainCompat(&args_it, init.minimal.environ, init.io);
}
fn mainBefore16() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var args_it: std.process.ArgIterator = try .initWithAllocator(arena.allocator());
    try mainCompat(&args_it, .{}, .legacy);
}
fn mainCompat(args_it: *ArgsIterator, environ: std16.process.Environ, io: std16.Io) !void {
    _ = args_it.next(); // skip program name

    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

    var opt: Options = .{};

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--font")) {
            opt.font_file = args_it.next() orelse errExit("--font missing arg", .{});
        } else if (std.mem.eql(u8, arg, "--size")) {
            const size_str = args_it.next() orelse errExit("--size missing arg", .{});
            opt.size = std.fmt.parseFloat(f32, size_str) catch errExit("invalid --size '{s}'", .{size_str});
        } else errExit("unknown cmdline option '{s}'", .{arg});
    }

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
            x11.log.err("no screen?", .{});
            std.process.exit(0xff);
        };
        const id_range = try x11.IdRange.init(setup.resource_id_base, setup.resource_id_mask);
        if (id_range.capacity() < Ids.needed_capacity) {
            x11.log.err("X server id range capacity {} is less than needed {}", .{ id_range.capacity(), Ids.needed_capacity });
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
    run(io, ids, &root, &sink, &source, &arena_instance, opt) catch |err| switch (err) {
        error.WriteFailed => |e| return x11.onWriteError(e, socket_writer.err.?),
        error.ReadFailed, error.EndOfStream, error.Protocol => |e| return source.onReadError(e, socket_reader.err),
        error.UnexpectedMessage => |e| return e,
    };
}

fn run(
    io: std16.Io,
    ids: Ids,
    root: *const Root,
    sink: *x11.RequestSink,
    source: *x11.Source,
    arena_instance: *std.heap.ArenaAllocator,
    opt: Options,
) error{ WriteFailed, ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!void {
    const present_ext = try x11.draft.synchronousQueryExtension(source, sink, x11.present.name) orelse {
        x11.log.err("Present extension not available", .{});
        std.process.exit(0xff);
    };

    const render_ext = try x11.draft.synchronousQueryExtension(source, sink, x11.render.name) orelse {
        x11.log.err("RENDER extension not available", .{});
        std.process.exit(0xff);
    };

    // Query PictFormats to find the PictureFormat for our root visual and an A8 (alpha) format
    try x11.render.QueryPictFormats(sink, render_ext.opcode_base);
    try sink.writer.flush();
    const visual_format: x11.render.PictureFormat, const a8_format: x11.render.PictureFormat = blk: {
        const pict_result, _ = try source.readSynchronousReplyHeader(sink.sequence, .render_QueryPictFormats);
        var pict_reader: x11.render.PictFormatsReader = .init(pict_result);

        var maybe_a8_format: ?x11.render.PictureFormat = null;
        {
            var format_rd = pict_reader.formatReader();
            while (try format_rd.next(source)) |format| {
                const log_formats = false;
                if (log_formats) std.log.info("PictFormat {f}", .{format});
                if (format.depth == 8 and format.type == .direct and format.direct.alpha_mask == 0xff) {
                    maybe_a8_format = format.id;
                    if (!log_formats) break;
                }
            }
            try format_rd.discardRemaining(source);
        }

        var maybe_visual_format: ?x11.render.PictureFormat = null;
        {
            var visual_rd = pict_reader.visualReader();
            while (try visual_rd.next(source)) |visual| {
                const log_visuals = false;
                if (log_visuals) std.log.info("Visual {}", .{visual});
                if (visual.visual == root.visual) {
                    maybe_visual_format = visual.format;
                    if (!log_visuals) break;
                }
            }
            try visual_rd.discardRemaining(source);
        }

        try pict_reader.discardRemaining(source);
        break :blk .{
            maybe_visual_format orelse {
                x11.log.err("no PictFormat for root visual {f}", .{root.visual});
                std.process.exit(0xff);
            },
            maybe_a8_format orelse {
                x11.log.err("no A8 PictFormat found", .{});
                std.process.exit(0xff);
            },
        };
    };

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
        },
    );

    var presenter: x11.Presenter = .{
        .opcode_base = present_ext.opcode_base,
        .depth = root.depth,
        .window_id = ids.window(),
        .event_id = ids.presentEventId(),
        .pixmaps = ids.presentPixmaps(),
    };
    try presenter.init(sink, window_size.x, window_size.y);

    const dst_pictures = ids.dstPictures();
    for (presenter.pixmaps, dst_pictures) |pixmap, picture| {
        try x11.render.CreatePicture(sink, render_ext.opcode_base, picture, pixmap.drawable(), visual_format, .{});
    }

    // Create a solid white Picture (source color for glyph compositing)
    try x11.render.CreateSolidFill(
        sink,
        render_ext.opcode_base,
        ids.srcPicture(),
        x11.render.Color.fromRgb24(0xffffff),
    );

    try sink.MapWindow(ids.window());

    const ttf_content = blk: {
        if (opt.font_file) |font_file| {
            break :blk std16.Io.Dir.cwd().readFileAlloc(
                io,
                font_file,
                arena_instance.allocator(),
                .unlimited,
            ) catch |e| errExit(
                "read '{s}' failed with {s}",
                .{ font_file, @errorName(e) },
            );
        }
        break :blk @embedFile("InterVariable.ttf");
    };
    const ttf: xtt.TrueType = xtt.TrueType.load(ttf_content) catch |e| @panic(@errorName(e));
    xtt.check(&ttf) catch |e| @panic(@errorName(e));
    var font_size: f32 = opt.size;
    var uploaded_glyphs: xtt.GlyphIndexSet = undefined;
    var glyphs: xtt.GlyphSet = try .init(
        &ttf,
        render_ext.opcode_base,
        ids.glyphset(),
        a8_format,
        ttf.scaleForPixelHeight(font_size),
        &uploaded_glyphs,
        sink,
    );
    defer glyphs.deinit(sink) catch {};
    var glyph_arena: ArenaAllocator = .init(std.heap.page_allocator);

    var sliding: bool = false;
    var layout: Layout = .{
        .slider = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
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
                        if (try updateFontSize(sink, &font_size, &glyphs, layout.slider, pt.x))
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
                    if (try updateFontSize(sink, &font_size, &glyphs, layout.slider, pt.x))
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
                    try presenter.resize(sink, window_size.x, window_size.y);
                    for (presenter.pixmaps, dst_pictures) |pixmap, picture| {
                        try x11.render.FreePicture(sink, render_ext.opcode_base, picture);
                        try x11.render.CreatePicture(sink, render_ext.opcode_base, picture, pixmap.drawable(), visual_format, .{});
                    }
                    dirty = true;
                }
            },
            .GenericEvent => {
                const event = try source.read2(.GenericEvent);
                if (event.isPresentCompleteNotify(presenter.opcode_base)) {
                    const complete = try source.read3Full(.present_CompleteNotify);
                    if (!try presenter.handleCompleteNotify(
                        complete,
                    )) std.debug.panic("unexpected {}", .{complete});
                } else if (event.isPresentIdleNotify(presenter.opcode_base)) {
                    const idle = try source.read3Full(.present_IdleNotify);
                    if (!try presenter.handleIdleNotify(
                        idle,
                    )) std.debug.panic("unexpected {}", .{idle});
                } else std.debug.panic("unexpected {}", .{event});
            },
            .MapNotify,
            .ReparentNotify,
            .MappingNotify,
            => try source.discardRemaining(),
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmtDropError()}),
        }
        if (dirty) if (presenter.beginFrame()) |pixmap| {
            const dst_picture = dst_pictures[presenter.back_buf];
            layout = render(
                &glyph_arena,
                sink,
                ids.gc(),
                pixmap,
                dst_picture,
                ids.srcPicture(),
                &glyphs,
                window_size,
                font_size,
                opt.font_file,
            ) catch |err| switch (err) {
                error.WriteFailed => return error.WriteFailed,
            };
            try presenter.endFrame(sink);
            dirty = false;
        };
    }
}

fn updateFontSize(
    sink: *x11.RequestSink,
    font_size: *f32,
    glyphs: *xtt.GlyphSet,
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
    try glyphs.change(sink, .{ .size = new_font_size });
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
    gc: x11.GraphicsContext,
    pixmap: x11.Pixmap,
    dst_picture: x11.render.Picture,
    src_picture: x11.render.Picture,
    glyphs: *xtt.GlyphSet,
    window_size: XY(u16),
    font_size: f32,
    font_file: ?[]const u8,
) error{WriteFailed}!Layout {
    const drawable = pixmap.drawable();

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
    var writer: xtt.Writer = .init(.{
        .glyph_set = glyphs,
        .src_picture = src_picture,
        .gpa = glyph_arena.allocator(),
        .sink = sink,
        .dst_picture = dst_picture,
        .cursor = .{
            .x = margin,
            .y = 30,
        },
        .left_margin = margin,
        .buffer = &writer_buf,
    });
    renderText(&writer, drawable, gc, margin, font_size, font_file) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        else => |e| std.debug.panic("render text error: {s}", .{@errorName(e)}),
    };

    return layout;
}

fn renderText(
    writer: *xtt.Writer,
    drawable: x11.Drawable,
    gc: x11.GraphicsContext,
    margin: i16,
    font_size: f32,
    font_file: ?[]const u8,
) xtt.Writer.Error!void {
    try writer.newline();
    try writer.interface.print("size: {d}", .{font_size});
    try underline(drawable, gc, writer, margin);
    try writer.newline();
    if (font_file) |f| {
        try writer.interface.print("{s}", .{f});
    } else {
        try writer.interface.writeAll("builtin font InterVariable.ttf");
    }
    try underline(drawable, gc, writer, margin);
    try writer.newline();
    try writer.interface.print("Hello, {s}! These glyphs are missing: こんにちは", .{"World"});
    try underline(drawable, gc, writer, margin);
    try writer.newline();
    try writer.newline();
    try writer.interface.writeAll("0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ");
    try underline(drawable, gc, writer, margin);
    try writer.newline();
    try writer.interface.writeAll("abcdefghijklmnopqrstuvwxyz");
    try underline(drawable, gc, writer, margin);
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
    drawable: x11.Drawable,
    gc: x11.GraphicsContext,
    text_writer: *xtt.Writer,
    left: i16,
) !void {
    try text_writer.interface.flush(); // flush to resolve the final cursor position
    try text_writer.sink.PolyFillRectangle(drawable, gc, .initAssume(&[_]x11.Rectangle{.{
        .x = left,
        .y = @intFromFloat(@round(text_writer.cursor.y)),
        .width = @intFromFloat(@round(text_writer.cursor.x - @as(f32, @floatFromInt(left)))),
        .height = 1,
    }}));
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    x11.log.err(fmt, args);
    std.process.exit(0xff);
}

const zig_atleast_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

const std = @import("std");
const std16 = if (zig_atleast_16) std else @import("std16");
const x11 = @import("x11");

const xtt = @import("xtt");
const XY = x11.XY;
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;
const Cmdline = @import("Cmdline.zig");
