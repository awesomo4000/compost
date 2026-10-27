const std = @import("std");
const core = @import("compositor");
const terminal = @import("terminal");
const input = @import("input.zig");
const docking = @import("docking.zig");
const decoration = @import("frame.zig");
const Renderer = @import("renderer.zig").Renderer;
pub const std_options: std.Options = .{ .log_level = .warn, .logFn = logDiagnostic };
// Never let dependency diagnostics bypass composition onto the live terminal.
// Fixed storage bounds memory use even when a child repeatedly probes a feature.
var diagnostic_bytes: [16384]u8 = undefined;
var diagnostic_len: usize = 0;
var diagnostic_overflow = false;
var defer_diagnostics = true;
fn logDiagnostic(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (!defer_diagnostics or std.c.isatty(2) == 0) {
        std.log.defaultLog(level, scope, format, args);
        return;
    }
    const line = std.mem.print(diagnostic_bytes[diagnostic_len..], level.asText() ++ "(" ++ @tagName(scope) ++ "): " ++ format ++ "\n", args) catch {
        diagnostic_overflow = true;
        return;
    };
    diagnostic_len += line.len;
}
fn flushDiagnostics() void {
    defer_diagnostics = false;
    var remaining = diagnostic_bytes[0..diagnostic_len];
    while (remaining.len != 0) {
        const n = std.c.write(2, remaining.ptr, remaining.len);
        if (n <= 0) break;
        remaining = remaining[@intCast(n)..];
    }
    if (diagnostic_overflow) std.log.warn("additional terminal diagnostics omitted", .{});
}
const host = @import("host.zig");
const Slot = struct { selecting: bool = false, name: ?[]u8 = null, command: ?[]u8 = null, index: c_int, id: core.Id = 0, surface: ?*terminal.Surface = null, renderer: Renderer, drawn_revision: ?u64 = null, floating_bounds: ?core.Rect = null };
var slots: [host.capacity]Slot = init: {
    var result: [host.capacity]Slot = undefined;
    for (&result, 0..) |*slot, index| slot.* = .{ .index = @intCast(index), .renderer = .{ .next_image = @intCast(index + 1), .image_stride = host.capacity, .framed = false, .bordered = true, .inactive_cursor = true } };
    break :init result;
};
const Drag = struct { id: core.Id, x: i32, y: i32, bounds: core.Rect, edge: decoration.Edge, split: ?usize = null, free_move: bool = false, started: bool = false };
var drag: ?Drag = null;
var selection_drag: ?struct { id: core.Id, x: u16, y: u16, started: bool = false } = null;
var drag_original: ?core.Scene = null;
var drag_dock_extent: ?i32 = null;
var destination: ?docking.Destination = null;
var initialized = false;
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
    if (std.c.getenv("COMPO_BORDER_STYLE")) |value| {
        if (std.mem.eql(u8, std.mem.span(value), "plain")) decoration.style = .plain;
    }
    defer if (border_output) |*output| output.deinit();
    defer for (&slots) |*slot| {
        if (slot.surface) |s| s.destroy();
        if (slot.name) |name| allocator.free(name);
        if (slot.command) |command| allocator.free(command);
        slot.renderer.deinit(allocator);
    };
    const status = host.run();
    flushDiagnostics();
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
    if (selection_drag != null) {
        selection_drag = null;
        scene.releasePointer();
    }
    if (scene.get(id).?.options.kind == .floating) float_return_focus = scene.focus;
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
    if (!initialized) {
        initialized = true;
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
        if (count != 0) try scene.setFocus(slots[if (count == 1) 0 else 1].id);
    } else {
        try cancelDrag();
        border_capture = false;
        selection_drag = null;
        scene.releasePointer();
        try scene.resizeRoot(root);
        if (count >= 2 and slots[0].surface != null and slots[1].surface != null and scene.get(slots[0].id).?.options.kind == .docked)
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
fn restoreDrag() void {
    if (drag_original) |original| {
        scene = original;
        dock_extent = drag_dock_extent;
        for (&slots) |*slot| slot.renderer.region_scene = null;
    }
    drag = null;
    drag_original = null;
    destination = null;
    scene.releasePointer();
}
fn cancelDrag() !void {
    restoreDrag();
    try applyLayout();
}
fn newShell() !void {
    if (drag != null) try cancelDrag();
    var free: ?*Slot = null;
    for (&slots) |*slot| if (slot.surface == null) {
        free = slot;
        break;
    };
    const slot = free orelse return;
    const area = scene.usable;
    if (area.w < 3 or area.h < 3) return;
    const w = @max(3, @divTrunc(area.w * 2, 3));
    const h = @max(3, @divTrunc(area.h * 2, 3));
    slot.id = try scene.add(.{ .kind = .{ .floating = try core.Rect.init(area.x + @divTrunc(area.w - w, 2), area.y + @divTrunc(area.h - h, 2), w, h) } });
    errdefer scene.remove(slot.id) catch {};
    const bounds = decoration.contentFor(&scene, slot.id);
    slot.renderer.invalidate(allocator);
    slot.floating_bounds = null;
    slot.drawn_revision = null;
    slot.surface = try terminal.Surface.create(io, allocator, .{ .columns = @intCast(bounds.w), .rows = @intCast(bounds.h), .cell_width = pixel_width, .cell_height = pixel_height }, .{ .context = slot, .write = write });
    errdefer {
        slot.surface.?.destroy();
        slot.surface = null;
    }
    if (host.setSize(slot.index, @intCast(bounds.w), @intCast(bounds.h), pixel_width, pixel_height) != 0 or !host.spawn(@intCast(slot.index), false)) return error.ChildSpawnFailed;
    try focus(slot.id);
    try applyLayout();
}
fn event(_: *anyopaque, value: input.Event) !void {
    switch (value) {
        .new_shell => try newShell(),
        .select_mode => if (focused()) |slot| {
            selection_drag = null;
            scene.releasePointer();
            slot.selecting = !slot.selecting;
            slot.surface.?.clearSelection();
        },
        .copy_selection => if (focused()) |slot| {
            if (try slot.surface.?.selectionText(allocator)) |text| {
                defer allocator.free(text);
                // Only this explicit user command may write the outer clipboard.
                // Child OSC 52 effects remain disabled in the VT handler.
                if (text.len > 1024 * 1024) {
                    try display("\x07");
                    return;
                }
                const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(text.len));
                defer allocator.free(encoded);
                _ = std.base64.standard.Encoder.encode(encoded, text);
                try display("\x1b]52;c;");
                try display(encoded);
                try display("\x1b\\");
                slot.surface.?.clearSelection();
                slot.selecting = false;
                selection_drag = null;
                scene.releasePointer();
            }
        },
        .quit => host.quit(),
        .toggle_focus => {
            const start: usize = if (focused()) |slot| @intCast(slot.index) else 0;
            for (1..slots.len + 1) |offset| {
                const slot = &slots[(start + offset) % slots.len];
                if (slot.surface != null and scene.get(slot.id).?.visible and !scene.get(slot.id).?.bounds.empty()) {
                    try focus(slot.id);
                    try scene.raise(slot.id);
                    layout_dirty = true;
                    break;
                }
            }
        },
        .toggle_float => {
            var candidate = focused();
            if (candidate == null or scene.get(candidate.?.id).?.options.kind != .floating) {
                candidate = null;
                for (&slots) |*slot| if (slot.surface != null and scene.get(slot.id).?.options.kind == .floating) {
                    candidate = slot;
                    break;
                };
            }
            const slot = candidate orelse return;
            if (drag != null) try cancelDrag();
            const show = !scene.get(slot.id).?.visible;
            if (show) float_return_focus = scene.focus else {
                if (float_return_focus) |id| if (scene.get(id)) |window| {
                    if (window.visible and !window.bounds.empty() and id != slot.id) try focus(id);
                };
            }
            scene.releasePointer();
            try scene.setVisible(slot.id, show);
            try applyLayout();
            if (show and !scene.get(slot.id).?.bounds.empty()) try focus(slot.id);
        },
        .bytes => |bytes| {
            if (drag != null and std.mem.eql(u8, bytes, "\x1b")) {
                try cancelDrag();
                return;
            }
            if (focused()) |slot| {
                if (selection_drag != null) {
                    selection_drag = null;
                    scene.releasePointer();
                }
                const had_selection = slot.selecting or slot.surface.?.terminal.screens.active.selection != null;
                slot.surface.?.clearSelection();
                slot.selecting = false;
                selection_drag = null;
                scene.releasePointer();
                if (had_selection and std.mem.eql(u8, bytes, "\x1b") and !decoder.pasting) return;
                if ((std.mem.eql(u8, bytes, "\x1b[200~") or std.mem.eql(u8, bytes, "\x1b[201~")) and !slot.surface.?.terminal.modes.get(.bracketed_paste)) return;
                try write(slot, bytes);
            }
        },
        .focus => |is_focused| if (focused()) |slot| {
            if (slot.surface.?.terminal.modes.get(.focus_event)) try write(slot, if (is_focused) "\x1b[I" else "\x1b[O");
        },
        .mouse => |mouse| {
            if (selection_drag) |*selection| {
                for (&slots) |*slot| if (slot.surface != null and slot.id == selection.id) {
                    const inner = decoration.contentFor(&scene, selection.id);
                    if (!inner.empty() and (mouse.release or mouse.button & 32 != 0)) {
                        const x = std.math.clamp(@as(i32, mouse.x) - inner.x, 0, inner.w - 1);
                        const y = std.math.clamp(@as(i32, mouse.y) - inner.y, 0, inner.h - 1);
                        if (!selection.started and (x != selection.x or y != selection.y)) {
                            try slot.surface.?.selectAt(selection.x, selection.y, false);
                            selection.started = true;
                        }
                        if (selection.started) try slot.surface.?.selectAt(@intCast(x), @intCast(y), true);
                    }
                };
                if (mouse.release) {
                    selection_drag = null;
                    scene.releasePointer();
                }
                return;
            }
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
            if (drag) |original_active| {
                var active = original_active;
                if (mouse.release) {
                    if (active.started) if (destination) |drop| {
                        for (&slots) |*slot| if (slot.surface != null and slot.id == active.id) {
                            slot.floating_bounds = scene.get(active.id).?.bounds;
                        };
                        try drop.apply(&scene, active.id);
                    };
                    drag = null;
                    drag_original = null;
                    destination = null;
                    scene.releasePointer();
                    try applyLayout();
                } else if (mouse.button & 32 != 0) {
                    const dx = @as(i32, mouse.x) - active.x;
                    const dy = @as(i32, mouse.y) - active.y;
                    if (active.edge == .move and !active.started) {
                        if (@abs(dx) < 2 and @abs(dy) < 1) return;
                        if (scene.get(active.id).?.options.kind != .floating) {
                            var remembered: ?core.Rect = null;
                            for (&slots) |*slot| if (slot.surface != null and slot.id == active.id) {
                                remembered = slot.floating_bounds;
                            };
                            const w = if (remembered) |r| r.w else @max(3, @divTrunc(scene.root.w * 2, 3));
                            const h = if (remembered) |r| r.h else @max(3, @divTrunc(scene.root.h * 2, 3));
                            active.bounds = try core.Rect.init(active.x - @divTrunc((active.x - active.bounds.x) * w, @max(1, active.bounds.w)), active.y - @divTrunc((active.y - active.bounds.y) * h, @max(1, active.bounds.h)), w, h);
                            drag.?.bounds = active.bounds;
                        }
                        var options = scene.get(active.id).?.options;
                        // Existing floats keep their layer. Undocking a wall
                        // drops its always-on-top policy along with reservation.
                        if (options.kind != .floating) options = .{ .kind = .{ .floating = active.bounds } };
                        options.kind = .{ .floating = active.bounds };
                        try scene.configure(active.id, options);
                        try scene.raise(active.id);
                    }
                    drag.?.started = true;
                    if (active.split) |split| {
                        const position = if (active.edge == .tile_vertical) active.bounds.right() + dx else active.bounds.bottom() + dy;
                        try scene.resizeDivider(split, position);
                    } else if (active.edge == .divider) {
                        const extent = std.math.clamp(active.bounds.w + dx, @min(3, scene.root.w), @max(3, scene.root.w - 3));
                        dock_extent = extent;
                        try scene.configure(active.id, .{ .kind = .{ .docked = .{ .edge = .left, .extent = extent } }, .always_on_top = true });
                    } else {
                        const requested = decoration.adjust(active.bounds, active.edge, dx, dy, scene.root);
                        try scene.moveResize(active.id, requested);
                    }
                    destination = if (active.edge == .move and !active.free_move and mouse.button & 24 != 24) docking.pick(&scene, active.id, mouse.x, mouse.y, mouse.button & 16 != 0) else null;
                    try applyLayout();
                }
                return;
            }
            const target = scene.pointerTarget(mouse.x, mouse.y) orelse return;
            const press = !mouse.release and mouse.button & 96 == 0 and mouse.button & 3 != 3;
            if (press) {
                const window = scene.get(target).?;
                const inner = decoration.contentFor(&scene, target);
                const on_border = !inner.contains(mouse.x, mouse.y);
                const modified = mouse.button & 8 != 0 and mouse.button & 4 == 0 and (mouse.button & 3 == 0 or mouse.button & 3 == 2);
                const border_edge = decoration.edgeAt(&scene, target, mouse.x, mouse.y);
                const moving = modified and mouse.button & 3 == 0;
                if ((border_edge != .divider and border_edge != .tile_vertical and border_edge != .tile_horizontal) or moving) try focus(target);
                if (moving or (border_edge != null and mouse.button & 3 == 0) or
                    (window.options.kind == .floating and !on_border and modified))
                {
                    const action = if (moving) decoration.Edge.move else border_edge orelse decoration.Edge.bottom_right;
                    drag_original = scene;
                    drag_dock_extent = dock_extent;
                    destination = null;
                    drag = .{ .id = target, .x = mouse.x, .y = mouse.y, .bounds = window.bounds, .edge = action, .free_move = moving and mouse.button & 16 != 0, .split = if (action == .tile_vertical) scene.dividerFor(target, .horizontal) else if (action == .tile_horizontal) scene.dividerFor(target, .vertical) else null };
                    try scene.capturePointer(target);
                    return;
                }
                if (on_border) {
                    border_capture = true;
                    return;
                }
                if (mouse.button == 0) for (&slots) |*slot| if (slot.surface != null and slot.id == target) {
                    const modes = slot.surface.?.terminal.modes;
                    if (slot.selecting or (!modes.get(.mouse_event_normal) and !modes.get(.mouse_event_button) and !modes.get(.mouse_event_any))) {
                        slot.surface.?.clearSelection();
                        selection_drag = .{ .id = target, .x = @intCast(@as(i32, mouse.x) - inner.x), .y = @intCast(@as(i32, mouse.y) - inner.y) };
                        try scene.capturePointer(target);
                        return;
                    }
                };
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
                if (s.terminal.modes.get(.mouse_format_sgr_pixels)) {
                    // The outer host requests cell reports. Project their centers
                    // into the child pixel grid, after subtracting pane borders.
                    const cw: i32 = @max(1, s.size.cell_width);
                    const ch: i32 = @max(1, s.size.cell_height);
                    const px = (x - 1) * cw + @divTrunc(cw, 2) + 1;
                    const py = (y - 1) * ch + @divTrunc(ch, 2) + 1;
                    var buf: [80]u8 = undefined;
                    try write(slot, try std.mem.print(&buf, "\x1b[<{d};{d};{d}{s}", .{ mouse.button, px, py, if (mouse.release) "m" else "M" }));
                } else if (s.terminal.modes.get(.mouse_format_sgr)) {
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
fn hasShells() bool {
    for (&slots) |*slot| if (slot.surface != null) return true;
    return false;
}
fn draw() !void {
    var changed = borders_dirty or layout_dirty or drawn_scene != scene.revision;
    for (&slots) |*slot| if (slot.surface) |s| {
        changed = changed or slot.drawn_revision != s.revision;
    };
    if (!changed) return;
    const render_scene = scene;
    var preview: ?core.Rect = null;
    if (destination) |drop| if (drag) |active| {
        const rect = try drop.preview(&scene, active.id);
        if (!rect.empty()) preview = rect;
    };
    try display("\x1b[?2026h\x1b[?25l\x1b[?7l\x1b[0m");
    if (layout_dirty) {
        try display("\x1b[2J");
        // Paint only unoccupied desktop cells. Windows render their own tinted
        // retained content; borders and Kitty placements keep their normal form.
        if (preview) |rect| {
            if (border_output == null) border_output = .init(allocator);
            const output = &border_output.?;
            output.clearRetainingCapacity();
            try output.writer.writeAll("\x1b[0;48;2;20;28;33m");
            var y = rect.y;
            while (y < rect.bottom()) : (y += 1) {
                var x = rect.x;
                while (x < rect.right()) {
                    if (scene.hitTest(x, y) != null) {
                        x += 1;
                        continue;
                    }
                    const start = x;
                    while (x < rect.right() and scene.hitTest(x, y) == null) : (x += 1) {}
                    try output.writer.print("\x1b[{d};{d}H", .{ y + 1, start + 1 });
                    try output.writer.splatByteAll(' ', @intCast(x - start));
                }
            }
            try output.writer.writeAll("\x1b[0m");
            try display(output.written());
        }
    }
    for (&slots) |*slot| if (slot.surface) |s| {
        if (layout_dirty) {
            slot.renderer.invalidate(allocator);
            // Preview scenes and cancelled layouts can reuse a revision number.
            slot.renderer.region_scene = null;
        }
        if (!layout_dirty and drawn_scene == scene.revision and slot.drawn_revision == s.revision) continue;
        slot.renderer.tint = if (preview) |rect| .{ .bounds = rect } else null;
        const frame = try slot.renderer.draw(allocator, &render_scene, slot.id, s);
        try display(frame);
        slot.drawn_revision = s.revision;
    };
    if (borders_dirty or layout_dirty or drawn_scene != scene.revision) {
        if (border_output == null) border_output = .init(allocator);
        const output = &border_output.?;
        output.clearRetainingCapacity();
        for (&slots) |*slot| if (slot.surface != null) try decoration.draw(&output.writer, &render_scene, slot.id, if (hover_id == slot.id) hover_edge else null);
        if (!hasShells()) {
            const label = "compo";
            const hint = "Ctrl-] Enter: shell   Ctrl-] q: quit";
            if (scene.root.w >= hint.len and scene.root.h >= 4) {
                try output.writer.print("\x1b[{d};{d}H\x1b[36mcompo\x1b[0m\x1b[{d};{d}H{s}", .{ @divTrunc(scene.root.h, 2), @divTrunc(scene.root.w - @as(i32, label.len), 2) + 1, @divTrunc(scene.root.h, 2) + 2, @divTrunc(scene.root.w - @as(i32, hint.len), 2) + 1, hint });
            }
        }
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
            if (render_scene.hitTest(x, y) == slot.id)
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
    if (drag != null) restoreDrag();
    const slot = &slots[@intCast(index)];
    clearImages(slot);
    slot.surface.?.destroy();
    slot.surface = null;
    slot.selecting = false;
    if (selection_drag) |selection| if (selection.id == slot.id) {
        selection_drag = null;
    };
    if (slot.name) |name| allocator.free(name);
    if (slot.command) |command| allocator.free(command);
    slot.name = null;
    slot.command = null;
    const next_image = slot.renderer.next_image;
    slot.renderer.deinit(allocator);
    slot.renderer = .{ .next_image = next_image, .image_stride = host.capacity, .framed = false, .bordered = true, .inactive_cursor = true };
    slot.drawn_revision = null;
    scene.remove(slot.id) catch |err| {
        failure = err;
        return -1;
    };
    drag = null;
    scene.releasePointer();
    // Keep the float floating while a base shell remains. Promote the last
    // shell to a visible full-root tile so a hidden child cannot strand exit.
    if (!host.desktop) for (slots[0..@min(count, 3)]) |*other| if (other.surface != null) {
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

pub var control_dirty = false;
const Placement = struct {
    kind: enum { floating },
    rect: core.Rect,
    fit: enum { exact, constrain } = .exact,
    layer: i32 = 0,
};
const ControlRequest = struct {
    id: []const u8,
    op: []const u8,
    window: ?[]const u8 = null,
    name: ?[]const u8 = null,
    argv: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    env: std.json.ArrayHashMap([]const u8) = .{},
    placement: ?Placement = null,
    focus: bool = false,
};
const WindowInfo = struct {
    window: []const u8,
    name: ?[]const u8,
    command: ?[]const u8,
    state: []const u8 = "running",
    rect: core.Rect,
    content: core.Rect,
    columns: u16,
    rows: u16,
    cell_width: u16,
    cell_height: u16,
    kind: []const u8,
    layer: i32,
    order: u64,
    visible: bool,
    focused: bool,
};
fn windowInfo(a: std.mem.Allocator, instance: []const u8, slot: *const Slot) !WindowInfo {
    const w = scene.get(slot.id).?;
    const s = slot.surface.?;
    return .{
        .window = try std.fmt.allocPrint(a, "{s}/{d}", .{ instance, slot.id }),
        .name = slot.name,
        .command = slot.command,
        .rect = w.bounds,
        .content = decoration.contentFor(&scene, slot.id),
        .columns = s.size.columns,
        .rows = s.size.rows,
        .cell_width = pixel_width,
        .cell_height = pixel_height,
        .kind = @tagName(w.options.kind),
        .layer = w.options.layer,
        .order = w.order,
        .visible = w.visible,
        .focused = scene.focus == slot.id,
    };
}
fn resolveWindow(instance: []const u8, reference: ?[]const u8) !*Slot {
    const ref = reference orelse return error.MissingWindow;
    if (ref.len <= instance.len + 1 or !std.mem.startsWith(u8, ref, instance) or ref[instance.len] != '/') return error.UnknownWindow;
    const id = std.fmt.parseInt(core.Id, ref[instance.len + 1 ..], 10) catch return error.UnknownWindow;
    for (&slots) |*slot| if (slot.surface != null and slot.id == id) return slot;
    return error.UnknownWindow;
}
fn validString(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) == null;
}
fn placementScene(candidate: *core.Scene, id: ?core.Id, placement: Placement) !core.Id {
    const rect = try core.Rect.init(placement.rect.x, placement.rect.y, placement.rect.w, placement.rect.h);
    if (rect.w < 3 or rect.h < 3) return error.InvalidBounds;
    const options: core.Options = .{ .kind = .{ .floating = rect }, .layer = placement.layer };
    const target = if (id) |existing| blk: {
        if (candidate.get(existing).?.options.kind != .floating) return error.NotFloating;
        try candidate.configure(existing, options);
        break :blk existing;
    } else try candidate.add(options);
    const actual = candidate.get(target).?.bounds;
    if (actual.w < 3 or actual.h < 3) return error.InvalidBounds;
    if (placement.fit == .exact and !std.meta.eql(rect, actual)) return error.PlacementRejected;
    return target;
}

pub fn controlDispatch(a: std.mem.Allocator, value: std.json.Value, instance: []const u8) ![]u8 {
    const parsed = std.json.parseFromValue(ControlRequest, a, value, .{}) catch return error.InvalidRequest;
    defer parsed.deinit();
    const req = parsed.value;
    const create = std.mem.eql(u8, req.op, "window.create");
    const list = std.mem.eql(u8, req.op, "window.list");
    const get = std.mem.eql(u8, req.op, "window.get");
    const place = std.mem.eql(u8, req.op, "window.place");
    // Reject even valid field names when they do not apply to this operation.
    for (value.object.keys()) |key| {
        if (std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "op")) continue;
        if (!list and !create and std.mem.eql(u8, key, "window")) continue;
        if ((create or place) and std.mem.eql(u8, key, "placement")) continue;
        if (create) {
            var allowed = false;
            for ([_][]const u8{ "name", "argv", "cwd", "env", "focus" }) |field| if (std.mem.eql(u8, key, field)) {
                allowed = true;
            };
            if (allowed) continue;
        }
        return error.InvalidRequest;
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    if (list) {
        var windows: [host.capacity]WindowInfo = undefined;
        var n: usize = 0;
        for (&slots) |*slot| if (slot.surface != null) {
            windows[n] = try windowInfo(temp, instance, slot);
            n += 1;
        };
        return std.json.Stringify.valueAlloc(a, .{ .id = req.id, .result = .{ .windows = windows[0..n], .scene_revision = scene.revision } }, .{});
    }
    if (drag != null and !get) return error.DragInProgress;
    var slot: *Slot = undefined;
    if (create) {
        const argv = req.argv orelse return error.MissingArgv;
        if (argv.len == 0 or argv.len > 128 or argv[0].len == 0 or argv[0].len > 512 or argv[0][0] != '/') return error.InvalidArgv;
        var total: usize = 0;
        for (argv) |arg| {
            if (!validString(arg)) return error.InvalidArgv;
            total += arg.len;
        }
        if (total > 8192) return error.InvalidArgv;
        if (req.cwd) |cwd| if (!validString(cwd) or cwd.len == 0 or cwd[0] != '/') return error.InvalidCwd;
        for (req.env.map.keys(), req.env.map.values()) |key, val| {
            if (key.len == 0 or !validString(key) or !validString(val) or std.mem.indexOfScalar(u8, key, '=') != null) return error.InvalidEnvironment;
        }
        if (req.name) |name| {
            if (name.len == 0 or name.len > 128 or !validString(name)) return error.InvalidName;
            for (&slots) |existing| if (existing.name) |other| if (std.mem.eql(u8, name, other)) return error.NameInUse;
        }
        const metadata = try std.json.Stringify.valueAlloc(temp, .{ .name = req.name, .command = argv[0] }, .{});
        if (metadata.len > 1024) return error.MetadataTooLarge;
        var available: ?*Slot = null;
        for (&slots) |*candidate| if (candidate.surface == null) {
            available = candidate;
            break;
        };
        slot = available orelse return error.CapacityExceeded;
        var candidate = scene;
        const id = try placementScene(&candidate, null, req.placement orelse return error.MissingPlacement);
        const name = if (req.name) |name| try allocator.dupe(u8, name) else null;
        errdefer if (name) |n| allocator.free(n);
        const command = try allocator.dupe(u8, argv[0]);
        errdefer allocator.free(command);
        const bounds = decoration.contentFor(&candidate, id);
        const s = try terminal.Surface.create(io, allocator, .{ .columns = @intCast(bounds.w), .rows = @intCast(bounds.h), .cell_width = pixel_width, .cell_height = pixel_height }, .{ .context = slot, .write = write });
        errdefer s.destroy();
        if (host.setSize(slot.index, @intCast(bounds.w), @intCast(bounds.h), pixel_width, pixel_height) != 0) return error.ChildResizeFailed;
        try host.spawnCommand(@intCast(slot.index), argv, req.cwd, req.env);
        scene = candidate;
        slot.id = id;
        slot.surface = s;
        slot.name = name;
        slot.command = command;
        slot.floating_bounds = null;
        slot.drawn_revision = null;
        slot.renderer.invalidate(allocator);
        if (req.focus) try focus(id);
    } else {
        slot = try resolveWindow(instance, req.window);
        if (place) {
            var candidate = scene;
            _ = try placementScene(&candidate, slot.id, req.placement orelse return error.MissingPlacement);
            const bounds = decoration.contentFor(&candidate, slot.id);
            const old = slot.surface.?.size;
            if (host.setSize(slot.index, @intCast(bounds.w), @intCast(bounds.h), pixel_width, pixel_height) != 0) return error.ChildResizeFailed;
            _ = slot.surface.?.resize(.{ .columns = @intCast(bounds.w), .rows = @intCast(bounds.h), .cell_width = pixel_width, .cell_height = pixel_height }) catch |err| {
                _ = host.setSize(slot.index, old.columns, old.rows, pixel_width, pixel_height);
                return err;
            };
            scene = candidate;
        } else if (std.mem.eql(u8, req.op, "window.close")) {
            host.closeWindow(@intCast(slot.index));
            if (compositor_exit(slot.index) != 0) return error.CloseFailed;
            control_dirty = true;
            return std.json.Stringify.valueAlloc(a, .{ .id = req.id, .result = .{ .removed = req.window.?, .scene_revision = scene.revision } }, .{});
        } else if (std.mem.eql(u8, req.op, "window.focus")) {
            try focus(slot.id);
        } else if (std.mem.eql(u8, req.op, "window.raise")) {
            try scene.raise(slot.id);
        } else if (std.mem.eql(u8, req.op, "window.lower")) {
            try scene.lower(slot.id);
        } else if (!get) return error.UnknownOperation;
    }
    if (!get) {
        control_dirty = true;
        layout_dirty = true;
    }
    return std.json.Stringify.valueAlloc(a, .{ .id = req.id, .result = .{ .window = try windowInfo(temp, instance, slot), .requested_rect = if (req.placement) |p| @as(?core.Rect, p.rect) else null, .scene_revision = scene.revision } }, .{});
}
