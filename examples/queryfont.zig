const std = @import("std");
const x11 = @import("x11");

pub const std_options: std.Options = .{ .io_vtable = .threaded };

pub const log_level = std.log.Level.info;

pub fn main(init: std.process.Init.Minimal) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    // only allocates on windows, no need to free
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var arg_it = try init.args.iterateAllocator(arena.allocator());
    _ = arg_it.skip();
    const font_name = arg_it.next() orelse {
        std.debug.print("Usage: queryfont FONTNAME\n", .{});
        std.process.exit(0);
    };
    if (arg_it.next()) |arg| {
        std.log.err("expected 1 cmd arg (FONTNAME) but got extra arg '{s}'", .{arg});
        std.process.exit(1);
    }

    const stream, const setup = blk: {
        var read_buffer: [1000]u8 = undefined;
        var socket_reader, const used_auth = try x11.draft.connect(io, init.environ, &read_buffer);
        errdefer x11.disconnect(io, socket_reader.stream);
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
        break :blk .{ socket_reader.stream, setup };
    };
    defer x11.disconnect(io, stream);

    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = stream.writer(io, &write_buffer);
    var socket_reader = stream.reader(io, &read_buffer);
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
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
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
