comptime {
    const zig_atleast_16 = @import("builtin").zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;
    if (zig_atleast_16) @compileError("this module should only be used on zig 0.15");
}

pub const Io = @import("Io.zig");

pub const debug = @import("std").debug;
pub const fs = @import("std").fs;
pub const math = @import("std").math;
pub const mem = @import("std").mem;
pub const os = @import("std").os;
pub const posix = @import("std").posix;
pub const process = @import("process.zig");
pub const testing = @import("std").testing;
pub const time = @import("std").time;

test {
    testing.refAllDecls(@This());
}
