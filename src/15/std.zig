pub const Io = @import("Io.zig");
pub const builtin = @import("std").builtin;
pub const c = @import("std").c;
pub const debug = @import("std").debug;
pub const fmt = @import("std").fmt;
pub const fs = struct {
    pub const File15 = @import("fs/File15.zig");
};
pub const io = Io;
pub const math = @import("std").math;
pub const mem = @import("std").mem;
pub const net = @import("net.zig");
pub const os = struct {
    pub const windows = @import("std").os.windows;
    pub const linux = @import("os/linux.zig");
};
pub const posix = @import("posix.zig");
pub const time = @import("std").time;
