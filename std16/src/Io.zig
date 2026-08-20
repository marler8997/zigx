const Io = @This();

const builtin = @import("builtin");

const std = @import("std.zig");
const math = std.math;
const assert = std.debug.assert;
// const Allocator = std.mem.Allocator;
// const Alignment = std.mem.Alignment;

userdata: ?*anyopaque,
vtable: *const VTable,

pub const legacy: Io = .{ .userdata = null, .vtable = &legacy_vtable };

pub const Reader = @import("std").Io.Reader;
pub const Writer = @import("std").Io.Writer;
pub const net = @import("Io/net.zig");
pub const Dir = @import("Io/Dir.zig");
pub const File = @import("Io/File.zig");

pub const VTable = struct {
    now: *const fn (?*anyopaque, Clock) Timestamp,
    netRead: *const fn (?*anyopaque, src: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize,
    netWrite: *const fn (?*anyopaque, dest: net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) net.Stream.Writer.Error!usize,
    netClose: *const fn (?*anyopaque, handle: []const net.Socket.Handle) void,
    netShutdown: *const fn (?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void,
};

// pub const Operation = union(enum) {
//     file_read_streaming: FileReadStreaming,
//     file_write_streaming: FileWriteStreaming,
//     /// On Windows this is NtDeviceIoControlFile. On POSIX this is ioctl. On
//     /// other systems this tag is unreachable.
//     device_io_control: DeviceIoControl,
//     net_receive: NetReceive,

//     pub const Tag = @typeInfo(Operation).@"union".tag_type.?;

//     /// May return 0 reads which is different than `error.EndOfStream`.
//     pub const FileReadStreaming = struct {
//         file: File,
//         data: []const []u8,

//         pub const Error = UnendingError || error{EndOfStream};
//         pub const UnendingError = error{
//             InputOutput,
//             SystemResources,
//             /// Trying to read a directory file descriptor as if it were a file.
//             IsDir,
//             ConnectionResetByPeer,
//             /// File was not opened with read capability.
//             NotOpenForReading,
//             SocketUnconnected,
//             /// Non-blocking has been enabled, and reading from the file descriptor
//             /// would block.
//             WouldBlock,
//             /// In WASI, this error occurs when the file descriptor does
//             /// not hold the required rights to read from it.
//             AccessDenied,
//             /// Unable to read file due to lock. Depending on the `Io` implementation,
//             /// reading from a locked file may return this error, or may ignore the
//             /// lock.
//             LockViolation,
//         } || Io.UnexpectedError;

//         pub const Result = Error!usize;
//     };

//     pub const FileWriteStreaming = struct {
//         file: File,
//         header: []const u8 = &.{},
//         data: []const []const u8,
//         splat: usize = 1,

//         pub const Error = error{
//             DiskQuota,
//             FileTooBig,
//             InputOutput,
//             NoSpaceLeft,
//             DeviceBusy,
//             /// File descriptor does not hold the required rights to write to it.
//             AccessDenied,
//             PermissionDenied,
//             /// File is an unconnected socket, or closed its read end.
//             BrokenPipe,
//             /// Insufficient kernel memory to read from in_fd.
//             SystemResources,
//             NotOpenForWriting,
//             /// The process cannot access the file because another process has locked
//             /// a portion of the file. Windows-only.
//             LockViolation,
//             /// Non-blocking has been enabled and this operation would block.
//             WouldBlock,
//             /// This error occurs when a device gets disconnected before or mid-flush
//             /// while it's being written to - errno(6): No such device or address.
//             NoDevice,
//             FileBusy,
//         } || Io.UnexpectedError;

//         pub const Result = Error!usize;
//     };

//     pub const DeviceIoControl = switch (builtin.os.tag) {
//         .wasi => noreturn,
//         .windows => struct {
//             file: File,
//             code: std.os.windows.CTL_CODE,
//             in: []const u8 = &.{},
//             out: []u8 = &.{},

//             pub const Result = std.os.windows.IO_STATUS_BLOCK;
//         },
//         else => struct {
//             file: File,
//             /// Device-dependent operation code.
//             code: u32,
//             arg: ?*anyopaque,

//             /// Device and operation dependent result. Negative values are
//             /// negative errno.
//             pub const Result = i32;
//         },
//     };

//     pub const NetReceive = struct {
//         socket_handle: net.Socket.Handle,
//         message_buffer: []net.IncomingMessage,
//         data_buffer: []u8,
//         flags: net.ReceiveFlags,

//         pub const Error = error{
//             /// Insufficient memory or other resource internal to the operating system.
//             SystemResources,
//             /// Per-process limit on the number of open file descriptors has been reached.
//             ProcessFdQuotaExceeded,
//             /// System-wide limit on the total number of open files has been reached.
//             SystemFdQuotaExceeded,
//             /// Local end has been shut down on a connection-oriented socket, or
//             /// the socket was never connected.
//             SocketUnconnected,
//             /// The socket type requires that message be sent atomically, and the
//             /// size of the message to be sent made this impossible. The message
//             /// was not transmitted, or was partially transmitted.
//             MessageOversize,
//             /// Network connection was unexpectedly closed by sender.
//             ConnectionResetByPeer,
//             /// The local network interface used to reach the destination is offline.
//             NetworkDown,
//             /// A connectionless packet was previously sent successfully,
//             /// however, it was not received because no service is operating at
//             /// the destination port of the transport on the remote system.
//             /// This caused an ICMP port unreachable packet to be returned to
//             /// the OS where it was queued up to be reported at the next call
//             /// to send or receive on the bound socket.
//             PortUnreachable,
//         } || Io.UnexpectedError;

//         pub const Result = struct { ?net.Socket.ReceiveError, usize };
//     };

//     pub const Result = Result: {
//         const operation_fields = @typeInfo(Operation).@"union".fields;
//         var fields: [operation_fields.len]std.builtin.TypeInfo.UnionField = undefined;
//         for (operation_fields, &fields) |field, *union_field| {
//             union_field.* = .{
//                 .name = field.name,
//                 .type = if (field.type == noreturn) noreturn else field.type.Result,
//             };
//         }
//         break :Result @Type(.{ .@"union" = .{
//             .layout = .auto,
//             .tag_type = Tag,
//             .fields = &fields,
//             .decls = &.{},
//         } });
//     };

//     pub const Storage = union {
//         unused: List.DoubleNode,
//         submission: Submission,
//         pending: Pending,
//         completion: Completion,

//         pub const Submission = struct {
//             node: List.SingleNode,
//             operation: Operation,
//         };

//         pub const Pending = struct {
//             node: List.DoubleNode,
//             tag: Tag,
//             userdata: Userdata align(@max(@alignOf(usize), 4)),

//             pub const Userdata = [7]usize;
//         };

//         pub const Completion = struct {
//             node: List.SingleNode,
//             result: Result,
//         };
//     };

//     pub const OptionalIndex = enum(u32) {
//         none = std.math.maxInt(u32),
//         _,

//         pub fn fromIndex(i: usize) OptionalIndex {
//             const oi: OptionalIndex = @enumFromInt(i);
//             assert(oi != .none);
//             return oi;
//         }

//         pub fn toIndex(oi: OptionalIndex) u32 {
//             assert(oi != .none);
//             return @intFromEnum(oi);
//         }
//     };
//     pub const List = struct {
//         head: OptionalIndex,
//         tail: OptionalIndex,

//         pub const empty: List = .{ .head = .none, .tail = .none };

//         pub const SingleNode = struct { next: OptionalIndex };
//         pub const DoubleNode = struct { prev: OptionalIndex, next: OptionalIndex };
//     };
// };

// /// Performs one `Operation`.
// pub fn operate(io: Io, operation: Operation) Cancelable!Operation.Result {
//     return io.vtable.operate(io.userdata, operation);
// }

// pub const OperateTimeoutError = Cancelable || Timeout.Error || ConcurrentError;

// /// Performs one `Operation` with provided `timeout`.
// pub fn operateTimeout(io: Io, operation: Operation, timeout: Timeout) OperateTimeoutError!Operation.Result {
//     var storage: [1]Operation.Storage = undefined;
//     var batch: Batch = .init(&storage);
//     batch.addAt(0, operation);
//     try batch.awaitConcurrent(io, timeout);
//     const completion = batch.next().?;
//     assert(completion.index == 0);
//     return completion.result;
// }

// /// Submits many operations together without waiting for all of them to
// /// complete.
// ///
// /// This is a low-level abstraction based on `Operation`. For a higher
// /// level API that operates on `Future`, see `Select` and `Group`.
// pub const Batch = struct {
//     storage: []Operation.Storage,
//     unused: Operation.List,
//     submitted: Operation.List,
//     pending: Operation.List,
//     completed: Operation.List,
//     userdata: ?*anyopaque align(@max(@alignOf(?*anyopaque), 4)),

//     /// After calling this, it is safe to unconditionally defer a call to
//     /// `cancel`. `storage` is a pre-allocated buffer of undefined memory that
//     /// determines the maximum number of active operations that can be
//     /// submitted via `add` and `addAt`.
//     pub fn init(storage: []Operation.Storage) Batch {
//         var prev: Operation.OptionalIndex = .none;
//         for (storage, 0..) |*operation, index| {
//             operation.* = .{ .unused = .{ .prev = prev, .next = .fromIndex(index + 1) } };
//             prev = .fromIndex(index);
//         }
//         storage[storage.len - 1].unused.next = .none;
//         return .{
//             .storage = storage,
//             .unused = .{
//                 .head = .fromIndex(0),
//                 .tail = .fromIndex(storage.len - 1),
//             },
//             .submitted = .empty,
//             .pending = .empty,
//             .completed = .empty,
//             .userdata = null,
//         };
//     }

//     /// Adds an operation to be performed at the next await call.
//     /// Returns the index that will be returned by `next` after the operation completes.
//     /// Asserts that no more than `storage.len` operations are active at a time.
//     pub fn add(batch: *Batch, operation: Operation) u32 {
//         const index = batch.unused.head.toIndex();
//         batch.addAt(index, operation);
//         return index;
//     }

//     /// Adds an operation to be performed at the next await call.
//     /// After the operation completes, `next` will return `index`.
//     /// Asserts that the operation at `index` is not active.
//     pub fn addAt(batch: *Batch, index: u32, operation: Operation) void {
//         const storage = &batch.storage[index];
//         const unused = storage.unused;
//         switch (unused.prev) {
//             .none => batch.unused.head = unused.next,
//             else => |prev_index| batch.storage[prev_index.toIndex()].unused.next = unused.next,
//         }
//         switch (unused.next) {
//             .none => batch.unused.tail = unused.prev,
//             else => |next_index| batch.storage[next_index.toIndex()].unused.prev = unused.prev,
//         }

//         switch (batch.submitted.tail) {
//             .none => batch.submitted.head = .fromIndex(index),
//             else => |tail_index| batch.storage[tail_index.toIndex()].submission.node.next = .fromIndex(index),
//         }
//         storage.* = .{ .submission = .{ .node = .{ .next = .none }, .operation = operation } };
//         batch.submitted.tail = .fromIndex(index);
//     }

//     pub const Completion = struct {
//         /// The element within the provided operation storage that completed.
//         /// `addAt` can be used to re-arm the `Batch` using this `index`.
//         index: u32,
//         /// The return value of the operation.
//         result: Operation.Result,
//     };

//     /// After calling `awaitAsync`, `awaitConcurrent`, or `cancel`, this
//     /// function iterates over the completed operations.
//     ///
//     /// Each completion returned from this function dequeues from the `Batch`.
//     /// It is not required to dequeue all completions before awaiting again.
//     pub fn next(batch: *Batch) ?Completion {
//         const index = batch.completed.head;
//         if (index == .none) return null;
//         const storage = &batch.storage[index.toIndex()];
//         const completion = storage.completion;
//         const next_index = completion.node.next;
//         batch.completed.head = next_index;
//         if (next_index == .none) batch.completed.tail = .none;

//         const tail_index = batch.unused.tail;
//         switch (tail_index) {
//             .none => batch.unused.head = index,
//             else => batch.storage[tail_index.toIndex()].unused.next = index,
//         }
//         storage.* = .{ .unused = .{ .prev = tail_index, .next = .none } };
//         batch.unused.tail = index;
//         return .{ .index = index.toIndex(), .result = completion.result };
//     }

//     /// Waits for at least one of the submitted operations to complete. After
//     /// this function returns the completed operations can be iterated with
//     /// `next`.
//     ///
//     /// This function provides opportunity for the implementation to introduce
//     /// concurrency into the batched operations, but unlike `awaitConcurrent`,
//     /// does not require it, and therefore cannot fail with
//     /// `error.ConcurrencyUnavailable`.
//     pub fn awaitAsync(batch: *Batch, io: Io) Cancelable!void {
//         return io.vtable.batchAwaitAsync(io.userdata, batch);
//     }

//     pub const AwaitConcurrentError = ConcurrentError || Cancelable || Timeout.Error;

//     /// Waits for at least one of the submitted operations to complete. After
//     /// this function returns the completed operations can be iterated with
//     /// `next`.
//     ///
//     /// Unlike `awaitAsync`, this function requires the implementation to
//     /// perform the operations concurrently and therefore can fail with
//     /// `error.ConcurrencyUnavailable`.
//     pub fn awaitConcurrent(batch: *Batch, io: Io, timeout: Timeout) AwaitConcurrentError!void {
//         return io.vtable.batchAwaitConcurrent(io.userdata, batch, timeout);
//     }

//     /// Requests all pending operations to be interrupted, then waits for all
//     /// pending operations to complete. After this returns, the `Batch` is in a
//     /// well-defined state, ready to be iterated with `next`. Successfully
//     /// canceled operations will be absent from the iteration. Some operations
//     /// may have successfully completed regardless of the cancel request and
//     /// will appear in the iteration.
//     pub fn cancel(batch: *Batch, io: Io) void {
//         { // abort pending submissions
//             var tail_index = batch.unused.tail;
//             defer batch.unused.tail = tail_index;
//             var index = batch.submitted.head;
//             errdefer batch.submissions.head = index;
//             while (index != .none) {
//                 const next_index = batch.storage[index.toIndex()].submission.node.next;
//                 switch (tail_index) {
//                     .none => batch.unused.head = index,
//                     else => batch.storage[tail_index.toIndex()].unused.next = index,
//                 }
//                 batch.storage[index.toIndex()] = .{ .unused = .{ .prev = tail_index, .next = .none } };
//                 tail_index = index;
//                 index = next_index;
//             }
//             batch.submitted = .{ .head = .none, .tail = .none };
//         }
//         io.vtable.batchCancel(io.userdata, batch);
//         assert(batch.submitted.head == .none and batch.submitted.tail == .none);
//         assert(batch.pending.head == .none and batch.pending.tail == .none);
//         assert(batch.userdata == null); // that was the last chance to deallocate resources
//     }
// };

pub const Limit = @import("std").Io.Limit;
// pub const Limit = enum(usize) {
//     nothing = 0,
//     unlimited = math.maxInt(usize),
//     _,

//     /// `math.maxInt(usize)` is interpreted to mean `.unlimited`.
//     pub fn limited(n: usize) Limit {
//         return @enumFromInt(n);
//     }

//     /// Any value grater than `math.maxInt(usize)` is interpreted to mean
//     /// `.unlimited`.
//     pub fn limited64(n: u64) Limit {
//         return @enumFromInt(@min(n, math.maxInt(usize)));
//     }

//     pub fn countVec(data: []const []const u8) Limit {
//         var total: usize = 0;
//         for (data) |d| total += d.len;
//         return .limited(total);
//     }

//     pub fn min(a: Limit, b: Limit) Limit {
//         return @enumFromInt(@min(@intFromEnum(a), @intFromEnum(b)));
//     }

//     pub fn max(a: Limit, b: Limit) Limit {
//         if (a == .unlimited or b == .unlimited) {
//             return .unlimited;
//         }

//         return @enumFromInt(@max(@intFromEnum(a), @intFromEnum(b)));
//     }

//     pub fn minInt(l: Limit, n: usize) usize {
//         return @min(n, @intFromEnum(l));
//     }

//     pub fn minInt64(l: Limit, n: u64) usize {
//         return @min(n, @intFromEnum(l));
//     }

//     pub fn slice(l: Limit, s: []u8) []u8 {
//         return s[0..l.minInt(s.len)];
//     }

//     pub fn sliceConst(l: Limit, s: []const u8) []const u8 {
//         return s[0..l.minInt(s.len)];
//     }

//     pub fn toInt(l: Limit) ?usize {
//         return switch (l) {
//             else => @intFromEnum(l),
//             .unlimited => null,
//         };
//     }

//     /// Reduces a slice to account for the limit, leaving room for one extra
//     /// byte above the limit, allowing for the use case of differentiating
//     /// between end-of-stream and reaching the limit.
//     pub fn slice1(l: Limit, non_empty_buffer: []u8) []u8 {
//         assert(non_empty_buffer.len >= 1);
//         return non_empty_buffer[0..@min(@intFromEnum(l) +| 1, non_empty_buffer.len)];
//     }

//     pub fn nonzero(l: Limit) bool {
//         return l != .nothing;
//     }

//     /// Return a new limit reduced by `amount` or return `null` indicating
//     /// limit would be exceeded.
//     pub fn subtract(l: Limit, amount: usize) ?Limit {
//         if (l == .unlimited) return .unlimited;
//         if (amount > @intFromEnum(l)) return null;
//         return @enumFromInt(@intFromEnum(l) - amount);
//     }
// };

pub const Cancelable = error{
    /// Caller has requested the async operation to stop.
    Canceled,
};

pub const UnexpectedError = error{
    /// The Operating System returned an undocumented error code.
    ///
    /// This error is in theory not possible, but it would be better
    /// to handle this error than to invoke undefined behavior.
    ///
    /// When this error code is observed, it usually means the Zig Standard
    /// Library needs a small patch to add the error code to the error set for
    /// the respective function.
    Unexpected,
};

pub const Clock = enum {
    /// A settable system-wide clock that measures real (i.e. wall-clock)
    /// time. This clock is affected by discontinuous jumps in the system
    /// time (e.g., if the system administrator manually changes the
    /// clock), and by frequency adjustments performed by NTP and similar
    /// applications.
    ///
    /// This clock normally counts the number of seconds since 1970-01-01
    /// 00:00:00 Coordinated Universal Time (UTC) except that it ignores
    /// leap seconds; near a leap second it is typically adjusted by NTP to
    /// stay roughly in sync with UTC.
    ///
    /// Timestamps returned by implementations of this clock represent time
    /// elapsed since 1970-01-01T00:00:00Z, the POSIX/Unix epoch, ignoring
    /// leap seconds. This is colloquially known as "Unix time". If the
    /// underlying OS uses a different epoch for native timestamps (e.g.,
    /// Windows, which uses 1601-01-01) they are translated accordingly.
    real,
    /// A nonsettable system-wide clock that represents time since some
    /// unspecified point in the past.
    ///
    /// Monotonic: Guarantees that the time returned by consecutive calls
    /// will not go backwards, but successive calls may return identical
    /// (not-increased) time values.
    ///
    /// Not affected by discontinuous jumps in the system time (e.g., if
    /// the system administrator manually changes the clock), but may be
    /// affected by frequency adjustments.
    ///
    /// This clock expresses intent to **exclude time that the system is
    /// suspended**. However, implementations may be unable to satisify
    /// this, and may include that time.
    ///
    /// * On Linux, corresponds `CLOCK_MONOTONIC`.
    /// * On macOS, corresponds to `CLOCK_UPTIME_RAW`.
    awake,
    /// Identical to `awake` except it expresses intent to **include time
    /// that the system is suspended**, however, due to limitations it may
    /// behave identically to `awake`.
    ///
    /// * On Linux, corresponds `CLOCK_BOOTTIME`.
    /// * On macOS, corresponds to `CLOCK_MONOTONIC_RAW`.
    boot,
    /// Tracks the amount of CPU in user or kernel mode used by the calling
    /// process.
    cpu_process,
    /// Tracks the amount of CPU in user or kernel mode used by the calling
    /// thread.
    cpu_thread,

    /// This function is not cancelable because it does not block.
    ///
    /// Resolution is determined by `resolution` which may be 0 if the
    /// clock is unsupported.
    ///
    /// See also:
    /// * `Clock.Timestamp.now`
    pub fn now(clock: Clock, io: Io) Io.Timestamp {
        return io.vtable.now(io.userdata, clock);
    }

    pub const ResolutionError = error{
        ClockUnavailable,
        Unexpected,
    };

    /// Reveals the granularity of `clock`. May be zero, indicating
    /// unsupported clock.
    pub fn resolution(clock: Clock, io: Io) ResolutionError!Io.Duration {
        return io.vtable.clockResolution(io.userdata, clock);
    }

    pub const Timestamp = struct {
        raw: Io.Timestamp,
        clock: Clock,

        /// This function is not cancelable because it does not block.
        ///
        /// Resolution is determined by `resolution` which may be 0 if
        /// the clock is unsupported.
        ///
        /// See also:
        /// * `Clock.now`
        pub fn now(io: Io, clock: Clock) Clock.Timestamp {
            return .{
                .raw = io.vtable.now(io.userdata, clock),
                .clock = clock,
            };
        }

        /// Sleeps until the timestamp arrives.
        ///
        /// See also:
        /// * `Io.sleep`
        /// * `Clock.Duration.sleep`
        /// * `Timeout.sleep`
        pub fn wait(t: Clock.Timestamp, io: Io) Cancelable!void {
            return io.vtable.sleep(io.userdata, .{ .deadline = t });
        }

        pub fn durationTo(from: Clock.Timestamp, to: Clock.Timestamp) Clock.Duration {
            assert(from.clock == to.clock);
            return .{
                .raw = from.raw.durationTo(to.raw),
                .clock = from.clock,
            };
        }

        pub fn addDuration(from: Clock.Timestamp, duration: Clock.Duration) Clock.Timestamp {
            assert(from.clock == duration.clock);
            return .{
                .raw = from.raw.addDuration(duration.raw),
                .clock = from.clock,
            };
        }

        pub fn subDuration(from: Clock.Timestamp, duration: Clock.Duration) Clock.Timestamp {
            assert(from.clock == duration.clock);
            return .{
                .raw = from.raw.subDuration(duration.raw),
                .clock = from.clock,
            };
        }

        /// Resolution is determined by `resolution` which may be 0 if
        /// the clock is unsupported.
        pub fn fromNow(io: Io, duration: Clock.Duration) Clock.Timestamp {
            return .{
                .clock = duration.clock,
                .raw = duration.clock.now(io).addDuration(duration.raw),
            };
        }

        /// Resolution is determined by `resolution` which may be 0 if
        /// the clock is unsupported.
        pub fn untilNow(timestamp: Clock.Timestamp, io: Io) Clock.Duration {
            const now_ts = Clock.Timestamp.now(io, timestamp.clock);
            return timestamp.durationTo(now_ts);
        }

        /// Resolution is determined by `resolution` which may be 0 if
        /// the clock is unsupported.
        pub fn durationFromNow(timestamp: Clock.Timestamp, io: Io) Clock.Duration {
            const now_ts = timestamp.clock.now(io);
            return .{
                .clock = timestamp.clock,
                .raw = now_ts.durationTo(timestamp.raw),
            };
        }

        /// Resolution is determined by `resolution` which may be 0 if
        /// the clock is unsupported.
        pub fn toClock(t: Clock.Timestamp, io: Io, clock: Clock) Clock.Timestamp {
            if (t.clock == clock) return t;
            const now_old = t.clock.now(io);
            const now_new = clock.now(io);
            const duration = now_old.durationTo(t);
            return .{
                .clock = clock,
                .raw = now_new.addDuration(duration),
            };
        }

        pub fn compare(lhs: Clock.Timestamp, op: math.CompareOperator, rhs: Clock.Timestamp) bool {
            assert(lhs.clock == rhs.clock);
            return math.compare(lhs.raw.nanoseconds, op, rhs.raw.nanoseconds);
        }
    };

    pub const Duration = struct {
        raw: Io.Duration,
        clock: Clock,

        /// Waits until a specified amount of time has passed on `clock`.
        ///
        /// See also:
        /// * `Io.sleep`
        /// * `Clock.Timestamp.wait`
        /// * `Timeout.sleep`
        pub fn sleep(duration: Clock.Duration, io: Io) Cancelable!void {
            return io.vtable.sleep(io.userdata, .{ .duration = duration });
        }
    };
};

pub const Timestamp = struct {
    nanoseconds: i96,

    pub fn now(io: Io, clock: Clock) Io.Timestamp {
        return io.vtable.now(io.userdata, clock);
    }

    pub const zero: Timestamp = .{ .nanoseconds = 0 };

    pub fn durationTo(from: Timestamp, to: Timestamp) Duration {
        return .{ .nanoseconds = to.nanoseconds - from.nanoseconds };
    }

    pub fn addDuration(from: Timestamp, duration: Duration) Timestamp {
        return .{ .nanoseconds = from.nanoseconds + duration.nanoseconds };
    }

    pub fn subDuration(from: Timestamp, duration: Duration) Timestamp {
        return .{ .nanoseconds = from.nanoseconds - duration.nanoseconds };
    }

    pub fn withClock(t: Timestamp, clock: Clock) Clock.Timestamp {
        return .{ .raw = t, .clock = clock };
    }

    pub fn fromNanoseconds(x: i96) Timestamp {
        return .{ .nanoseconds = x };
    }

    pub fn toMicroseconds(t: Timestamp) i64 {
        return @intCast(@divTrunc(t.nanoseconds, std.time.ns_per_us));
    }

    pub fn toMilliseconds(t: Timestamp) i64 {
        return @intCast(@divTrunc(t.nanoseconds, std.time.ns_per_ms));
    }

    pub fn toSeconds(t: Timestamp) i64 {
        return @intCast(@divTrunc(t.nanoseconds, std.time.ns_per_s));
    }

    pub fn toNanoseconds(t: Timestamp) i96 {
        return t.nanoseconds;
    }

    pub fn formatNumber(t: Timestamp, w: *std.Io.Writer, n: std.fmt.Number) std.Io.Writer.Error!void {
        return w.printInt(t.nanoseconds, n.mode.base() orelse 10, n.case, .{
            .precision = n.precision,
            .width = n.width,
            .alignment = n.alignment,
            .fill = n.fill,
        });
    }

    /// Resolution is determined by `Clock.resolution` which may be 0 if
    /// the clock is unsupported.
    pub fn untilNow(t: Timestamp, io: Io, clock: Clock) Duration {
        const now_ts = clock.now(io);
        return t.durationTo(now_ts);
    }
};

pub const Duration = struct {
    nanoseconds: i96,

    pub const zero: Duration = .{ .nanoseconds = 0 };
    pub const max: Duration = .{ .nanoseconds = math.maxInt(i96) };

    pub fn fromNanoseconds(x: i96) Duration {
        return .{ .nanoseconds = x };
    }

    pub fn fromMicroseconds(x: i64) Duration {
        return .{ .nanoseconds = @as(i96, x) * std.time.ns_per_us };
    }

    pub fn fromMilliseconds(x: i64) Duration {
        return .{ .nanoseconds = @as(i96, x) * std.time.ns_per_ms };
    }

    pub fn fromSeconds(x: i64) Duration {
        return .{ .nanoseconds = @as(i96, x) * std.time.ns_per_s };
    }

    pub fn toMicroseconds(d: Duration) i64 {
        return @intCast(@divTrunc(d.nanoseconds, std.time.ns_per_us));
    }

    pub fn toMilliseconds(d: Duration) i64 {
        return @intCast(@divTrunc(d.nanoseconds, std.time.ns_per_ms));
    }

    pub fn toSeconds(d: Duration) i64 {
        return @intCast(@divTrunc(d.nanoseconds, std.time.ns_per_s));
    }

    pub fn toNanoseconds(d: Duration) i96 {
        return d.nanoseconds;
    }

    /// Write number of nanoseconds according to its signed magnitude:
    /// `[#y][#w][#d][#h][#m]#[.###][n|u|m]s`
    pub fn format(duration: Duration, w: *Writer) Writer.Error!void {
        if (duration.nanoseconds < 0) try w.writeByte('-');
        return formatUnsigned(w, @abs(duration.nanoseconds));
    }

    fn formatUnsigned(w: *Writer, ns: u96) Writer.Error!void {
        var ns_remaining = ns;
        inline for (.{
            .{ .ns = 365 * std.time.ns_per_day, .sep = 'y' },
            .{ .ns = std.time.ns_per_week, .sep = 'w' },
            .{ .ns = std.time.ns_per_day, .sep = 'd' },
            .{ .ns = std.time.ns_per_hour, .sep = 'h' },
            .{ .ns = std.time.ns_per_min, .sep = 'm' },
        }) |unit| {
            if (ns_remaining >= unit.ns) {
                const units = ns_remaining / unit.ns;
                try w.printInt(units, 10, .lower, .{});
                try w.writeByte(unit.sep);
                ns_remaining -= units * unit.ns;
                if (ns_remaining == 0) return;
            }
        }

        inline for (.{
            .{ .ns = std.time.ns_per_s, .sep = "s" },
            .{ .ns = std.time.ns_per_ms, .sep = "ms" },
            .{ .ns = std.time.ns_per_us, .sep = "us" },
        }) |unit| {
            const kunits = ns_remaining * 1000 / unit.ns;
            if (kunits >= 1000) {
                try w.printInt(kunits / 1000, 10, .lower, .{});
                const frac = kunits % 1000;
                if (frac > 0) {
                    // Write up to 3 decimal places
                    var decimal_buf = [_]u8{ '.', 0, 0, 0 };
                    var inner: Writer = .fixed(decimal_buf[1..]);
                    inner.printInt(frac, 10, .lower, .{ .fill = '0', .width = 3 }) catch unreachable;
                    var end: usize = 4;
                    while (end > 1) : (end -= 1) {
                        if (decimal_buf[end - 1] != '0') break;
                    }
                    try w.writeAll(decimal_buf[0..end]);
                }
                return w.writeAll(unit.sep);
            }
        }

        try w.printInt(ns_remaining, 10, .lower, .{});
        try w.writeAll("ns");
    }

    test format {
        try testFormat("0ns", 0);
        try testFormat("1ns", 1);
        try testFormat("-1ns", -(1));
        try testFormat("999ns", std.time.ns_per_us - 1);
        try testFormat("-999ns", -(std.time.ns_per_us - 1));
        try testFormat("1us", std.time.ns_per_us);
        try testFormat("-1us", -(std.time.ns_per_us));
        try testFormat("1.45us", 1450);
        try testFormat("-1.45us", -(1450));
        try testFormat("1.5us", 3 * std.time.ns_per_us / 2);
        try testFormat("-1.5us", -(3 * std.time.ns_per_us / 2));
        try testFormat("14.5us", 14500);
        try testFormat("-14.5us", -(14500));
        try testFormat("145us", 145000);
        try testFormat("-145us", -(145000));
        try testFormat("999.999us", std.time.ns_per_ms - 1);
        try testFormat("-999.999us", -(std.time.ns_per_ms - 1));
        try testFormat("1ms", std.time.ns_per_ms + 1);
        try testFormat("-1ms", -(std.time.ns_per_ms + 1));
        try testFormat("1.5ms", 3 * std.time.ns_per_ms / 2);
        try testFormat("-1.5ms", -(3 * std.time.ns_per_ms / 2));
        try testFormat("1.11ms", 1110000);
        try testFormat("-1.11ms", -(1110000));
        try testFormat("1.111ms", 1111000);
        try testFormat("-1.111ms", -(1111000));
        try testFormat("1.111ms", 1111100);
        try testFormat("-1.111ms", -(1111100));
        try testFormat("999.999ms", std.time.ns_per_s - 1);
        try testFormat("-999.999ms", -(std.time.ns_per_s - 1));
        try testFormat("1s", std.time.ns_per_s);
        try testFormat("-1s", -(std.time.ns_per_s));
        try testFormat("59.999s", std.time.ns_per_min - 1);
        try testFormat("-59.999s", -(std.time.ns_per_min - 1));
        try testFormat("1m", std.time.ns_per_min);
        try testFormat("-1m", -(std.time.ns_per_min));
        try testFormat("1h", std.time.ns_per_hour);
        try testFormat("-1h", -(std.time.ns_per_hour));
        try testFormat("1d", std.time.ns_per_day);
        try testFormat("-1d", -(std.time.ns_per_day));
        try testFormat("1w", std.time.ns_per_week);
        try testFormat("-1w", -(std.time.ns_per_week));
        try testFormat("1y", 365 * std.time.ns_per_day);
        try testFormat("-1y", -(365 * std.time.ns_per_day));
        try testFormat("1y52w23h59m59.999s", 730 * std.time.ns_per_day - 1); // 365d = 52w1d
        try testFormat("-1y52w23h59m59.999s", -(730 * std.time.ns_per_day - 1)); // 365d = 52w1d
        try testFormat("1y1h1.001s", 365 * std.time.ns_per_day + std.time.ns_per_hour + std.time.ns_per_s + std.time.ns_per_ms);
        try testFormat("-1y1h1.001s", -(365 * std.time.ns_per_day + std.time.ns_per_hour + std.time.ns_per_s + std.time.ns_per_ms));
        try testFormat("1y1h1s", 365 * std.time.ns_per_day + std.time.ns_per_hour + std.time.ns_per_s + 999 * std.time.ns_per_us);
        try testFormat("-1y1h1s", -(365 * std.time.ns_per_day + std.time.ns_per_hour + std.time.ns_per_s + 999 * std.time.ns_per_us));
        try testFormat("1y1h999.999us", 365 * std.time.ns_per_day + std.time.ns_per_hour + std.time.ns_per_ms - 1);
        try testFormat("-1y1h999.999us", -(365 * std.time.ns_per_day + std.time.ns_per_hour + std.time.ns_per_ms - 1));
        try testFormat("1y1h1ms", 365 * std.time.ns_per_day + std.time.ns_per_hour + std.time.ns_per_ms);
        try testFormat("-1y1h1ms", -(365 * std.time.ns_per_day + std.time.ns_per_hour + std.time.ns_per_ms));
        try testFormat("1y1h1ms", 365 * std.time.ns_per_day + std.time.ns_per_hour + std.time.ns_per_ms + 1);
        try testFormat("-1y1h1ms", -(365 * std.time.ns_per_day + std.time.ns_per_hour + std.time.ns_per_ms + 1));
        try testFormat("1y1m999ns", 365 * std.time.ns_per_day + std.time.ns_per_min + 999);
        try testFormat("-1y1m999ns", -(365 * std.time.ns_per_day + std.time.ns_per_min + 999));
        try testFormat("292y24w3d23h47m16.854s", std.math.maxInt(i64));
        try testFormat("-292y24w3d23h47m16.854s", std.math.minInt(i64) + 1);
        try testFormat("-292y24w3d23h47m16.854s", std.math.minInt(i64));
    }

    fn testFormat(expected: []const u8, input: i96) !void {
        // worst case: "-XXXXXXXXXXXXXyXXwXXdXXhXXmXX.XXXs".len = 34
        var buf: [34]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try w.print("{f}", .{Duration{ .nanoseconds = input }});
        try std.testing.expectEqualStrings(expected, w.buffered());
    }
};

pub const AnyFuture = opaque {};

pub const ConcurrentError = error{
    /// May occur due to a temporary condition such as resource exhaustion, or
    /// to the Io implementation not supporting concurrency.
    ConcurrencyUnavailable,
};

// Implementation of the Io vtable for pre-0.16 using std.net.Stream.
const std15 = @import("std");

pub const legacy_vtable: VTable = .{
    .now = legacyNow,
    .netRead = legacyNetRead,
    .netWrite = legacyNetWrite,
    .netClose = legacyNetClose,
    .netShutdown = legacyNetShutdown,
};

pub fn legacyIo() Io {
    return .{ .userdata = null, .vtable = &legacy_vtable };
}

fn toStream(handle: net.Socket.Handle) std15.net.Stream {
    return .{ .handle = handle };
}

fn legacyNow(_: ?*anyopaque, clock: Clock) Timestamp {
    const Clock2 = enum { awake, boot, cpu_process, cpu_thread };
    const clock2: Clock2 = switch (clock) {
        .real => return .{ .nanoseconds = @intCast(std15.time.nanoTimestamp()) },
        inline else => |c| @field(Clock2, @tagName(c)),
    };
    if (builtin.os.tag == .windows) {
        switch (clock2) {
            .awake, .boot => {
                const qpc = std.os.windows.QueryPerformanceCounter();
                const qpf = std.os.windows.QueryPerformanceFrequency();
                return .{ .nanoseconds = @divFloor(@as(i96, qpc) * std15.time.ns_per_s, @as(i96, qpf)) };
            },
            .cpu_process, .cpu_thread => @panic("cpu clocks not implemented on windows"),
        }
    } else {
        const posix = std15.posix;
        const is_darwin = switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos => true,
            else => false,
        };
        const clock_id: posix.clockid_t = switch (clock2) {
            .awake => if (is_darwin) posix.CLOCK.UPTIME_RAW else posix.CLOCK.MONOTONIC,
            .boot => if (is_darwin) posix.CLOCK.MONOTONIC_RAW else posix.CLOCK.BOOTTIME,
            .cpu_process => posix.CLOCK.PROCESS_CPUTIME_ID,
            .cpu_thread => posix.CLOCK.THREAD_CPUTIME_ID,
        };
        const ts = posix.clock_gettime(clock_id) catch @panic("clock_gettime failed");
        const ns = @as(i96, ts.sec) * std15.time.ns_per_s + @as(i96, ts.nsec);
        return .{ .nanoseconds = ns };
    }
}

fn legacyNetRead(_: ?*anyopaque, src: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
    if (builtin.os.tag == .windows) {
        // ReadFile doesn't work with WSA_FLAG_OVERLAPPED sockets created by posix.socket; use WSARecv.
        const windows = std.os.windows;
        const ws2_32 = windows.ws2_32;
        var bufs: [8]ws2_32.WSABUF = undefined;
        var count: u32 = 0;
        for (data) |d| {
            if (d.len > 0 and count < bufs.len) {
                bufs[count] = .{ .len = @intCast(d.len), .buf = d.ptr };
                count += 1;
            }
        }
        if (count == 0) return 0;
        var n: u32 = undefined;
        var flags: u32 = 0;
        var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        if (ws2_32.WSARecv(src, &bufs, count, &n, &flags, &overlapped, null) == ws2_32.SOCKET_ERROR) switch (ws2_32.WSAGetLastError()) {
            .WSA_IO_PENDING => {
                var result_flags: u32 = undefined;
                if (ws2_32.WSAGetOverlappedResult(src, &overlapped, &n, windows.TRUE, &result_flags) == windows.FALSE) switch (ws2_32.WSAGetLastError()) {
                    .WSAECONNRESET, .WSAECONNABORTED, .WSAENETRESET => return error.ConnectionResetByPeer,
                    else => return error.Unexpected,
                };
            },
            .WSAECONNRESET, .WSAECONNABORTED, .WSAENETRESET => return error.ConnectionResetByPeer,
            else => return error.Unexpected,
        };
        return n;
    }
    return toStream(src).readv(@ptrCast(data)) catch |err| switch (err) {
        error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
        error.Unexpected => return error.Unexpected,
        else => return error.Unexpected,
    };
}

fn legacyNetWrite(_: ?*anyopaque, dest: net.Socket.Handle, header: []const u8, data: []const []const u8, splat: usize) net.Stream.Writer.Error!usize {
    _ = splat;
    if (builtin.os.tag == .windows) {
        // WriteFile doesn't work with WSA_FLAG_OVERLAPPED sockets created by posix.socket; use WSASend.
        const windows = std.os.windows;
        const ws2_32 = windows.ws2_32;
        var bufs: [9]ws2_32.WSABUF = undefined;
        var count: u32 = 0;
        if (header.len > 0) {
            bufs[count] = .{ .len = @intCast(header.len), .buf = @constCast(header.ptr) };
            count += 1;
        }
        for (data) |d| {
            if (d.len > 0 and count < bufs.len) {
                bufs[count] = .{ .len = @intCast(d.len), .buf = @constCast(d.ptr) };
                count += 1;
            }
        }
        if (count == 0) return 0;
        var n: u32 = undefined;
        var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        if (ws2_32.WSASend(dest, &bufs, count, &n, 0, &overlapped, null) == ws2_32.SOCKET_ERROR) switch (ws2_32.WSAGetLastError()) {
            .WSA_IO_PENDING => {
                var result_flags: u32 = undefined;
                if (ws2_32.WSAGetOverlappedResult(dest, &overlapped, &n, windows.TRUE, &result_flags) == windows.FALSE) switch (ws2_32.WSAGetLastError()) {
                    .WSAECONNRESET, .WSAECONNABORTED, .WSAENETRESET => return error.ConnectionResetByPeer,
                    else => return error.Unexpected,
                };
            },
            .WSAECONNRESET, .WSAECONNABORTED, .WSAENETRESET => return error.ConnectionResetByPeer,
            else => return error.Unexpected,
        };
        return n;
    }
    var iovecs: [9]std15.posix.iovec_const = undefined;
    var count: usize = 0;
    if (header.len > 0) {
        iovecs[count] = .{ .base = header.ptr, .len = header.len };
        count += 1;
    }
    for (data) |d| {
        if (d.len > 0 and count < iovecs.len) {
            iovecs[count] = .{ .base = d.ptr, .len = d.len };
            count += 1;
        }
    }
    return toStream(dest).writev(@ptrCast(iovecs[0..count])) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
        error.Unexpected => return error.Unexpected,
        else => return error.Unexpected,
    };
}

fn legacyNetClose(_: ?*anyopaque, handles: []const net.Socket.Handle) void {
    for (handles) |h| {
        toStream(h).close();
    }
}

fn legacyNetShutdown(_: ?*anyopaque, handle: net.Socket.Handle, how: net.ShutdownHow) net.ShutdownError!void {
    std15.posix.shutdown(handle, @enumFromInt(@intFromEnum(how))) catch |err| switch (err) {
        error.Unexpected => return error.Unexpected,
        else => return error.Unexpected,
    };
}
