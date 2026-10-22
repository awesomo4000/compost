const std = @import("std");
const core = @import("compositor");
const terminal = @import("terminal");
const input = @import("input.zig");
const decoration = @import("frame.zig");
const Renderer = @import("renderer.zig").Renderer;
pub const std_options: std.Options = .{ .log_level = .warn };
const host = @import("host.zig");
const Slot = struct { index: c_int, id: core.Id = 0, surface: ?*terminal.Surface = null, renderer: Renderer, drawn_revision: ?u64 = null };
var slots = [_]Slot{
    .{ .index = 0, .renderer = .{ .next_image = 1, .image_stride = 3, .framed = false, .bordered = true } },
    .{ .index = 1, .renderer = .{ .next_image = 2, .image_stride = 3, .framed = false, .bordered = true } },
    .{ .index = 2, .renderer = .{ .next_image = 3, .image_stride = 3, .framed = false, .bordered = true } },
};
const Drag = struct { id: core.Id, x: i32, y: i32, bounds: core.Rect, edge: decoration.Edge };
var drag: ?Drag = null;
var border_capture = false;
var hover_id: ?core.Id = null;
var hover_edge: ?decoration.Edge = null;
var borders_dirty = true;
var dock_extent: ?i32 = null;
var border_output: ?std.Io.Writer.Allocating = null;
var float_return_focus: ?core.Id = null;
var count: usize = 0;
var scene: core.Scene = undefined;
var io: std.Io = undefined;
var failure: ?anyerror = null;
var decoder: input.Decoder = .{};
var input_context: u8 = 0;
var pixel_width: u16 = 0;
var pixel_height: u16 = 0;
var layout_dirty = true;
var drawn_scene: ?u64 = null;
var modes_initialized = false;
var cursor_keys: ?bool = null;
const allocator = std.heap.smp_allocator;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    defer if (border_output) |*output| output.deinit();
    defer for (&slots) |*slot| {
        if (slot.surface) |s| s.destroy();
        slot.renderer.deinit(allocator);
    };
    const status = host.run();
    if (failure) |err| return err;
    if (status != 0) std.process.exit(@intCast(@min(status, 255)));
}
fn display(bytes: []const u8) !void {
    if (host.display(bytes) != 0) return error.DisplayWriteFailed;
}
fn write(ctx: *anyopaque, bytes: []const u8) !void {
    const slot: *Slot = @ptrCast(@alignCast(ctx));
    if (host.write(slot.index, bytes) != 0) return error.ChildWriteFailed;
}
fn focused() ?*Slot {
    for (&slots) |*slot| if (slot.surface != null and scene.focus == slot.id) return slot;
    return null;
}
fn focus(id: core.Id) !void {
    if (scene.focus == id) return;
    if (slots[2].surface != null and id == slots[2].id) float_return_focus = scene.focus;
    if (focused()) |slot| if (slot.surface.?.terminal.modes.get(.focus_event)) try write(slot, "\x1b[O");
    try scene.setFocus(id);
    if (focused()) |slot| if (slot.surface.?.terminal.modes.get(.focus_event)) try write(slot, "\x1b[I");
}
fn applyLayout() !void {
    layout_dirty = true;
    for (&slots) |*slot| {
        const s = slot.surface orelse continue;
        const bounds = decoration.contentFor(&scene, slot.id);
        if (bounds.empty()) continue;
        const changed = try s.resize(.{ .columns = @intCast(bounds.w), .rows = @intCast(bounds.h), .cell_width = pixel_width, .cell_height = pixel_height });
        if (changed and host.setSize(slot.index, s.size.columns, s.size.rows, pixel_width, pixel_height) != 0) return error.ChildResizeFailed;
    }
    if (focused() == null) for (&slots) |*slot| {
        if (slot.surface != null and scene.get(slot.id).?.visible and !scene.get(slot.id).?.bounds.empty()) {
            try focus(slot.id);
            break;
        }
    };
}
fn resize(cols: u16, rows: u16, cw: u16, ch: u16, requested_count: c_int) !void {
    pixel_width = if (ch == 0) 0 else cw;
    pixel_height = if (cw == 0) 0 else ch;
    const root = try core.Rect.init(0, 0, cols, rows);
    const extent = if (dock_extent) |width| @min(width, @max(0, @as(i32, cols) - 3)) else @min(24, cols / 3);
    if (count == 0) {
        count = @intCast(requested_count);
        scene = try core.Scene.init(root);
        for (slots[0..count], 0..) |*slot, i| {
            slot.id = try scene.add(if (i == 0 and count >= 2)
                .{ .kind = .{ .docked = .{ .edge = .left, .extent = extent } }, .always_on_top = true }
            else if (i == 2)
                .{ .kind = .{ .floating = try core.Rect.init(scene.usable.x + @divTrunc(scene.usable.w, 4), @divTrunc(root.h, 4), @max(1, @divTrunc(scene.usable.w, 2)), @max(1, @divTrunc(root.h, 2))) } }
            else
                .{ .kind = .tiled });
            const bounds = decoration.contentFor(&scene, slot.id);
            slot.surface = try terminal.Surface.create(io, allocator, .{
                .columns = @intCast(@max(1, bounds.w)),
                .rows = @intCast(@max(1, bounds.h)),
                .cell_width = pixel_width,
                .cell_height = pixel_height,
            }, .{ .context = slot, .write = write });
            if (host.setSize(slot.index, slot.surface.?.size.columns, slot.surface.?.size.rows, pixel_width, pixel_height) != 0) return error.ChildResizeFailed;
        }
        try scene.setFocus(slots[if (count == 1) 0 else 1].id);
    } else {
        drag = null;
        border_capture = false;
        scene.releasePointer();
        try scene.resizeRoot(root);
        if (count >= 2 and slots[0].surface != null and slots[1].surface != null)
            try scene.configure(slots[0].id, .{ .kind = .{ .docked = .{ .edge = .left, .extent = extent } }, .always_on_top = true });
        try applyLayout();
    }
}
pub fn compositor_resize(cols: u16, rows: u16, cw: u16, ch: u16, n: c_int) c_int {
    resize(cols, rows, cw, ch, n) catch |err| {
        failure = err;
        return -1;
    };
    return 0;
}
pub fn compositor_output(index: c_int, bytes: []const u8) c_int {
    slots[@intCast(index)].surface.?.feed(bytes) catch |err| {
        failure = err;
        return -1;
    };
    return 0;
}
fn event(_: *anyopaque, value: input.Event) !void {
    switch (value) {
        .toggle_focus => {
            const start: usize = if (focused()) |slot| @intCast(slot.index) else 0;
            for (1..slots.len + 1) |offset| {
                const slot = &slots[(start + offset) % slots.len];
                if (slot.surface != null and scene.get(slot.id).?.visible and !scene.get(slot.id).?.bounds.empty()) {
                    try focus(slot.id);
                    break;
                }
            }
        },
        .toggle_float => {
            const slot = &slots[2];
            if (slot.surface == null or scene.get(slot.id).?.options.kind != .floating) return;
            const show = !scene.get(slot.id).?.visible;
            if (show) float_return_focus = scene.focus else {
                if (float_return_focus) |id| if (scene.get(id)) |w| {
                    if (w.visible and !w.bounds.empty()) try focus(id);
                };
            }
            drag = null;
            scene.releasePointer();
            try scene.setVisible(slot.id, show);
            try applyLayout();
            if (show and !scene.get(slot.id).?.bounds.empty()) try focus(slot.id);
        },
        .bytes => |bytes| if (focused()) |slot| {
            if ((std.mem.eql(u8, bytes, "\x1b[200~") or std.mem.eql(u8, bytes, "\x1b[201~")) and !slot.surface.?.terminal.modes.get(.bracketed_paste)) return;
            try write(slot, bytes);
        },
        .focus => |is_focused| if (focused()) |slot| {
            if (slot.surface.?.terminal.modes.get(.focus_event)) try write(slot, if (is_focused) "\x1b[I" else "\x1b[O");
        },
        .mouse => |mouse| {
            const hit = scene.hitTest(mouse.x, mouse.y);
            const edge = if (hit) |id| decoration.edgeAt(&scene, id, mouse.x, mouse.y) else null;
            if (hover_id != hit or hover_edge != edge) {
                borders_dirty = true;
                hover_id = hit;
                hover_edge = edge;
            }
            if (border_capture) {
                if (mouse.release) border_capture = false;
                return;
            }
            if (drag) |active| {
                if (mouse.release) {
                    drag = null;
                    scene.releasePointer();
                } else if (mouse.button & 32 != 0) {
                    const dx = @as(i32, mouse.x) - active.x;
                    const dy = @as(i32, mouse.y) - active.y;
                    if (active.edge == .divider) {
                        const extent = std.math.clamp(active.bounds.w + dx, @min(3, scene.root.w), @max(3, scene.root.w - 3));
                        dock_extent = extent;
                        try scene.configure(active.id, .{ .kind = .{ .docked = .{ .edge = .left, .extent = extent } }, .always_on_top = true });
                    } else {
                        const requested = decoration.adjust(active.bounds, active.edge, dx, dy, scene.usable);
                        try scene.moveResize(active.id, requested);
                    }
                    try applyLayout();
                }
                return;
            }
            const target = scene.pointerTarget(mouse.x, mouse.y) orelse return;
            const press = !mouse.release and mouse.button & 96 == 0 and mouse.button & 3 != 3;
            if (press) {
                const border_edge = decoration.edgeAt(&scene, target, mouse.x, mouse.y);
                if (border_edge != .divider) try focus(target);
                const window = scene.get(target).?;
                const inner = decoration.contentFor(&scene, target);
                const on_border = !inner.contains(mouse.x, mouse.y);
                const modified = mouse.button & 8 != 0 and mouse.button & 4 == 0 and (mouse.button & 3 == 0 or mouse.button & 3 == 2);
                if ((border_edge != null and mouse.button & 3 == 0) or
                    (window.options.kind == .floating and !on_border and modified))
                {
                    const action = border_edge orelse (if (mouse.button & 3 == 2 or mouse.button & 16 != 0) decoration.Edge.bottom_right else decoration.Edge.move);
                    drag = .{ .id = target, .x = mouse.x, .y = mouse.y, .bounds = window.bounds, .edge = action };
                    try scene.capturePointer(target);
                    return;
                }
                if (on_border) {
                    border_capture = true;
                    return;
                }
                try scene.capturePointer(target);
            }
            defer if (mouse.release) scene.releasePointer();
            for (&slots) |*slot| {
                if (slot.surface == null or slot.id != target) continue;
                const s = slot.surface.?;
                const normal = s.terminal.modes.get(.mouse_event_normal);
                const button = s.terminal.modes.get(.mouse_event_button);
                const any = s.terminal.modes.get(.mouse_event_any);
                if (!normal and !button and !any) return;
                if (mouse.button & 32 != 0 and !any and !(button and scene.capture != null)) return;
                const bounds = decoration.contentFor(&scene, target);
                if (bounds.empty()) return;
                if (scene.capture == null and !bounds.contains(mouse.x, mouse.y)) return;
                const x = std.math.clamp(@as(i32, mouse.x) - bounds.x, 0, bounds.w - 1) + 1;
                const y = std.math.clamp(@as(i32, mouse.y) - bounds.y, 0, bounds.h - 1) + 1;
                if (s.terminal.modes.get(.mouse_format_sgr)) {
                    var buf: [80]u8 = undefined;
                    try write(slot, try std.mem.print(&buf, "\x1b[<{d};{d};{d}{s}", .{ mouse.button, x, y, if (mouse.release) "m" else "M" }));
                } else if (x <= 223 and y <= 223 and mouse.button <= 223) {
                    const code = if (mouse.release) (mouse.button & 28) | 3 else mouse.button;
                    const bytes = [_]u8{ 27, '[', 'M', @intCast(code + 32), @intCast(x + 32), @intCast(y + 32) };
                    try write(slot, &bytes);
                }
            }
        },
    }
}
const sink: input.Sink = .{ .context = &input_context, .emit = event };
pub fn compositor_input(bytes: []const u8) c_int {
    decoder.feed(bytes, sink) catch |err| {
        failure = err;
        return -1;
    };
    return 0;
}
pub fn compositor_idle() c_int {
    decoder.flush(sink) catch |err| {
        failure = err;
        return -1;
    };
    return 0;
}
fn draw() !void {
    var changed = borders_dirty or layout_dirty or drawn_scene != scene.revision;
    for (&slots) |*slot| if (slot.surface) |s| {
        changed = changed or slot.drawn_revision != s.revision;
    };
    if (!changed) return;
    try display("\x1b[?2026h\x1b[?25l\x1b[?7l\x1b[0m");
    if (layout_dirty) try display("\x1b[2J");
    for (&slots) |*slot| if (slot.surface) |s| {
        if (layout_dirty) slot.renderer.invalidate(allocator);
        if (!layout_dirty and slot.drawn_revision == s.revision) continue;
        const frame = try slot.renderer.draw(allocator, &scene, slot.id, s);
        try display(frame);
        slot.drawn_revision = s.revision;
    };
    if (borders_dirty or layout_dirty or drawn_scene != scene.revision) {
        if (border_output == null) border_output = .init(allocator);
        const output = &border_output.?;
        output.clearRetainingCapacity();
        for (&slots) |*slot| if (slot.surface != null) try decoration.draw(&output.writer, &scene, slot.id, if (hover_id == slot.id) hover_edge else null);
        try display(output.written());
    }
    // Capture clicks and drags even when the focused shell has not requested mouse input.
    // Paste markers are always requested so compositor shortcuts never interpret pasted data.
    if (!modes_initialized) {
        try display("\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h");
        modes_initialized = true;
    }
    if (focused()) |slot| {
        const application_keys = slot.surface.?.terminal.modes.get(.cursor_keys);
        if (cursor_keys != application_keys) {
            try display(if (application_keys) "\x1b[?1h" else "\x1b[?1l");
            cursor_keys = application_keys;
        }
        const cursor = slot.renderer.state.cursor;
        if (cursor.visible) if (cursor.viewport) |p| {
            const bounds = decoration.contentFor(&scene, slot.id);
            var buf: [80]u8 = undefined;
            const x = bounds.x + @as(i32, p.x);
            const y = bounds.y + @as(i32, @intCast(p.y));
            if (scene.hitTest(x, y) == slot.id)
                try display(try std.mem.print(&buf, "\x1b[{d};{d}H\x1b[?25h", .{ y + 1, x + 1 }));
        };
    }
    try display("\x1b[?2026l");
    layout_dirty = false;
    borders_dirty = false;
    drawn_scene = scene.revision;
}
pub fn compositor_draw() c_int {
    draw() catch |err| {
        failure = err;
        return -1;
    };
    return 0;
}
fn clearImages(slot: *Slot) void {
    var ids = slot.renderer.images.valueIterator();
    while (ids.next()) |id| {
        var buf: [96]u8 = undefined;
        const bytes = std.mem.print(&buf, "\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{id.*}) catch continue;
        display(bytes) catch {};
    }
}
pub fn compositor_exit(index: c_int) c_int {
    const slot = &slots[@intCast(index)];
    clearImages(slot);
    slot.surface.?.destroy();
    slot.surface = null;
    scene.remove(slot.id) catch |err| {
        failure = err;
        return -1;
    };
    drag = null;
    scene.releasePointer();
    // Keep the float floating while a base shell remains. Promote the last
    // shell to a visible full-root tile so a hidden child cannot strand exit.
    for (&slots) |*other| if (other.surface != null) {
        const promote = if (other.index == 2)
            slots[0].surface == null and slots[1].surface == null
        else
            slots[if (other.index == 0) 1 else 0].surface == null;
        if (promote) {
            scene.configure(other.id, .{ .kind = .tiled }) catch |err| {
                failure = err;
                return -1;
            };
            scene.setVisible(other.id, true) catch |err| {
                failure = err;
                return -1;
            };
        }
    };
    applyLayout() catch |err| {
        failure = err;
        return -1;
    };
    return 0;
}
pub fn compositor_finish() void {
    for (&slots) |*slot| clearImages(slot);
}
