const std = @import("std");
const core = @import("compositor");
const terminal = @import("terminal");
const input = @import("input.zig");
const Renderer = @import("renderer.zig").Renderer;
pub const std_options: std.Options = .{ .log_level = .warn };
extern "c" fn host_run() c_int;
extern "c" fn host_write(c_int, [*]const u8, usize) c_int;
extern "c" fn host_set_size(c_int, u16, u16, u16, u16) c_int;
extern "c" fn host_display([*]const u8, usize) c_int;
const Slot = struct { index: c_int, id: core.Id = 0, surface: ?*terminal.Surface = null, renderer: Renderer, drawn_revision: ?u64 = null };
var slots = [_]Slot{
    .{ .index = 0, .renderer = .{ .next_image = 1, .image_stride = 2, .framed = false } },
    .{ .index = 1, .renderer = .{ .next_image = 2, .image_stride = 2, .framed = false } },
};
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
    defer for (&slots) |*slot| {
        if (slot.surface) |s| s.destroy();
        slot.renderer.deinit(allocator);
    };
    const status = host_run();
    if (failure) |err| return err;
    if (status != 0) std.process.exit(@intCast(@min(status, 255)));
}
fn display(bytes: []const u8) !void {
    if (host_display(bytes.ptr, bytes.len) != 0) return error.DisplayWriteFailed;
}
fn write(ctx: *anyopaque, bytes: []const u8) !void {
    const slot: *Slot = @ptrCast(@alignCast(ctx));
    if (host_write(slot.index, bytes.ptr, bytes.len) != 0) return error.ChildWriteFailed;
}
fn focused() ?*Slot {
    for (&slots) |*slot| if (slot.surface != null and scene.focus == slot.id) return slot;
    return null;
}
fn focus(id: core.Id) !void {
    if (scene.focus == id) return;
    if (focused()) |slot| if (slot.surface.?.terminal.modes.get(.focus_event)) try write(slot, "\x1b[O");
    try scene.setFocus(id);
    if (focused()) |slot| if (slot.surface.?.terminal.modes.get(.focus_event)) try write(slot, "\x1b[I");
}
fn applyLayout() !void {
    layout_dirty = true;
    for (&slots) |*slot| {
        const s = slot.surface orelse continue;
        const bounds = scene.get(slot.id).?.bounds;
        if (bounds.empty()) continue;
        _ = try s.resize(.{ .columns = @intCast(bounds.w), .rows = @intCast(bounds.h), .cell_width = pixel_width, .cell_height = pixel_height });
        if (host_set_size(slot.index, s.size.columns, s.size.rows, pixel_width, pixel_height) != 0) return error.ChildResizeFailed;
    }
    if (focused() == null) for (&slots) |*slot| {
        if (slot.surface != null and !scene.get(slot.id).?.bounds.empty()) {
            try focus(slot.id);
            break;
        }
    };
}
fn resize(cols: u16, rows: u16, cw: u16, ch: u16, requested_count: c_int) !void {
    pixel_width = if (ch == 0) 0 else cw;
    pixel_height = if (cw == 0) 0 else ch;
    const root = try core.Rect.init(0, 0, cols, rows);
    const extent = @min(24, cols / 3);
    if (count == 0) {
        count = @intCast(requested_count);
        scene = try core.Scene.init(root);
        for (slots[0..count], 0..) |*slot, i| {
            slot.id = try scene.add(if (i == 0 and count == 2)
                .{ .kind = .{ .docked = .{ .edge = .left, .extent = extent } }, .always_on_top = true }
            else
                .{ .kind = .tiled });
            const bounds = scene.get(slot.id).?.bounds;
            slot.surface = try terminal.Surface.create(io, allocator, .{
                .columns = @intCast(@max(1, bounds.w)),
                .rows = rows,
                .cell_width = pixel_width,
                .cell_height = pixel_height,
            }, .{ .context = slot, .write = write });
            if (host_set_size(slot.index, slot.surface.?.size.columns, rows, pixel_width, pixel_height) != 0) return error.ChildResizeFailed;
        }
        try scene.setFocus(slots[count - 1].id);
    } else {
        try scene.resizeRoot(root);
        if (count == 2 and slots[0].surface != null and slots[1].surface != null)
            try scene.configure(slots[0].id, .{ .kind = .{ .docked = .{ .edge = .left, .extent = extent } }, .always_on_top = true });
        try applyLayout();
    }
}
export fn compositor_resize(cols: u16, rows: u16, cw: u16, ch: u16, n: c_int) c_int {
    resize(cols, rows, cw, ch, n) catch |err| {
        failure = err;
        return -1;
    };
    return 0;
}
export fn compositor_output(index: c_int, bytes: [*]const u8, len: usize) c_int {
    slots[@intCast(index)].surface.?.feed(bytes[0..len]) catch |err| {
        failure = err;
        return -1;
    };
    return 0;
}
fn event(_: *anyopaque, value: input.Event) !void {
    switch (value) {
        .toggle_focus => {
            for (&slots) |*slot| if (slot.surface != null and scene.focus != slot.id and !scene.get(slot.id).?.bounds.empty()) {
                try focus(slot.id);
                break;
            };
        },
        .bytes => |bytes| if (focused()) |slot| {
            if ((std.mem.eql(u8, bytes, "\x1b[200~") or std.mem.eql(u8, bytes, "\x1b[201~")) and !slot.surface.?.terminal.modes.get(.bracketed_paste)) return;
            try write(slot, bytes);
        },
        .focus => |is_focused| if (focused()) |slot| {
            if (slot.surface.?.terminal.modes.get(.focus_event)) try write(slot, if (is_focused) "\x1b[I" else "\x1b[O");
        },
        .mouse => |mouse| {
            const target = scene.pointerTarget(mouse.x, mouse.y) orelse return;
            const press = !mouse.release and mouse.button & 96 == 0 and mouse.button & 3 != 3;
            if (press) {
                try focus(target);
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
                const bounds = scene.get(target).?.bounds;
                if (bounds.empty()) return;
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
export fn compositor_input(bytes: [*]const u8, len: usize) c_int {
    decoder.feed(bytes[0..len], sink) catch |err| {
        failure = err;
        return -1;
    };
    return 0;
}
export fn compositor_idle() c_int {
    decoder.flush(sink) catch |err| {
        failure = err;
        return -1;
    };
    return 0;
}
fn draw() !void {
    var changed = layout_dirty or drawn_scene != scene.revision;
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
    // Capture clicks and drags even when the focused shell has not requested mouse input.
    // Paste markers are always requested so compositor shortcuts never interpret pasted data.
    if (!modes_initialized) {
        try display("\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[?2004h");
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
            const bounds = scene.get(slot.id).?.bounds;
            var buf: [80]u8 = undefined;
            try display(try std.mem.print(&buf, "\x1b[{d};{d}H\x1b[?25h", .{ bounds.y + @as(i32, @intCast(p.y)) + 1, bounds.x + @as(i32, p.x) + 1 }));
        };
    }
    try display("\x1b[?2026l");
    layout_dirty = false;
    drawn_scene = scene.revision;
}
export fn compositor_draw() c_int {
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
export fn compositor_exit(index: c_int) c_int {
    const slot = &slots[@intCast(index)];
    clearImages(slot);
    slot.surface.?.destroy();
    slot.surface = null;
    scene.remove(slot.id) catch |err| {
        failure = err;
        return -1;
    };
    for (&slots) |*other| if (other.surface != null) {
        scene.configure(other.id, .{ .kind = .tiled }) catch |err| {
            failure = err;
            return -1;
        };
    };
    applyLayout() catch |err| {
        failure = err;
        return -1;
    };
    return 0;
}
export fn compositor_finish() void {
    for (&slots) |*slot| clearImages(slot);
}
