const std = @import("std");
const x11 = @import("x11");

pub const log_level = std.log.Level.info;

pub fn main() !void {
    try x11.wsaStartup();

    const stream = blk: {
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
        _ = screen;
        break :blk socket_reader.getStream();
    };
    defer x11.disconnect(stream);

    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    var socket_writer = x11.socketWriter(stream, &write_buffer);
    var socket_reader = x11.socketReader(stream, &read_buffer);
    var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    var source: x11.Source = .initAfterSetup(socket_reader.interface());

    if (@as(?error{WriteFailed}, blk: {
        sink.ListFonts(0xffff, .initComptime("*")) catch |e| break :blk e;
        sink.writer.flush() catch |e| break :blk e;
        break :blk null;
    })) |e| return x11.onWriteError(e, socket_writer.err.?);

    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    streamFonts(&source, sink.sequence, &stdout_writer.interface) catch |err| switch (err) {
        error.WriteFailed => return stdout_writer.err.?,
        error.ReadFailed => return socket_reader.getError().?,
        error.EndOfStream, error.Protocol, error.UnexpectedMessage => |e| return e,
    };
}
fn streamFonts(source: *x11.Source, sequence: u16, writer: *std.Io.Writer) error{ WriteFailed, ReadFailed, EndOfStream, Protocol, UnexpectedMessage }!void {
    const fonts, _ = try source.readSynchronousReplyHeader(sequence, .ListFonts);
    std.log.info("font count {}", .{fonts.count});
    for (0..fonts.count) |_| {
        const len = try source.takeReplyInt(u8);
        try source.streamReply(writer, len);
        try writer.writeByte('\n');
    }
    const remaining = source.replyRemainingSize();
    std.log.info("discarding remaining {} bytes...", .{remaining});
    try source.replyDiscard(remaining);
    try writer.flush();
}
