const std = @import("std");
const x11 = @import("x11");

pub const log_level = std.log.Level.info;

const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
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

    const display = try x11.getDisplay();
    std.log.info("DISPLAY {f}", .{display});
    const parsed_display = x11.parseDisplay(display) catch |err| {
        std.log.err("invalid DISPLAY {f}: {s}", .{ display, @errorName(err) });
        std.process.exit(0xff);
    };
    const address = try x11.getAddress(display, &parsed_display);
    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var io = x11.connect(address, &write_buffer, &read_buffer) catch |err| {
        std.log.err("connect to {f} failed with {s}", .{ address, @errorName(err) });
        std.process.exit(0xff);
    };
    defer io.shutdown(); // no need to close as well
    std.log.info("connected to {f}", .{address});
    try x11.ext.authenticate(display, parsed_display, address, &io);
    var sink: x11.RequestSink = .{ .writer = &io.socket_writer.interface };
    var source: x11.Source = .{ .reader = io.socket_reader.interface() };
    const setup = try source.readSetup();
    std.log.info("setup reply {f}", .{setup});
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
