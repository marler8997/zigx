const std = @import("std");
const x11 = @import("x11");

const zig_atleast_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;
const std16 = if (zig_atleast_16) std else @import("std16");

pub const log_level = std.log.Level.info;

const arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const ArgsIterator = if (zig_atleast_16) std.process.Args.Iterator else std.process.ArgIterator;

pub const main = if (zig_atleast_16) mainAtleast16 else mainBefore16;
fn mainAtleast16(init: std.process.Init) !void {
    var args_it = try init.minimal.args.iterateAllocator(init.arena.allocator());
    try mainCompat(&args_it, init.minimal.environ, init.io);
}
fn mainBefore16() !void {
    var arena = arena_instance;
    var args_it: std.process.ArgIterator = try .initWithAllocator(arena.allocator());
    try mainCompat(&args_it, .{}, .legacy);
}
fn mainCompat(args_it: *ArgsIterator, environ: std16.process.Environ, io: std16.Io) !void {
    _ = args_it.next(); // skip program name
    const font_name = args_it.next() orelse {
        std.debug.print("Usage: queryfont FONTNAME\n", .{});
        std.process.exit(0);
    };
    if (args_it.next() != null) {
        std.log.err("expected 1 cmd arg (FONTNAME) but got more", .{});
        std.process.exit(1);
    }

    try x11.wsaStartup();

    const socket, const setup = blk: {
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
        _ = screen;
        break :blk .{ socket_reader.socket, setup };
    };
    defer x11.disconnect(io, socket);

    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = x11.socketWriter(io, socket, &write_buffer);
    var socket_reader = x11.socketReader(io, socket, &read_buffer);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .initAfterSetup(&socket_reader.interface);

    const id_range = try x11.IdRange.init(setup.resource_id_base, setup.resource_id_mask);
    const font_id = id_range.addAssumeCapacity(0).font();

    if (@as(?error{WriteFailed}, blk: {
        sink.OpenFont(font_id, .initAssume(font_name)) catch |e| break :blk e;
        sink.QueryFont(font_id.fontable()) catch |e| break :blk e;
        sink.writer.flush() catch |e| break :blk e;
        break :blk null;
    })) |e| return x11.onWriteError(e, socket_writer.err.?);

    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer = std16.Io.File.stdout().writer(io, &stdout_buffer);
    streamFont(&source, sink.sequence, &stdout_writer.interface) catch |err| switch (err) {
        error.WriteFailed => return stdout_writer.err.?,
        error.ReadFailed => return socket_reader.err.?,
        error.EndOfStream, error.Protocol, error.UnexpectedMessage => |e| return e,
    };
}

fn streamFont(source: *x11.Source, sequence: u16, stdout: *std.Io.Writer) error{ WriteFailed, ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!void {
    const font, _ = try source.readSynchronousReplyHeader(sequence, .QueryFont);
    std.log.info("{}", .{font});

    const msg_remaining_size: u35 = source.replyRemainingSize();
    const fields_remaining_size: u35 =
        (@as(u35, font.property_count) * @sizeOf(x11.FontProp)) +
        (@as(u35, font.info_count) * @sizeOf(x11.CharInfo));
    if (msg_remaining_size != fields_remaining_size) std.debug.panic(
        "msg size is {} but fields indicate {}",
        .{ msg_remaining_size, fields_remaining_size },
    );
    for (0..font.property_count) |index| {
        var prop: x11.FontProp = undefined;
        try source.readReply(std.mem.asBytes(&prop));
        try stdout.print("Property {}: {}\n", .{ index, prop });
    }
    for (0..font.info_count) |index| {
        var info: x11.CharInfo = undefined;
        try source.readReply(std.mem.asBytes(&info));
        try stdout.print("Info {}: {}\n", .{ index, info });
    }
    std.debug.assert(source.replyRemainingSize() == 0);
    try stdout.flush();
}
