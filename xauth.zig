const std = @import("std");
const x = @import("x.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var auth_filename: ?[]const u8 = null;
    defer if (auth_filename) |auth| allocator.free(auth);

    var args_it = try std.process.argsWithAllocator(allocator);
    if (!args_it.skip()) {
        usage();
    }

    while (args_it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-f")) {
                if (auth_filename) |_| {
                    std.debug.print("error: -f provided multiple times\n", .{});
                    usage();
                }

                const auth_filename_arg = args_it.next() orelse {
                    std.debug.print("error: missing authfilename after option -f\n", .{});
                    usage();
                };

                auth_filename = try allocator.dupe(u8, auth_filename_arg);
            } else {
                std.debug.print("error: invalid option \"{s}\"\n", .{arg});
                usage();
            }
        } else {
            if (std.mem.eql(u8, arg, "help")) {
                usage();
            } else if (std.mem.eql(u8, arg, "list")) {
                if (auth_filename == null) {
                    var system_auth_filename_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                    const system_auth_filename = try x.getAuthorityFilePath(&system_auth_filename_buf);
                    auth_filename = try allocator.dupe(u8, system_auth_filename);
                }

                try listAuthorizationEntries(auth_filename.?);
                return;
            } else {
                std.debug.print("error: invalid command \"{s}\"\n", .{arg});
                usage();
            }
        }
    }

    std.debug.print("error: missing command\n", .{});
    usage();
}

fn listAuthorizationEntries(auth_filename: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    var stdout_buffer = std.io.bufferedWriter(stdout);
    const stdout_writer = stdout_buffer.writer();

    var auth_file = try x.AuthorizationFile.init(auth_filename);
    defer auth_file.deinit();
    var auth_it = auth_file.iterator();

    while (try auth_it.next()) |*auth| {
        try stdout_writer.print("{s}/{s}:{s}  {s}  {s}\n", .{ auth.address, authFamilyGetName(auth.family), auth.num, auth.name, std.fmt.fmtSliceHexLower(auth.data) });
        try stdout_buffer.flush();
    }
}

fn authFamilyGetName(family: i16) []const u8 {
    switch (family) {
        @intFromEnum(x.AuthorizationFamily.local)    => return "unix",
        @intFromEnum(x.AuthorizationFamily.internet) => return "inet",
        else                                         => return "unknown",
    }
}

fn usage() noreturn {
    std.debug.print(
        \\usage: xauth [-options ...] [command arg ...]
        \\
        \\OPTIONS:
        \\  -f  authfilename    Authorization file to use. Optional, defaults to $XAUTHORITY or $HOME/.Xauthority
        \\
        \\COMMANDS:
        \\  list                List authorization entries
        \\
    , .{});
    std.process.exit(1);
}
