const std = @import("std");
const x11 = @import("x11");

pub const log_level = std.log.Level.info;

const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn main() !void {
    const all_args = try std.process.argsAlloc(allocator);
    if (all_args.len <= 1) {
        std.debug.print("Usage: queryfont FONTNAME\n", .{});
        std.process.exit(0);
    }
    const cmd_args = all_args[1..];
    if (cmd_args.len != 1) {
        std.log.err("expected 1 cmd arg (FONTNAME) but got {}", .{cmd_args.len});
        std.process.exit(1);
    }
    const font_name = cmd_args[0];

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
    var read_buf: [32]u8 = undefined;
    var socket_writer = x11.socketWriter(stream, &write_buf);
    var socket_reader = x11.socketReader(stream, &read_buf);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .{ .reader = socket_reader.interface() };

    const setup = switch (try x11.ext.authenticate(sink.writer, &source, .{
        .display_num = parsed_display.display_num,
        .socket = stream.handle,
    })) {
        .failed => |reason| {
            x11.log.err("auth failed: {f}", .{reason});
            std.process.exit(0xff);
        },
        .success => |reply_len| reply_len,
    };
    std.log.info("setup reply {}", .{setup});
    const screen = try x11.ext.readSetupDynamic(&source, &setup, .{}) orelse {
        std.log.err("no screen?", .{});
        std.process.exit(0xff);
    };
    _ = screen;

    const font_id = setup.resource_id_base.add(0).font();

    try sink.OpenFont(font_id, .initAssume(font_name));
    try sink.QueryFont(font_id.fontable());

    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer: x11.FileWriter = .init(x11.stdout(), &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try sink.writer.flush();
    const font, _ = try source.readSynchronousReplyHeader(sink.sequence, .QueryFont);
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
