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

    const display = try x11.getDisplay();
    std.log.info("DISPLAY {f}", .{display});
    const parsed_display = x11.parseDisplay(display) catch |err| {
        std.log.err("invalid DISPLAY {f}: {s}", .{ display, @errorName(err) });
        std.process.exit(0xff);
    };
    const address = try x11.getAddress(display, &parsed_display);
    std.log.info("Address {f}", .{address});
    var write_buffer: [1000]u8 = undefined;
    var read_buffer: [1000]u8 = undefined;
    // const conn = try x11.connect(
    //     .{ .display = display, .parsed_display = parsed_display, .address = address },
    //     .{ .write = &write_buf, .read = &read_buf },
    // );
    // _ = conn;
    const conn = blk: {
        var filename_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var connector: x11.Connector = .{
            .input = .{
                .display = display,
                .parsed_display = parsed_display,
                .address = address,
                .write_buffer = &write_buffer,
                .read_buffer = &read_buffer,
            },
            .filename_buffer = &filename_buffer,
        };
        defer connector.deinit();
        while (true) switch (connector.next()) {
            .connected => |conn| break :blk conn,
            .get_auth_filename_error => |e| {
                std.log.err("get auth filename ({s}) failed with {s}", .{ e.kind.context(), @errorName(e.err) });
            },
            .open_auth_file_error => |e| {
                std.log.err("open auth file '{s}' ({s}) failed with {s}", .{ e.filename, e.kind.context(), @errorName(e.err) });
            },
        };
        // while (connector.next()) |event| {
        //     std.debug.panic("todo: handle event {}", .{event});
        // }
    };
    _ = conn;

    // var auth_filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    // const auth_filename = try x11.getAuthFilename2(&auth_filename_buf);
    // std.log.info("AuthFilename {f}", .{x11.fmtMaybeString(auth_filename)});
    // var auth_it: x11.AuthIterator = .{
    //     .display = display,
    //     .parsed_display = parsed_display,
    //     .address = address,
    //     .filename = auth_filename,
    // };
    // while (auth_it.next()) |auth| switch (auth) {
    //     .open_file_error => |err| {
    //         std.log.err("open xauth file '{?s}' failed with {s}", .{ auth_filename, @errorName(err) });
    //     },
    //     .read_file_error => |err| {
    //         std.log.err("read xauth file '{?s}' failed with {s}", .{ auth_filename, @errorName(err) });
    //     },
    //     .auth_file_truncated => {
    //         std.log.err("xauth file '{?s}' is truncated", .{auth_filename});
    //     },
    // };
    // while (true) {}
    // _ = parsed_display;
    if (true) @panic("todo");

    _ = font_name;
    // const addr, const stream = x11.connect(display, parsed_display) catch |err| {
    //     std.log.err("connect to DISPLAY {f} failed with {s}", .{ display, @errorName(err) });
    //     std.process.exit(0xff);
    // };
    // defer std.posix.shutdown(stream.handle, .both) catch {};
    // std.log.info("connected to {f}", .{addr});

    // var socket_writer = x11.socketWriter(stream, &write_buf);
    // var socket_reader = x11.socketReader(stream, &read_buf);
    // var sink: x11.RequestSink = .{ .writer = &socket_writer.interface };
    // var source: x11.Source = .{ .reader = socket_reader.interface() };

    // const setup = switch (try x11.authenticate(sink.writer, &source, .{
    //     .display = display,
    //     .parsed = parsed_display,
    //     .addr = addr,
    // })) {
    //     .failed => |reason| {
    //         std.log.err("auth failed: {f}", .{reason});
    //         std.process.exit(0xff);
    //     },
    //     .success => |setup| setup,
    // };
    // std.log.info("setup reply {}", .{setup});
    // const screen = try x11.ext.readSetupDynamic(&source, &setup, .{}) orelse {
    //     std.log.err("no screen?", .{});
    //     std.process.exit(0xff);
    // };
    // _ = screen;

    // const font_id = setup.resource_id_base.add(0).font();

    // try sink.OpenFont(font_id, .initAssume(font_name));
    // try sink.QueryFont(font_id.fontable());

    // var stdout_buffer: [1000]u8 = undefined;
    // var stdout_writer: x11.FileWriter = .init(x11.stdout(), &stdout_buffer);
    // const stdout = &stdout_writer.interface;

    // try sink.writer.flush();
    // const font, _ = try source.readSynchronousReplyHeader(sink.sequence, .QueryFont);
    // std.log.info("{}", .{font});

    // const msg_remaining_size: u35 = source.replyRemainingSize();
    // const fields_remaining_size: u35 =
    //     (@as(u35, font.property_count) * @sizeOf(x11.FontProp)) +
    //     (@as(u35, font.info_count) * @sizeOf(x11.CharInfo));
    // if (msg_remaining_size != fields_remaining_size) std.debug.panic(
    //     "msg size is {} but fields indicate {}",
    //     .{ msg_remaining_size, fields_remaining_size },
    // );
    // for (0..font.property_count) |index| {
    //     var prop: x11.FontProp = undefined;
    //     try source.readReply(std.mem.asBytes(&prop));
    //     try stdout.print("Property {}: {}\n", .{ index, prop });
    // }
    // for (0..font.info_count) |index| {
    //     var info: x11.CharInfo = undefined;
    //     try source.readReply(std.mem.asBytes(&info));
    //     try stdout.print("Info {}: {}\n", .{ index, info });
    // }
    // std.debug.assert(source.replyRemainingSize() == 0);

    // try stdout.flush();
}
