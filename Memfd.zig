const std = @import("std");
const Memfd = @This();

fd: std.os.fd_t,

pub fn init(name: [:0]const u8) !Memfd {
    return Memfd{ .fd = try std.os.memfd_createZ(name, 0) };
}

pub fn deinit(self: Memfd) void {
    std.os.close(self.fd);
}
