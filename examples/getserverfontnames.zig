const std = @import("std");
const x11 = @import("x11");

pub const log_level = std.log.Level.info;

const zig_atleast_15 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 15, .patch = 0 }) != .lt;

pub fn main() !void {
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
    var io = x11.connect(&address, &write_buffer, &read_buffer) catch |err| {
        std.log.err("connect to {f} failed with {s}", .{ address, @errorName(err) });
        std.process.exit(0xff);
    };
    defer io.shutdown(); // no need to close as well
    std.log.info("connected to {f}", .{address});
    try x11.draft.authenticate(display, &parsed_display, &address, &io);
    var sink: x11.RequestSink = .{ .writer = &io.socket_writer.interface };
    var source: x11.Source = .{ .reader = io.socket_reader.interface() };
    const setup = try source.readSetup();
    std.log.info("setup reply {f}", .{setup});
    const screen = try x11.draft.readSetupDynamic(&source, &setup, .{}) orelse {
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
