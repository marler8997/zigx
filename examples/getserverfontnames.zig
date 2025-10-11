const std = @import("std");
const x11 = @import("x11");

pub const log_level = std.log.Level.info;

const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn main() !void {
    try x11.wsaStartup();

    const display = x11.getDisplay();
    std.log.info("DISPLAY '{s}'", .{display});
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

    try sink.ListFonts(0xffff, .initComptime("*"));
    try sink.writer.flush();

    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer: x11.FileWriter = .init(x11.stdout(), &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const fonts, _ = try source.readSynchronousReplyHeader(sink.sequence, .ListFonts);
    std.log.info("font count {}", .{fonts.count});
    for (0..fonts.count) |_| {
        const len = try source.takeReplyInt(u8);
        try source.streamReply(stdout, len);
        try stdout.writeByte('\n');
    }
    const remaining = source.replyRemainingSize();
    std.log.info("discarding remaining {} bytes...", .{remaining});
    try source.replyDiscard(remaining);

    try stdout.flush();
}
