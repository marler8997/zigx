const std = @import("std");
const x11 = @import("x11");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

const window_width = 400;
const window_height = 400;

const Key = enum {
    escape,
    w,
    i,
    d,
    g,
    c,
    l,
};

const bg_color = 0x231a20;
const fg_color = 0xadccfa;

const Ids = struct {
    base: x11.ResourceBase,

    pub fn window(self: Ids) x11.Window {
        return self.base.add(0).window();
    }
    pub fn bg(self: Ids) x11.GraphicsContext {
        return self.base.add(1).graphicsContext();
    }
    pub fn fg(self: Ids) x11.GraphicsContext {
        return self.base.add(2).graphicsContext();
    }
    pub fn childWindow(self: Ids) x11.Window {
        return self.base.add(3).window();
    }
};

pub fn main() !u8 {
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

    var keycode_map = std.AutoHashMapUnmanaged(u8, Key){};

    {
        var it = try x11.synchronousGetKeyboardMapping(&sink, &source, try .init(
            setup.min_keycode,
            setup.max_keycode,
        ));
        for (setup.min_keycode..@as(usize, setup.max_keycode) + 1) |keycode| {
            for (try it.readSyms(&source)) |sym| {
                if (@as(?Key, switch (sym) {
                    .kbd_escape => .escape,
                    .latin_w => .w,
                    .latin_i => .i,
                    .latin_d => .d,
                    .latin_g,
                    => .g,
                    .latin_c,
                    => .c,
                    .latin_l => .l,
                    else => null,
                })) |key| {
                    try keycode_map.put(allocator, @intCast(keycode), key);
                }
            }
        }
    }

    const ids: Ids = .{ .base = setup.resource_id_base };

    try sink.CreateWindow(.{
        .window_id = ids.window(),
        .parent_window_id = screen.root,
        .depth = 0, // dont care, inherit from parent
        .x = 0,
        .y = 0,
        .width = window_width,
        .height = window_height,
        .border_width = 0, // TODO: what is this?
        .class = .input_output,
        .visual_id = screen.root_visual,
    }, .{
        .bg_pixel = bg_color,
        .event_mask = .{
            .KeyPress = 1,
            .PointerMotion = 1,
            .Exposure = 1,
        },
    });

    try sink.CreateGc(
        ids.bg(),
        ids.window().drawable(),
        .{ .foreground = fg_color },
    );
    try sink.CreateGc(
        ids.fg(),
        ids.window().drawable(),
        .{
            .background = bg_color,
            .foreground = fg_color,
        },
    );

    const font_dims: FontDims = blk: {
        try sink.QueryTextExtents(ids.fg().fontable(), .initComptime(&[_]u16{'m'}));
        try sink.writer.flush();
        const extents, _ = try source.readSynchronousReplyFull(sink.sequence, .QueryTextExtents);
        std.log.info("text extents: {}", .{extents});
        break :blk .{
            .width = @intCast(extents.overall_width),
            .height = @intCast(extents.font_ascent + extents.font_descent),
            .font_left = @intCast(extents.overall_left),
            .font_ascent = extents.font_ascent,
        };
    };

    try sink.MapWindow(ids.window());

    var state = State{};

    try sink.QueryExtension(x11.inputext.name);
    state.xinput = .{ .sent_extension_query = .{
        .sequence = sink.sequence,
    } };

    while (true) {
        try sink.writer.flush();
        const msg_kind = source.readKind() catch |err| return switch (err) {
            error.EndOfStream => {
                std.log.info("X11 connection closed (EndOfStream)", .{});
                std.process.exit(0);
            },
            else => |e| switch (io.socket_reader.getError() orelse e) {
                error.ConnectionResetByPeer => {
                    std.log.info("X11 connection closed (ConnectionReset)", .{});
                    return std.process.exit(0);
                },
                else => |e2| e2,
            },
        };
        switch (msg_kind) {
            .Error => std.debug.panic("X11 {f}", .{source.readFmt()}),
            .Reply => {
                const reply = try source.read2(.Reply);
                const handled = try handleReply(
                    reply,
                    &source,
                    &sink,
                    &state,
                    screen.root,
                    ids.window(),
                    ids.bg(),
                    ids.fg(),
                    font_dims,
                );
                if (!handled) {
                    std.log.info("unexpected X11 reply: {}", .{reply});
                    std.process.exit(0xff);
                }
                // just always do another render, it's *probably* needed
                try render(&sink, ids.window(), ids.bg(), ids.fg(), font_dims, state);
            },
            .KeyPress => {
                const event = try source.read2(.KeyPress);
                var do_render = true;
                if (keycode_map.get(event.keycode)) |key| switch (key) {
                    .g => {
                        //try state.toggleGrab(&sink, screen.root);
                        try state.toggleGrab(&sink, ids.window());
                    },
                    .w => try warpPointer(&sink),
                    .c => {
                        state.confine_grab = !state.confine_grab;
                    },
                    .i => if (state.window_created) {
                        try sink.DestroyWindow(ids.childWindow());
                        state.window_created = false;
                    } else {
                        try createWindow(&sink, screen.root, ids.childWindow());
                        state.window_created = true;
                    },
                    .d => {
                        try disableInputDevice(&sink, &state);
                    },
                    .l => {
                        try listenToRawEvents(&sink, &state, screen.root);
                    },
                    .escape => {
                        std.log.info("ESC pressed, exiting loop...", .{});
                        return 0;
                    },
                } else {
                    // std.log.info("{}", .{event.keycode});
                    do_render = false;
                }
                if (do_render) {
                    try render(&sink, ids.window(), ids.bg(), ids.fg(), font_dims, state);
                }
            },
            // NOTE: server will send us KeyRelease when the user holds down a key
            //       even though we didn't register for the KeyRelease event
            .KeyRelease => _ = try source.discardRemaining(),
            .MotionNotify => {
                const motion = try source.read2(.MotionNotify);
                // too much logging
                //std.log.info("{}", .{motion});
                state.pointer_root_pos.x = motion.root_x;
                state.pointer_root_pos.y = motion.root_y;
                state.pointer_event_pos.x = motion.event_x;
                state.pointer_event_pos.y = motion.event_y;
                try render(&sink, ids.window(), ids.bg(), ids.fg(), font_dims, state);
            },
            .Expose => {
                const expose = try source.read2(.Expose);
                std.log.info("X11 {}", .{expose});
                try render(&sink, ids.window(), ids.bg(), ids.fg(), font_dims, state);
            },
            .GenericEvent => {
                const event = try source.read2(.GenericEvent);
                const extension: x11.Extension = switch (state.xinput) {
                    .initial,
                    .sent_extension_query,
                    .extension_missing,
                    => std.debug.panic("unexpected X11 event {}", .{event}),
                    .get_version => |v| v.extension,
                    .enabled => |e| e,
                };
                if (extension.opcode_base != event.ext_opcode_base) std.debug.panic(
                    "expected opcode {} but got {}",
                    .{ extension.opcode_base, event.ext_opcode_base },
                );
                const code: x11.NonExhaustive(x11.inputext.ExtEventCode) = @enumFromInt(@as(u8, @truncate(event.type)));
                try source.discardRemaining();
                switch (code) {
                    .raw_button_press => {
                        std.log.info("Generic Event: {} (RawButtonPress)", .{event});
                    },
                    else => std.debug.panic("unexpected X11 extension event {}", .{event}),
                }
            },
            else => std.debug.panic("unexpected X11 {f}", .{source.readFmt()}),
        }
    }
}

fn handleReply(
    reply: x11.servermsg.Reply,
    source: *x11.Source,
    sink: *x11.RequestSink,
    state: *State,
    root_window_id: x11.Window,
    window_id: x11.Window,
    bg_gc_id: x11.GraphicsContext,
    fg_gc_id: x11.GraphicsContext,
    font_dims: FontDims,
) !bool {
    const remaining_size = reply.remainingSize();
    switch (state.grab) {
        .disabled => {},
        .requested => |requested_grab| if (requested_grab.sequence == reply.sequence) {
            _ = try source.read3Full(.GrabPointer);
            const result = x11.GrabResult.fromFlexible(reply.flexible);
            const result_name = std.enums.tagName(x11.NonExhaustive(x11.GrabResult), result) orelse std.debug.panic(
                "invalid grab result {}",
                .{reply.flexible},
            );
            std.log.info("grab result '{s}'", .{result_name});
            if (result == .success) {
                state.grab = .{ .enabled = .{ .confined = requested_grab.confined } };
            } else {
                state.grab = .disabled;
            }
            try render(sink, window_id, bg_gc_id, fg_gc_id, font_dims, state.*);
            return true; // handled
        },
        .enabled => {},
    }

    switch (state.xinput) {
        .initial, .extension_missing, .enabled => {},
        .sent_extension_query => |query| if (reply.sequence == query.sequence) {
            if (remaining_size != @sizeOf(x11.stage3.QueryExtension)) std.debug.panic(
                "expected size {} but got {}",
                .{ @sizeOf(x11.stage3.QueryExtension), remaining_size },
            );
            const maybe_ext: ?x11.Extension = try .init(try source.read3Full(.QueryExtension));
            std.log.info("extension '{s}': {?}", .{ x11.inputext.name.nativeSlice(), maybe_ext });
            if (maybe_ext) |ext| {
                try x11.inputext.request.GetExtensionVersion(sink, ext.opcode_base, x11.inputext.name);
                state.xinput = .{ .get_version = .{
                    .sequence = sink.sequence,
                    .extension = ext,
                } };
            } else {
                state.xinput = .extension_missing;
            }
            return true; // handled
        },
        .get_version => |info| if (reply.sequence == info.sequence) {
            if (reply.flexible != @intFromEnum(x11.inputext.ExtOpcode.get_extension_version)) std.debug.panic(
                "expected reply opcode(flexible) {} but got {}",
                .{ @intFromEnum(x11.inputext.ExtOpcode.get_extension_version), reply },
            );
            if (remaining_size != @sizeOf(x11.inputext.stage3.GetExtensionVersion)) std.debug.panic(
                "expected size {} but got {}",
                .{ @sizeOf(x11.stage3.QueryExtension), remaining_size },
            );
            const version = try x11.inputext.read3Full(source, .GetExtensionVersion);
            if (version.present != .yes) std.debug.panic("XInputExtension present={} after it was already present?", .{@intFromEnum(version.present)});
            if (version.major != 2) std.debug.panic("expected XInputExtension major version {} but got {}", .{ 2, version.major });
            if (version.minor < 3) std.debug.panic("XInputExtension minor version is {} but require at least 3", .{version.minor});
            state.xinput = .{ .enabled = info.extension };

            // Now that we see that the input extension is available and compatible, let's
            // resume any operations that someone requested while we were waiting for the
            // extension to be available.
            if (state.disable_input_device == .extension_not_available_yet) {
                try disableInputDevice(sink, state);
            }
            if (state.listen_to_raw_events == .extension_not_available_yet) {
                try listenToRawEvents(sink, state, root_window_id);
            }

            return true; // handled
        },
    }

    std.debug.panic("todo: handle {}", .{reply});
    // switch (state.disable_input_device) {
    //     .initial, .no_pointer_to_disable, .extension_not_available_yet, .extension_missing, .disabled => {},
    //     .list_devices => |state_info| if (msg.sequence == state_info.sequence) {
    //         const devices_reply: *const x11.inputext.ListInputDevicesReply = @ptrCast(msg);
    //         var input_info_it = devices_reply.inputInfoIterator();
    //         var names_it = devices_reply.findNames();
    //         var selected_pointer_id: ?u8 = null;
    //         for (devices_reply.deviceInfos().nativeSlice()) |*device| {
    //             const name = (try names_it.next()) orelse @panic("malformed reply");
    //             if (device.use == .extension_pointer) {
    //                 if (selected_pointer_id) |id| {
    //                     std.log.warn("multiple pointer ids, dropping {}", .{id});
    //                 }
    //                 selected_pointer_id = device.id;
    //             }
    //             std.log.info("Device {} '{f}', type={}, use={s}:", .{ device.id, name, device.device_type, @tagName(device.use) });
    //             var info_index: u8 = 0;
    //             while (info_index < device.class_count) : (info_index += 1) {
    //                 std.log.info("  Input: {f}", .{input_info_it.front()});
    //                 input_info_it.pop();
    //             }
    //         }
    //         std.debug.assert((try names_it.next()) == null);

    //         if (selected_pointer_id) |pointer_id| {
    //             const name = comptime x11.Slice(u16, [*]const u8).initComptime("Device Enabled");
    //             try sink.InternAtom(.{
    //                 .only_if_exists = false,
    //                 .name = name,
    //             });
    //             state.disable_input_device = .{ .intern_atom = .{
    //                 .sequence = sink.sequence,
    //                 .ext_opcode = state_info.ext_opcode,
    //                 .pointer_id = pointer_id,
    //             } };
    //         } else {
    //             state.disable_input_device = .no_pointer_to_disable;
    //         }
    //         return true; // handled
    //     },
    //     .intern_atom => |info| if (msg.sequence == info.sequence) {
    //         const atom = x11.readIntNative(u32, msg.reserve_min[0..]);
    //         try x11.inputext.GetProperty(sink, info.ext_opcode, .{
    //             .device_id = info.pointer_id,
    //             .property = atom,
    //             .type = 0,
    //             .offset = 0,
    //             .len = 0,
    //             .delete = false,
    //         });
    //         state.disable_input_device = .{ .get_prop = .{
    //             .sequence = sink.sequence,
    //             .ext_opcode = info.ext_opcode,
    //             .pointer_id = info.pointer_id,
    //             .atom = atom,
    //         } };
    //         return true;
    //     },
    //     .get_prop => |info| if (msg.sequence == info.sequence) {
    //         const reply: *const x11.inputext.get_property.Reply = @ptrCast(msg);
    //         std.log.info("get_property returned {}", .{reply});

    //         try x11.inputext.ChangeProperty(sink, info.ext_opcode, u8, .{
    //             .device_id = info.pointer_id,
    //             .mode = .replace,
    //             .property = info.atom,
    //             .type = @intFromEnum(x11.Atom.INTEGER),
    //             .values = x11.Slice(u16, [*]const u8).initComptime(&[_]u8{0}),
    //         });
    //         state.disable_input_device = .{ .disabled = .{
    //             .ext_opcode = info.ext_opcode,
    //             .pointer_id = info.pointer_id,
    //             .atom = info.atom,
    //         } };
    //         return true;
    //     },
    // }

    // return false; // not handled
}

fn warpPointer(sink: *x11.RequestSink) !void {
    std.log.info("warping pointer 20 x 10...", .{});
    try sink.WarpPointer(.{
        .src_window = .none,
        .dst_window = .none,
        .src_x = 0,
        .src_y = 0,
        .src_width = 0,
        .src_height = 0,
        .dst_x = 20,
        .dst_y = 10,
    });
}

fn createWindow(sink: *x11.RequestSink, parent_window_id: x11.Window, window_id: x11.Window) !void {
    try sink.CreateWindow(.{
        .window_id = window_id,
        .parent_window_id = parent_window_id,
        .depth = 0, // dont care, inherit from parent
        .x = 0,
        .y = 0,
        .width = 500,
        .height = 500,
        .border_width = 0, // TODO: what is this?
        .class = .input_output,
        //.class = .input_only,
        .visual_id = .copy_from_parent,
    }, .{
        // .bg_pixmap = .copy_from_parent,
        // .bg_pixel = bg_color,
        // //.border_pixmap =
        // .border_pixel = 0x01fa8ec9,
        // .bit_gravity = .north_west,
        // .win_gravity = .east,
        // .backing_store = .when_mapped,
        // .backing_planes = 0x1234,
        // .backing_pixel = 0xbbeeeeff,
        // .override_redirect = true,
        // .save_under = true,
        // .event_mask =
        //     x11.event.key_press
        //     | x11.event.key_release
        //     | x11.event.button_press
        //     | x11.event.button_release
        //     | x11.event.enter_window
        //     | x11.event.leave_window
        //     | x11.event.pointer_motion
        //     | x11.event.pointer_motion_hint WHAT THIS DO?
        //     | x11.event.button1_motion  WHAT THIS DO?
        //     | x11.event.button2_motion  WHAT THIS DO?
        //     | x11.event.button3_motion  WHAT THIS DO?
        //     | x11.event.button4_motion  WHAT THIS DO?
        //     | x11.event.button5_motion  WHAT THIS DO?
        //     | x11.event.button_motion  WHAT THIS DO?
        //     | x11.event.keymap_state
        //     | x11.event.exposure
        //     ,
        // .dont_propagate = 1,
    });
    try sink.MapWindow(window_id);
}

fn listenToRawEvents(sink: *x11.RequestSink, state: *State, root_window_id: x11.Window) !void {
    const extension_missing_fmt = "unable to listen to raw events, XInputExtension is missing";
    switch (state.listen_to_raw_events) {
        .initial, .extension_not_available_yet => {
            if (state.xinput == .extension_missing) {
                std.log.info(extension_missing_fmt, .{});
                state.listen_to_raw_events = .extension_missing;
                return;
            } else if (state.xinput != .enabled) {
                std.log.info("unable to listen to raw events at this moment, waiting for the XInputExtension before continuing.", .{});
                state.listen_to_raw_events = .extension_not_available_yet;
                return;
            }

            // Listen to all mouse clicks regardless of where they occurred
            std.log.info("Setting up raw mouse click listener...", .{});
            var event_masks = [_]x11.inputext.EventMask{.{
                .device_id = .all_master,
                .mask = x11.inputext.event.raw_button_press,
            }};

            const opcode_base = state.xinput.enabled.opcode_base;
            try x11.inputext.SelectEvents(sink, opcode_base, root_window_id, event_masks[0..]);

            state.listen_to_raw_events = .enabled;
        },
        .extension_missing => std.log.info(extension_missing_fmt, .{}),
        .enabled => std.log.info("listening to raw events already", .{}),
    }
}

fn disableInputDevice(sink: *x11.RequestSink, state: *State) !void {
    const already_fmt = "disable input device already requested, {s}...";
    const extension_missing_fmt = "can't disable input device, XInputExtension is missing";
    switch (state.disable_input_device) {
        // Transition from initial or someone who previously failed to disable the
        // pointer because they had no pointer at the time.
        .initial, .no_pointer_to_disable, .extension_not_available_yet => {
            if (state.xinput == .extension_missing) {
                std.log.info(extension_missing_fmt, .{});
                state.disable_input_device = .extension_missing;
                return;
            } else if (state.xinput != .enabled) {
                std.log.info("can't disable input device at this moment, waiting for the XInputExtension before continuing.", .{});
                state.disable_input_device = .extension_not_available_yet;
                return;
            }

            const opcode_base = state.xinput.enabled.opcode_base;
            try x11.inputext.ListInputDevices(sink, opcode_base);
            state.disable_input_device = .{ .list_devices = .{
                .sequence = sink.sequence,
                .ext_opcode = opcode_base,
            } };
        },
        .extension_missing => std.log.info(extension_missing_fmt, .{}),
        .list_devices => std.log.info(already_fmt, .{"getting input devices"}),
        .intern_atom => std.log.info(already_fmt, .{"interning atom"}),
        .get_prop => std.log.info(already_fmt, .{"getting property"}),
        .disabled => |info| {
            std.log.info("TODO: re-enabled input device {}", .{info.pointer_id});
        },
    }
}

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

fn Pos(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}
const State = struct {
    pointer_root_pos: Pos(i16) = .{ .x = -1, .y = -1 },
    pointer_event_pos: Pos(i16) = .{ .x = -1, .y = -1 },
    grab: union(enum) {
        disabled: void,
        requested: struct { confined: bool, sequence: u16 },
        enabled: struct { confined: bool },
    } = .disabled,
    confine_grab: bool = false,

    xinput: union(enum) {
        initial: void,
        sent_extension_query: struct {
            sequence: u16,
        },
        extension_missing: void,
        get_version: struct {
            sequence: u16,
            extension: x11.Extension,
        },
        enabled: x11.Extension,
    } = .initial,

    listen_to_raw_events: union(enum) {
        initial: void,
        extension_not_available_yet: void,
        extension_missing: void,
        enabled: void,
    } = .initial,

    disable_input_device: union(enum) {
        initial: void,
        extension_not_available_yet: void,
        extension_missing: void,
        list_devices: struct {
            sequence: u16,
            ext_opcode: u8,
        },
        no_pointer_to_disable: void,
        intern_atom: struct {
            sequence: u16,
            ext_opcode: u8,
            pointer_id: u8,
        },
        get_prop: struct {
            sequence: u16,
            ext_opcode: u8,
            pointer_id: u8,
            atom: u32,
        },
        disabled: struct {
            ext_opcode: u8,
            pointer_id: u8,
            atom: u32,
        },
    } = .initial,
    window_created: bool = false,

    fn toggleGrab(self: *State, sink: *x11.RequestSink, grab_window: x11.Window) !void {
        switch (self.grab) {
            .disabled => {
                std.log.info("requesting grab...", .{});
                try sink.GrabPointer(.{
                    //.owner_events = true,
                    .owner_events = false,
                    .grab_window = grab_window,
                    .event_mask = .{ .pointer_motion = 1 },
                    .pointer_mode = .synchronous,
                    .keyboard_mode = .asynchronous,
                    .confine_to = if (self.confine_grab) grab_window else .none,
                    .cursor = .none,
                    .time = .current_time,
                });
                self.grab = .{ .requested = .{
                    .confined = self.confine_grab,
                    .sequence = sink.sequence,
                } };
            },
            .requested => {
                std.log.info("grab already requested", .{});
            },
            .enabled => {
                std.log.info("ungrabbing", .{});
                try sink.UngrabPointer(.current_time);
                self.grab = .disabled;
            },
        }
    }
};

fn renderString(
    sink: *x11.RequestSink,
    drawable: x11.Drawable,
    gc: x11.GraphicsContext,
    pos: x11.XY(i16),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    sink.printImageText8(drawable, gc, pos, fmt, args) catch |err| switch (err) {
        error.TextTooLong => @panic("todo: handle render long text"),
        error.WriteFailed => return error.WriteFailed,
    };
}

fn render(
    sink: *x11.RequestSink,
    window_id: x11.Window,
    bg_gc_id: x11.GraphicsContext,
    fg_gc_id: x11.GraphicsContext,
    font_dims: FontDims,
    state: State,
) !void {
    _ = bg_gc_id;
    try sink.ClearArea(
        window_id,
        .{
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
        },
        .{ .exposures = false },
    );
    try renderString(
        sink,
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = font_dims.font_left,
            .y = font_dims.font_ascent + (0 * font_dims.height),
        },
        "root: {} x {}",
        .{
            state.pointer_root_pos.x,
            state.pointer_root_pos.y,
        },
    );
    try renderString(
        sink,
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = font_dims.font_left,
            .y = font_dims.font_ascent + (1 * font_dims.height),
        },
        "event: {} x {}",
        .{
            state.pointer_event_pos.x,
            state.pointer_event_pos.y,
        },
    );
    const grab_suffix: []const u8 = switch (state.grab) {
        .disabled => "",
        .requested => |c| if (c.confined) " confined=true" else " confined=false",
        .enabled => |c| if (c.confined) " confined=true" else " confined=false",
    };
    try renderString(
        sink,
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = font_dims.font_left,
            .y = font_dims.font_ascent + (2 * font_dims.height),
        },
        "(G)rab: {s}{s}",
        .{ @tagName(state.grab), grab_suffix },
    );
    try renderString(
        sink,
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = font_dims.font_left,
            .y = font_dims.font_ascent + (3 * font_dims.height),
        },
        "(C)onfine Grab: {}",
        .{state.confine_grab},
    );
    try renderString(
        sink,
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = font_dims.font_left,
            .y = font_dims.font_ascent + (4 * font_dims.height),
        },
        "(W)arp",
        .{},
    );
    try renderString(
        sink,
        window_id.drawable(),
        fg_gc_id,
        .{
            .x = font_dims.font_left,
            .y = font_dims.font_ascent + (5 * font_dims.height),
        },
        "{s} W(i)ndow",
        .{if (state.window_created) "Destroy" else "Create"},
    );
    {
        const suffix: []const u8 = switch (state.disable_input_device) {
            .initial => "",
            .extension_not_available_yet => " (waiting for XInputExtension...)",
            .extension_missing => " (XInputExtension is missing)",
            .list_devices => " (listing input devices...)",
            .no_pointer_to_disable => " (failed: no pointer to disable)",
            .intern_atom => " (interning atom...)",
            .get_prop => " (getting current property value...)",
            .disabled => " (disabled)",
        };
        try renderString(
            sink,
            window_id.drawable(),
            fg_gc_id,
            .{
                .x = font_dims.font_left,
                .y = font_dims.font_ascent + (6 * font_dims.height),
            },
            "(D)isable Input Device{s}",
            .{suffix},
        );
    }
    {
        const suffix: []const u8 = switch (state.listen_to_raw_events) {
            .initial => "",
            .extension_not_available_yet => " (waiting for XInputExtension...)",
            .extension_missing => " (XInputExtension is missing)",
            .enabled => " (enabled)",
        };
        try renderString(
            sink,
            window_id.drawable(),
            fg_gc_id,
            .{
                .x = font_dims.font_left,
                .y = font_dims.font_ascent + (7 * font_dims.height),
            },
            "(L)isten to raw events{s}",
            .{suffix},
        );
    }
}
