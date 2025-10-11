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

    const font_id = fixed.resource_id_base.add(0).font();

    var sink: x11.RequestSink = .{ .writer = writer };

    try sink.OpenFont(font_id, .initAssume(font_name));
    try sink.QueryFont(font_id.fontable());
    const query_font_sequence = sink.sequence;

    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer = if (zig_atleast_15) std.fs.File.stdout().writer(&stdout_buffer) else std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout = if (zig_atleast_15) &stdout_writer.interface else stdout_writer.writer();

    try sink.writer.flush();

    {
        const msg1 = try x11.read1(reader);
        if (msg1.kind != .Reply) std.debug.panic(
            "expected Reply but got {f}",
            .{msg1.readFmt(reader)},
        );
        const reply = try msg1.read2(.Reply, reader);
        if (reply.sequence != query_font_sequence) std.debug.panic(
            "expected sequence {} but got {f}",
            .{ query_font_sequence, reply.readFmt(reader) },
        );
        const result = try x11.read3(.QueryFont, reader);
        std.log.info("{}", .{result});

        const msg_remaining_size: u35 = reply.remainingSize();
        const fields_remaining_size: u35 =
            @as(u35, @sizeOf(x11.stage3.QueryFont)) +
            (@as(u35, result.property_count) * @sizeOf(x11.FontProp)) +
            (@as(u35, result.info_count) * @sizeOf(x11.CharInfo));
        if (msg_remaining_size != fields_remaining_size) std.debug.panic(
            "msg size is {} but fields indicate {}",
            .{ msg_remaining_size, fields_remaining_size },
        );
        for (0..result.property_count) |index| {
            var prop: x11.FontProp = undefined;
            try reader.readSliceAll(std.mem.asBytes(&prop));
            try stdout.print("Property {}: {}\n", .{ index, prop });
        }
        for (0..result.info_count) |index| {
            var info: x11.CharInfo = undefined;
            try reader.readSliceAll(std.mem.asBytes(&info));
            try stdout.print("Info {}: {}\n", .{ index, info });
        }
    }

    try stdout.flush();
}
