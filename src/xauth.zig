const std = @import("std");
const std16 = if (zig_atleast_16) std else @import("std16");
const x11 = @import("x11");

const zig_atleast_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

const global = struct {
    pub var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    pub const arena = arena_instance.allocator();
};

const Opt = struct {
    auth_filename: ?[]const u8 = null,
};

fn usage() void {
    std.debug.print(
        \\usage: xauth [-options ...] [command arg ...]
        \\
        \\OPTIONS:
        \\  -f  authfilename    Authorization file to use. Optional, defaults to $XAUTHORITY or $HOME/.Xauthority
        \\
        \\COMMANDS:
        \\  help                Print help
        \\  list                List authorization entries
        \\
    , .{});
}

const ArgsIterator = if (zig_atleast_16) std.process.Args.Iterator else std.process.ArgIterator;

pub const main = if (zig_atleast_16) mainAtleast16 else mainBefore16;
fn mainAtleast16(init: std.process.Init) !void {
    var args_it = try init.minimal.args.iterateAllocator(init.arena.allocator());
    try mainCompat(&args_it, init.minimal.environ, init.io);
}
fn mainBefore16() !void {
    var args_it: std.process.ArgIterator = try .initWithAllocator(global.arena);
    // no need to free
    try mainCompat(&args_it, .{}, .legacy);
}
fn mainCompat(args_it: *ArgsIterator, environ: std16.process.Environ, io: std16.Io) !void {
    _ = args_it.next();

    var opt = Opt{};
    const cmd: []const u8 = blk: {
        var maybe_cmd: ?[]const u8 = null;
        while (args_it.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                if (maybe_cmd != null) {
                    std.log.err("too many cmdline args", .{});
                    std.process.exit(1);
                }
                maybe_cmd = arg;
            } else if (std.mem.eql(u8, arg, "-f")) {
                opt.auth_filename = args_it.next() orelse {
                    std.log.err("missing authfilename after option -f", .{});
                    std.process.exit(1);
                };
            } else {
                std.log.err("invalid option \"{s}\"", .{arg});
                std.process.exit(1);
            }
        }
        break :blk maybe_cmd orelse return usage();
    };
    if (std.mem.eql(u8, cmd, "help")) {
        usage();
    } else if (std.mem.eql(u8, cmd, "list")) {
        try list(environ, io, opt);
    } else {
        std.log.err("invalid command \"{s}\"", .{cmd});
        std.process.exit(1);
    }
}

fn list(environ: std16.process.Environ, io: std16.Io, opt: Opt) !void {
    if (opt.auth_filename) |filename| {
        const file = std16.Io.Dir.cwd().openFile(io, filename, .{}) catch |err| {
            std.log.err("open '{s}' failed with {s}", .{ filename, @errorName(err) });
            std.process.exit(1);
        };
        defer file.close(io);
        try list2(io, file);
    } else {
        var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (std.enums.valuesFromFields(
            x11.AuthFileKind,
            @typeInfo(x11.AuthFileKind).@"enum".fields,
        )) |kind| {
            if (x11.getAuthFilename(environ, kind, &filename_buf) catch |err| {
                std.log.err("get auth filename ({s}) failed with {s}", .{ kind.context(), @errorName(err) });
                continue;
            }) |filename| {
                if (std16.Io.Dir.cwd().openFile(io, filename, .{})) |file| {
                    defer file.close(io);
                    try list2(io, file);
                } else |err| {
                    std.log.info("open '{s}' failed with {s}", .{ filename, @errorName(err) });
                }
            }
        }
    }
}

fn list2(io: std16.Io, file: std16.Io.File) !void {
    var file_read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_read_buf);
    var reader: x11.AuthReader = .{ .reader = &file_reader.interface };
    list3(io, &reader) catch |err| return switch (err) {
        error.ReadFailed => file_reader.err orelse error.ReadFailed,
        else => |e| e,
    };
}

fn list3(io: std16.Io, reader: *x11.AuthReader) !void {
    var stdout_buffer: [1000]u8 = undefined;
    var stdout_writer = std16.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var entry_index: u32 = 0;
    while (true) : (entry_index += 1) {
        const family = (try reader.takeFamily()) orelse break;
        try stdout.print("AddressFamily={f} ", .{x11.fmtEnum(family)});
        const addr_len = try reader.takeDynamicLen(.addr);
        switch (family) {
            .inet => if (addr_len == 4) {
                const a = try reader.takeDynamic(4);
                try stdout.print("{}.{}.{}.{} ", .{ a[0], a[1], a[2], a[3] });
            },
            .inet6 => {},
            .unix => {
                try stdout.writeAll("UnixAddress='");
                try reader.streamDynamic(stdout, addr_len);
                try stdout.writeAll("' ");
            },
            .wild => {},
            _ => {},
        }
        if (reader.state == .dynamic_data) {
            try stdout.print("Address({} bytes)=", .{addr_len});
            try streamHex(reader, stdout, addr_len);
            try stdout.writeAll(" ");
        }

        const display_num_len = try reader.takeDynamicLen(.display_num);
        try stdout.writeAll("DisplayNum='");
        try reader.streamDynamic(stdout, display_num_len);
        try stdout.writeAll("'");

        const name_len = try reader.takeDynamicLen(.name);
        try stdout.writeAll(" AuthName='");
        try reader.streamDynamic(stdout, name_len);
        const data_len = try reader.takeDynamicLen(.data);
        try stdout.print("' Data({} bytes)=", .{data_len});
        try streamHex(reader, stdout, data_len);
        try stdout.writeByte('\n');
    }
    try stdout.flush();
}

fn streamHex(reader: *x11.AuthReader, stdout: *std.Io.Writer, n: usize) !void {
    var remaining = n;
    while (remaining > 0) {
        const take_len = @min(remaining, reader.reader.buffer.len);
        const data = try reader.takeDynamic(take_len);
        try stdout.print("{x}", .{data});
        remaining -= take_len;
    }
    reader.finishDynamic();
}
