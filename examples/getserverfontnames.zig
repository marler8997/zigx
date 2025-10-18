const std = @import("std");
const x11 = @import("x11");

pub const log_level = std.log.Level.info;

const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

pub fn main() !void {
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
    const writer = &socket_writer.interface;
    const reader = socket_reader.interface();

    const reply_len = switch (try x11.ext.authenticate(writer, reader, .{
        .display_num = parsed_display.display_num,
        .socket = stream.handle,
    })) {
        .failed => |reason| {
            x11.log.err("auth failed: {f}", .{reason});
            std.process.exit(0xff);
        },
        .success => |reply_len| reply_len,
    };

    const fixed = try x11.ext.readConnectSetupFixed(reader);
    std.log.info("fixed is {}", .{fixed});
    const screen = try x11.ext.readConnectSetupDynamic(reader, reply_len, &fixed) orelse {
        std.log.err("no screen?", .{});
        std.process.exit(0xff);
    };
    _ = screen;

    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    try sink.ListFonts(0xffff, .initComptime("*"));
    const list_fonts_sequence = sink.sequence;
    try sink.writer.flush();

    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer: x11.FileWriter = .init(x11.stdout(), &stdout_buffer);
    const stdout = &stdout_writer.interface;

    {
        const msg1 = try x11.read1(reader);
        if (msg1.kind != .Reply) std.debug.panic(
            "expected Reply but got {f}",
            .{msg1.readFmt(reader)},
        );
        const reply = try msg1.read2(.Reply, reader);
        if (reply.sequence != list_fonts_sequence) std.debug.panic(
            "expected sequence {} but got {f}",
            .{ list_fonts_sequence, reply.readFmt(reader) },
        );
        const fonts = try x11.read3(.ListFonts, reader);
        std.log.info("font count {}", .{fonts.count});
        var remaining = reply.bodySize();
        for (0..fonts.count) |_| {
            if (remaining == 0) @panic("fonts truncated");
            const len = try reader.takeByte();
            remaining -= 1;
            if (len > remaining) @panic("fonts truncated");
            try reader.streamExact(stdout, len);
            remaining -= len;
            try stdout.writeByte('\n');
        }
        std.log.info("discarding remaining {} bytes...", .{remaining});
        try reader.discardAll(remaining);
    }

    try stdout.flush();
}
