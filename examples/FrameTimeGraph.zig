const FrameTimeGraph = @This();

const history_len = 150;
const grid_color = 0x333333;
const bar_color = 0x666666;
const highlight_color = 0xcccccc;
const over_color = 0xcc3333;

font_dims: FontDims,
previous_time: ?std.time.Instant = null,
frame_times: [history_len]f32 = [1]f32{0} ** history_len,
cursor: u8 = 0,
max_ms: f32 = 50,

pub const FontDims = struct {
    width: u8,
    font_ascent: i16,
    font_descent: u8,
};

pub fn writeRender(
    self: *FrameTimeGraph,
    sink: *x11.RequestSink,
    drawable: x11.Drawable,
    gc_id: x11.GraphicsContext,
    window_width: u16,
    window_height: u16,
) error{ WriteFailed, TextTooLong }!void {
    const now = std.time.Instant.now() catch @panic("time not supported");
    const elapsed_ms: f32 = if (self.previous_time) |prev|
        @as(f32, @floatFromInt(now.since(prev))) / std.time.ns_per_ms
    else
        0;
    self.previous_time = now;

    self.frame_times[self.cursor] = elapsed_ms;

    const char_w: i16 = self.font_dims.width;
    const font_height: i16 = self.font_dims.font_ascent + self.font_dims.font_descent;
    const margin: i16 = char_w * 2;

    // Y-axis label area on the left (e.g. "00.00ms")
    const y_label_width: i16 = char_w * 7;

    const title_height: i16 = font_height + margin;
    const graph_left: i16 = margin + y_label_width + margin;
    const graph_right: i16 = @as(i16, @intCast(window_width)) - margin;
    const graph_top: i16 = margin + title_height + @divTrunc(font_height, 2);
    const graph_bottom: i16 = @as(i16, @intCast(window_height)) - margin - @divTrunc(font_height, 2);
    const graph_height: i16 = graph_bottom - graph_top;
    const graph_width: i16 = graph_right - graph_left;

    if (graph_height < 1 or graph_width < 1) return;

    // Title
    try sink.ChangeGc(gc_id, .{ .foreground = highlight_color });
    try sink.printImageText8(drawable, gc_id, .{
        .x = margin,
        .y = margin + self.font_dims.font_ascent,
    }, "Frame Time History    +/- to zoom", .{});

    // Draw bars first (gridlines go on top)
    const graph_width_f: f32 = @floatFromInt(graph_right - graph_left);
    const bar_stride: f32 = graph_width_f / @as(f32, history_len);

    try sink.ChangeGc(gc_id, .{ .foreground = bar_color });

    for (0..history_len) |i| {
        const ft = self.frame_times[i];
        const over = ft > self.max_ms;
        const bar_height_f: f32 = @min(ft / self.max_ms, 1.0) * @as(f32, @floatFromInt(graph_height));
        const bar_height: u16 = @intFromFloat(@max(1, bar_height_f));
        const x: i16 = graph_left + @as(i16, @intFromFloat(@as(f32, @floatFromInt(i)) * bar_stride));
        const x_next: i16 = graph_left + @as(i16, @intFromFloat(@as(f32, @floatFromInt(i + 1)) * bar_stride));
        const y = graph_bottom - @as(i16, @intCast(bar_height));
        const w: u16 = @max(1, @as(u16, @intCast(@max(0, x_next - x))));

        const color: u32 = if (over) over_color else if (i == self.cursor) highlight_color else bar_color;
        try sink.ChangeGc(gc_id, .{ .foreground = color });

        try sink.PolyFillRectangle(drawable, gc_id, .initAssume(&.{.{
            .x = x,
            .y = y,
            .width = w,
            .height = bar_height,
        }}));

        // Label clipped bars with their frame time
        if (over) {
            try sink.ChangeGc(gc_id, .{ .foreground = highlight_color });
            try sink.printImageText8(drawable, gc_id, .{
                .x = x,
                .y = graph_top - 2,
            }, "{d:.0}", .{ft});
        }
    }

    // Reset foreground for gridlines
    try sink.ChangeGc(gc_id, .{ .foreground = bar_color });

    // Draw horizontal gridlines on top of bars
    // Space lines so labels don't overlap: minimum spacing is font_height
    const num_lines: i16 = @max(1, @divTrunc(graph_height, font_height + 4));
    const ms_per_line: f32 = self.max_ms / @as(f32, @floatFromInt(num_lines));

    var line_idx: i16 = 0;
    while (line_idx <= num_lines) : (line_idx += 1) {
        const ms_value: f32 = ms_per_line * @as(f32, @floatFromInt(line_idx));
        const y_offset: f32 = (ms_value / self.max_ms) * @as(f32, @floatFromInt(graph_height));
        const y: i16 = graph_bottom - @as(i16, @intFromFloat(y_offset));

        // Gridline
        try sink.ChangeGc(gc_id, .{ .foreground = grid_color });
        try sink.PolyFillRectangle(drawable, gc_id, .initAssume(&.{.{
            .x = graph_left,
            .y = y,
            .width = @intCast(graph_width),
            .height = 1,
        }}));

        // Label
        try sink.ChangeGc(gc_id, .{ .foreground = highlight_color });
        try sink.printImageText8(drawable, gc_id, .{
            .x = margin,
            .y = y + @divTrunc(self.font_dims.font_ascent, 2),
        }, "{d:.2}ms", .{ms_value});
    }

    self.cursor = (self.cursor + 1) % history_len;
}

const std = @import("std");
const x11 = @import("x11");
