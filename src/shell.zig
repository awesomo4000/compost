const std = @import("std");
const core = @import("compositor");
const terminal = @import("terminal");
const input = @import("input.zig");
const docking = @import("docking.zig");
const decoration = @import("frame.zig");
const title = @import("title.zig");
const help_panel = @import("help.zig");
var help_visible = false;
var numbers_visible = false;
var missing_number: [32]u8 = undefined;
var title_animation: title.Animator = .{};
var title_frame: title.Frame = .{ .alpha = 0, .scatter = 1 };
var title_mouse_release = false;
var title_enabled = true;
var title_paste = false;
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
const Notice = struct { count: usize, action: enum { copied, pasted }, until: u64 };
var paste_target: ?struct { id: ?core.Id, count: usize = 0, bracketed: bool = false } = null;
const Slot = struct { number: ?u8 = null, sync_until: ?u64 = null, notice: ?Notice = null, browsing: bool = false, selecting: bool = false, name: ?[]u8 = null, command: ?[]u8 = null, index: c_int, id: core.Id = 0, surface: ?*terminal.Surface = null, renderer: Renderer, drawn_revision: ?u64 = null, floating_bounds: ?core.Rect = null };
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
var cursor_visible: ?bool = null;
var cursor_style: ?u8 = null;
const allocator = std.heap.smp_allocator;
var trace_mouse = false;
var startup_notice: ?struct { text: []const u8, until: u64 } = null;
const usage =
    \\Usage: compo [--init FILE | --no-init] [--no-title] [--prefix KEY] [--help|-h]
    \\       compo ctl [--socket PATH] COMMAND
    \\
    \\With no arguments, open the compositor desktop.
    \\--prefix KEY overrides COMPO_PREFIX (default Ctrl-]); e.g. ctrl-] or C-].
    \\Use Ctrl-a through Ctrl-z, Ctrl-@, Ctrl-\, Ctrl-], Ctrl-^, or Ctrl-_.
    \\--no-title skips the startup modal. Any key or click dismisses it otherwise.
    \\Startup: --init FILE, otherwise COMPO_INIT or ~/.config/compo/init.sh.
    \\XDG_CONFIG_HOME overrides ~/.config. --no-init disables startup scripts.
    \\Scripts run under /bin/sh with COMPO_BIN and COMPO_SOCKET, outside any pane.
    \\
    \\Run compo ctl --help for per-window commands and placement options.
    \\COMPO_SOCKET selects the control socket for ctl and is inherited by children.
    \\COMPO_BORDER_STYLE=plain selects plain borders instead of the aurora gradient.
    \\COMPO_HEADLESS=80x24 runs a headless control host for testing.
    \\COMPO_SINGLE=1, COMPO_LEGACY=1, COMPO_FLOAT=1 select fixture layouts.
    \\COMPO_COMMAND, COMPO_SIDEBAR_COMMAND, COMPO_FLOAT_COMMAND set fixture commands.
    \\COMPO_DESKTOP=1 forces empty desktop startup even with fixture commands set.
    \\COMPO_TRACE_MOUSE=1 traces button events and routing to stderr, without keys.
    \\Terminal diagnostics are buffered until exit when stderr is a terminal.
    \\Redirect stderr for live diagnostics: compo 2>/tmp/compo.log
    \\
;

fn traceMouse(mouse: input.Mouse, comptime format: []const u8, args: anytype) void {
    // Hover can produce thousands of events. Trace buttons/wheel only.
    if (trace_mouse and mouse.button & 32 == 0) std.log.scoped(.mouse_trace).warn(format, args);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "ctl")) {
        const status = @import("ctl.zig").run(init.gpa, args[2..]) catch |err| {
            std.debug.print("compo ctl: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        if (status != 0) std.process.exit(status);
        return;
    }
    var init_path: ?[:0]const u8 = null;
    var no_init = false;
    var show_help = false;
    var prefix_name: ?[]const u8 = if (std.c.getenv("COMPO_PREFIX")) |value| std.mem.span(value) else null;
    var arg_index: usize = 1;
    while (arg_index < args.len) : (arg_index += 1) {
        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--prefix")) {
            arg_index += 1;
            if (arg_index == args.len) return error.MissingPrefix;
            prefix_name = args[arg_index];
        } else if (std.mem.eql(u8, arg, "--no-title")) {
            title_animation.phase = .hidden;
            title_enabled = false;
        } else if (std.mem.eql(u8, arg, "--init")) {
            if (init_path != null or no_init) return error.ConflictingStartupOptions;
            arg_index += 1;
            if (arg_index == args.len) return error.MissingStartupFile;
            init_path = args[arg_index];
        } else if (std.mem.eql(u8, arg, "--no-init")) {
            if (init_path != null) return error.ConflictingStartupOptions;
            no_init = true;
        } else return error.UnknownCommand;
    }
    if (prefix_name) |name| decoder.prefix_key = input.Prefix.parse(name) catch {
        std.debug.print("compo: invalid prefix '{s}'; use Ctrl-a through Ctrl-z or Ctrl-@, Ctrl-\\, Ctrl-], Ctrl-^, Ctrl-_ (Escape is reserved).\n", .{name});
        std.process.exit(1);
    };
    if (show_help) {
        try display(usage);
        var buffer: [256]u8 = undefined;
        for (input.bindings) |binding| {
            try display(try std.mem.print(&buffer, "{s} {s}: {s}\n", .{ decoder.prefix_key.label(), binding.label, binding.description }));
        }
        try display(try std.mem.print(&buffer, "{s} 1-9, 0: focus window 1-10\n{s} twice: send literal prefix\n", .{ decoder.prefix_key.label(), decoder.prefix_key.label() }));
        try display("Alt-drag: move/dock; Ctrl-Alt-drag: free move; border drag: resize\n");
        return;
    }
    host.startup_script = try @import("startup.zig").findScript(init.arena.allocator(), init_path, no_init);
    if (host.startup_script != null) {
        host.startup_binary = try std.process.executablePathAlloc(init.io, init.arena.allocator());
        var cwd: [4096]u8 = undefined;
        const path = std.c.getcwd(&cwd, cwd.len) orelse return error.StartupDirectoryUnavailable;
        host.startup_directory = try init.arena.allocator().dupeSentinel(u8, std.mem.span(@as([*:0]const u8, @ptrCast(path))), 0);
    }
    io = init.io;
    trace_mouse = if (std.c.getenv("COMPO_TRACE_MOUSE")) |v| std.mem.eql(u8, std.mem.span(v), "1") else false;
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
            slot.number = if (i < 10) @intCast(i + 1) else null;
            slot.id = try scene.add(if (i == 0 and count >= 2)
                .{ .kind = .{ .docked = .{ .edge = .left, .extent = extent } }, .always_on_top = true }
            else if (i == 2)
                .{ .kind = .{ .floating = try core.Rect.init(scene.usable.x + @divTrunc(scene.usable.w, 4), @divTrunc(root.h, 4), @max(1, @divTrunc(scene.usable.w, 2)), @max(1, @divTrunc(root.h, 2))) } }
            else
                .{ .kind = .tiled });
            const bounds = decoration.contentFor(&scene, slot.id);
            slot.surface = try terminal.Surface.createWithHistory(io, allocator, .{
                .columns = @intCast(@max(1, bounds.w)),
                .rows = @intCast(@max(1, bounds.h)),
                .cell_width = pixel_width,
                .cell_height = pixel_height,
            }, .{ .context = slot, .write = write }, 8 * 1024 * 1024);
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
    const slot = &slots[@intCast(index)];
    slot.surface.?.feed(bytes) catch |err| {
        failure = err;
        return -1;
    };
    if (slot.surface.?.terminal.modes.get(.synchronized_output)) {
        if (slot.sync_until == null) slot.sync_until = host.milliseconds() +| 1000;
    } else slot.sync_until = null;
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
fn availableNumber(requested: ?u8) !?u8 {
    if (requested) |n| {
        if (n < 1 or n > 10) return error.InvalidNumber;
        for (&slots) |slot| if (slot.surface != null and slot.number == @as(u8, @intCast(n))) return error.NumberInUse;
        return n;
    }
    for (1..11) |n| {
        var used = false;
        for (&slots) |slot| if (slot.surface != null and slot.number == @as(u8, @intCast(n))) {
            used = true;
            break;
        };
        if (!used) return @intCast(n);
    }
    return null;
}
fn newShell() !void {
    if (drag != null) try cancelDrag();
    var free: ?*Slot = null;
    for (&slots) |*slot| if (slot.surface == null) {
        free = slot;
        break;
    };
    const slot = free orelse return;
    const number = try availableNumber(null);
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
    slot.surface = try terminal.Surface.createWithHistory(io, allocator, .{ .columns = @intCast(bounds.w), .rows = @intCast(bounds.h), .cell_width = pixel_width, .cell_height = pixel_height }, .{ .context = slot, .write = write }, 8 * 1024 * 1024);
    errdefer {
        slot.surface.?.destroy();
        slot.surface = null;
        slot.sync_until = null;
    }
    if (host.setSize(slot.index, @intCast(bounds.w), @intCast(bounds.h), pixel_width, pixel_height) != 0 or !host.spawn(@intCast(slot.index), false)) return error.ChildSpawnFailed;
    slot.number = number;
    try focus(slot.id);
    try applyLayout();
}
fn event(_: *anyopaque, value: input.Event) !void {
    if (title_paste) {
        if (value == .bytes and std.mem.eql(u8, value.bytes, "\x1b[201~")) title_paste = false;
        return;
    }
    if (title_mouse_release and value == .mouse) {
        if (value.mouse.release) title_mouse_release = false;
        return;
    }
    if (title_animation.active()) {
        switch (value) {
            .focus => {},
            .mouse => |mouse| {
                if (!mouse.release and mouse.button & 96 == 0 and mouse.button & 3 != 3) {
                    title_mouse_release = true;
                    title_animation.dismiss(host.milliseconds());
                }
            },
            .bytes => |bytes| {
                title_paste = std.mem.eql(u8, bytes, "\x1b[200~");
                title_animation.dismiss(host.milliseconds());
            },
            .quit => host.quit(),
            else => title_animation.dismiss(host.milliseconds()),
        }
        return;
    }
    if (help_visible) {
        switch (value) {
            .help => {
                help_visible = false;
                layout_dirty = true;
            },
            .bytes => |bytes| {
                if (std.mem.eql(u8, bytes, "\x1b[200~")) title_paste = true;
                if (std.mem.eql(u8, bytes, "\x1b")) {
                    help_visible = false;
                    layout_dirty = true;
                }
            },
            .mouse => |mouse| {
                if (!mouse.release and mouse.button & 96 == 0 and mouse.button & 3 != 3 and !help_panel.bounds(scene.root).contains(mouse.x, mouse.y)) {
                    help_visible = false;
                    layout_dirty = true;
                    title_mouse_release = true;
                }
            },
            else => {},
        }
        return;
    }
    switch (value) {
        .help => {
            if (drag != null) try cancelDrag();
            help_visible = true;
            layout_dirty = true;
        },
        .numbers => {
            numbers_visible = !numbers_visible;
            layout_dirty = true;
        },
        .focus_number => |number| {
            var target: ?*Slot = null;
            for (&slots) |*slot| if (slot.surface != null and slot.number == number) {
                target = slot;
                break;
            };
            if (target) |slot| {
                if (drag != null) try cancelDrag();
                try scene.setVisible(slot.id, true);
                try focus(slot.id);
                try scene.raise(slot.id);
                try applyLayout();
            } else {
                const text = try std.mem.print(&missing_number, "No window {d}", .{if (number == 10) @as(u8, 0) else number});
                startupNotice(text);
            }
        },
        .new_shell => try newShell(),
        .scrollback => if (focused()) |slot| {
            slot.browsing = !slot.browsing;
            slot.surface.?.scroll(if (slot.browsing) .{ .delta = -@as(isize, slot.surface.?.size.rows) } else .bottom);
        },
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
                showNotice(slot, .copied, characterCount(text));
                slot.surface.?.clearSelection();
                slot.selecting = false;
                selection_drag = null;
                scene.releasePointer();
            }
        },
        .reload => host.requestReload() catch |err| startupNotice(switch (err) {
            error.NoStartupScript => "no startup script",
            error.StartupBusy => "startup script busy",
            else => "reload failed",
        }),
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
            if (std.mem.eql(u8, bytes, "\x1b[200~")) {
                paste_target = .{ .id = null };
                if (focused()) |slot| if (!slot.browsing) {
                    paste_target.?.id = slot.id;
                    paste_target.?.bracketed = slot.surface.?.terminal.modes.get(.bracketed_paste);
                    slot.surface.?.clearSelection();
                    slot.selecting = false;
                    selection_drag = null;
                    scene.releasePointer();
                    if (!slot.surface.?.terminal.screens.active.viewportIsBottom()) slot.surface.?.scroll(.bottom);
                    if (slot.surface.?.terminal.modes.get(.bracketed_paste)) try write(slot, bytes);
                };
                return;
            }
            if (paste_target) |*paste| {
                const end = std.mem.eql(u8, bytes, "\x1b[201~");
                for (&slots) |*slot| if (slot.surface != null and paste.id == slot.id) {
                    if (!end or paste.bracketed) try write(slot, bytes);
                    if (end) showNotice(slot, .pasted, paste.count) else paste.count +|= characterCount(bytes);
                };
                if (end) paste_target = null;
                return;
            }
            if (std.mem.eql(u8, bytes, "\x1b[201~")) return;
            if (drag != null and std.mem.eql(u8, bytes, "\x1b")) {
                try cancelDrag();
                return;
            }
            if (focused()) |slot| {
                if (!decoder.pasting and (std.mem.eql(u8, bytes, "\x1b[5;2~") or std.mem.eql(u8, bytes, "\x1b[6;2~"))) {
                    const amount: isize = slot.surface.?.size.rows;
                    slot.surface.?.scroll(.{ .delta = if (bytes[2] == '5') -amount else amount });
                    return;
                }
                if (slot.browsing) {
                    if (decoder.pasting) return;
                    if (bytes.len > 1 and bytes[0] != 0x1b) {
                        for (bytes) |byte| {
                            if (!slot.browsing) break;
                            try event(&input_context, .{ .bytes = &.{byte} });
                        }
                        return;
                    }
                    const s = slot.surface.?;
                    if (std.mem.eql(u8, bytes, "\x1b") or std.mem.eql(u8, bytes, "q")) {
                        slot.browsing = false;
                        s.clearSelection();
                        selection_drag = null;
                        scene.releasePointer();
                        s.scroll(.bottom);
                    } else if (std.mem.eql(u8, bytes, "k") or std.mem.eql(u8, bytes, "\x1b[A")) s.scroll(.{ .delta = -1 }) else if (std.mem.eql(u8, bytes, "j") or std.mem.eql(u8, bytes, "\x1b[B")) s.scroll(.{ .delta = 1 }) else if (std.mem.eql(u8, bytes, "\x1b[5~")) s.scroll(.{ .delta = -@as(isize, s.size.rows) }) else if (std.mem.eql(u8, bytes, "\x1b[6~")) s.scroll(.{ .delta = s.size.rows }) else if (std.mem.eql(u8, bytes, "g")) s.scroll(.top) else if (std.mem.eql(u8, bytes, "G")) s.scroll(.bottom);
                    return;
                }
                if (!slot.surface.?.terminal.screens.active.viewportIsBottom()) slot.surface.?.scroll(.bottom);
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
        .mouse => |incoming_mouse| {
            var mouse = incoming_mouse;
            traceMouse(mouse, "received button={d} release={} cell={d},{d} focus={?d} capture={?d}", .{ mouse.button, mouse.release, mouse.x, mouse.y, scene.focus, scene.capture });
            // All-motion reporting includes motion with a button held. A drag
            // that began outside a child (or whose release was intercepted)
            // must not create a new application drag without a preceding press.
            // Treat it as hover so borders and application hover still work.
            // tmux treats the next real click as drag-end if forwarded unchanged.
            if (!mouse.release and mouse.button & 32 != 0 and mouse.button & 3 != 3 and scene.capture == null) {
                if (trace_mouse) std.log.scoped(.mouse_trace).warn("normalized orphan drag to hover button={d} cell={d},{d}", .{ mouse.button, mouse.x, mouse.y });
                // Retain Shift/Alt/Control, clear button identity, set no-button motion.
                mouse.button = (mouse.button & 28) | 35;
            }
            if (selection_drag) |*selection| {
                traceMouse(mouse, "consumed by selection window={d}", .{selection.id});
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
                traceMouse(mouse, "consumed by border capture", .{});
                if (mouse.release) border_capture = false;
                return;
            }
            if (drag) |original_active| {
                traceMouse(mouse, "consumed by window drag window={d}", .{original_active.id});
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
                    traceMouse(mouse, "consumed by border window={d}", .{target});
                    border_capture = true;
                    return;
                }
                if (mouse.button == 0) for (&slots) |*slot| if (slot.surface != null and slot.id == target) {
                    const modes = slot.surface.?.terminal.modes;
                    if (slot.selecting or slot.browsing or (!modes.get(.mouse_event_normal) and !modes.get(.mouse_event_button) and !modes.get(.mouse_event_any))) {
                        traceMouse(mouse, "selection start window={d} forced={} browsing={} modes={}/{}/{}", .{ target, slot.selecting, slot.browsing, modes.get(.mouse_event_normal), modes.get(.mouse_event_button), modes.get(.mouse_event_any) });
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
                traceMouse(mouse, "route window={d} modes={}/{}/{} browsing={} viewport_bottom={}", .{ target, normal, button, any, slot.browsing, s.terminal.screens.active.viewportIsBottom() });
                if (!mouse.release and mouse.button & 64 != 0 and mouse.button & 3 < 2 and
                    decoration.contentFor(&scene, target).contains(mouse.x, mouse.y) and
                    (slot.browsing or (!normal and !button and !any)))
                {
                    s.scroll(.{ .delta = if (mouse.button & 1 == 0) -3 else 3 });
                    return;
                }
                if (slot.browsing or !s.terminal.screens.active.viewportIsBottom()) return;
                if (!normal and !button and !any) return;
                if (mouse.button & 32 != 0 and !any and !(button and scene.capture != null)) return;
                const bounds = decoration.contentFor(&scene, target);
                if (bounds.empty()) return;
                if (scene.capture == null and !bounds.contains(mouse.x, mouse.y)) return;
                const x = std.math.clamp(@as(i32, mouse.x) - bounds.x, 0, bounds.w - 1) + 1;
                const y = std.math.clamp(@as(i32, mouse.y) - bounds.y, 0, bounds.h - 1) + 1;
                traceMouse(mouse, "forward window={d} button={d} release={} child_cell={d},{d} sgr={} pixels={}", .{ target, mouse.button, mouse.release, x, y, s.terminal.modes.get(.mouse_format_sgr), s.terminal.modes.get(.mouse_format_sgr_pixels) });
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
    decoder.idle(sink) catch |err| {
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
        changed = changed or (slot.sync_until == null and slot.drawn_revision != s.revision);
    };
    if (!changed) return;
    const render_scene = scene;
    var preview: ?core.Rect = null;
    if (destination) |drop| if (drag) |active| {
        const rect = try drop.preview(&scene, active.id);
        if (!rect.empty()) preview = rect;
    };
    try display("\x1b[?2026h\x1b[?7l\x1b[0m");
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
        if (!layout_dirty and drawn_scene == scene.revision) {
            if (slot.sync_until != null or slot.drawn_revision == s.revision) continue;
        } else if (slot.sync_until != null) {
            // Geometry/focus changes need a fresh projection. Cancel the hold
            // rather than leave retained rows at their old screen coordinates.
            s.terminal.modes.set(.synchronized_output, false);
            slot.sync_until = null;
        }
        slot.renderer.occlusion = if (title_animation.active()) title.bounds(scene.root) else if (help_visible) help_panel.bounds(scene.root) else null;
        slot.renderer.tint = if (title_animation.active()) .{ .bounds = scene.root, .color = .{ .r = 18, .g = 20, .b = 23 }, .alpha = 110 } else if (preview) |rect| .{ .bounds = rect } else null;
        const frame = try slot.renderer.draw(allocator, &render_scene, slot.id, s);
        try display(frame);
        slot.drawn_revision = s.revision;
    };
    if (borders_dirty or layout_dirty or drawn_scene != scene.revision) {
        if (border_output == null) border_output = .init(allocator);
        const output = &border_output.?;
        output.clearRetainingCapacity();
        for (&slots) |*slot| if (slot.surface != null) try decoration.draw(&output.writer, &render_scene, slot.id, if (hover_id == slot.id) hover_edge else null);
        for (&slots) |*slot| if (slot.surface != null) {
            if (numbers_visible) if (slot.number) |number| {
                var label_buffer: [160]u8 = undefined;
                // Only printable ASCII names belong in terminal decorations.
                const name = slot.name orelse "";
                var safe = true;
                for (name) |byte| if (byte < 32 or byte > 126) {
                    safe = false;
                    break;
                };
                const label = try std.mem.print(&label_buffer, "[{d}]{s}{s}", .{ if (number == 10) @as(u8, 0) else number, if (safe and name.len > 0) " " else "", if (safe) name else "" });
                const width = scene.get(slot.id).?.bounds.w;
                const shown = if (label.len > @as(usize, @intCast(@max(0, width - 4)))) label[0..3] else label;
                try decoration.drawNumber(&output.writer, &render_scene, slot.id, shown);
            };
            if (slot.notice) |notice| {
                var buffer: [64]u8 = undefined;
                const label = try std.mem.print(&buffer, "[ {d} {s} ]", .{ notice.count, @tagName(notice.action) });
                try decoration.drawNotice(&output.writer, &render_scene, slot.id, label);
            }
        };

        if (startup_notice) |notice| {
            var buf: [96]u8 = undefined;
            const label = try std.mem.print(&buf, "[ {s} ]", .{notice.text});
            if (focused()) |slot| {
                try decoration.drawNotice(&output.writer, &render_scene, slot.id, label);
            } else if (scene.root.w >= label.len) {
                try output.writer.print("\x1b[1;1H\x1b[38;2;90;150;140m{s}\x1b[0m", .{label});
            }
        }
        try display(output.written());
    }
    if (title_animation.active() and (borders_dirty or layout_dirty or drawn_scene != scene.revision)) {
        if (border_output == null) border_output = .init(allocator);
        const output = &border_output.?;
        output.clearRetainingCapacity();
        try title.draw(&output.writer, scene.root, title_frame);
        try display(output.written());
    }
    if (help_visible and (borders_dirty or layout_dirty or drawn_scene != scene.revision)) {
        if (border_output == null) border_output = .init(allocator);
        const output = &border_output.?;
        output.clearRetainingCapacity();
        try help_panel.draw(&output.writer, scene.root, decoder.prefix_key);
        try display(output.written());
    }
    // Capture clicks and drags even when the focused shell has not requested mouse input.
    // Paste markers are always requested so compositor shortcuts never interpret pasted data.
    if (!modes_initialized) {
        try display("\x1b[?1000h\x1b[?1002h\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004h");
        modes_initialized = true;
    }
    var visible_cursor = false;
    if (!title_animation.active() and !help_visible) if (focused()) |slot| {
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
            if (render_scene.hitTest(x, y) == slot.id) {
                visible_cursor = true;
                const style: u8 = (switch (cursor.visual_style) {
                    .block, .block_hollow => @as(u8, 1),
                    .underline => @as(u8, 3),
                    .bar => @as(u8, 5),
                }) + @as(u8, if (cursor.blinking) 0 else 1);
                if (cursor_style != style) {
                    try display(try std.mem.print(&buf, "\x1b[{d} q", .{style}));
                    cursor_style = style;
                }
                try display(try std.mem.print(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }));
            }
        };
    };
    if (cursor_visible != visible_cursor) {
        try display(if (visible_cursor) "\x1b[?25h" else "\x1b[?25l");
        cursor_visible = visible_cursor;
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
    slot.sync_until = null;
    slot.notice = null;
    slot.browsing = false;
    slot.selecting = false;
    if (selection_drag) |selection| if (selection.id == slot.id) {
        selection_drag = null;
    };
    if (slot.name) |name| allocator.free(name);
    if (slot.command) |command| allocator.free(command);
    slot.name = null;
    slot.number = null;
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
    kind: enum { floating, tiled },
    rect: ?core.Rect = null,
    target: ?[]const u8 = null,
    edge: ?core.Edge = null,
    ratio: ?u16 = null,
    fit: enum { exact, constrain } = .exact,
    layer: i32 = 0,
};
const ControlRequest = struct {
    id: []const u8,
    op: []const u8,
    window: ?[]const u8 = null,
    name: ?[]const u8 = null,
    number: ?u8 = null,
    argv: ?[]const []const u8 = null,
    command: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: std.json.ArrayHashMap([]const u8) = .{},
    placement: ?Placement = null,
    focus: bool = false,
};
const WindowInfo = struct {
    window: []const u8,
    name: ?[]const u8,
    number: ?u8,
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
        .number = slot.number,
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
    const explicit_name = std.mem.startsWith(u8, ref, "name:");
    if (explicit_name or std.mem.indexOfScalar(u8, ref, '/') == null) {
        const name = if (explicit_name) ref[5..] else ref;
        for (&slots) |*slot| if (slot.surface != null) {
            if (slot.name) |current| if (std.mem.eql(u8, name, current)) return slot;
        };
        return error.UnknownWindow;
    }
    if (ref.len <= instance.len + 1 or !std.mem.startsWith(u8, ref, instance) or ref[instance.len] != '/') return error.UnknownWindow;
    const id = std.fmt.parseInt(core.Id, ref[instance.len + 1 ..], 10) catch return error.UnknownWindow;
    for (&slots) |*slot| if (slot.surface != null and slot.id == id) return slot;
    return error.UnknownWindow;
}
fn validString(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) == null;
}
fn placementScene(candidate: *core.Scene, id: ?core.Id, placement: Placement, instance: []const u8) !core.Id {
    if (placement.kind == .tiled) {
        if (placement.rect != null or placement.layer != 0 or placement.fit != .exact) return error.InvalidPlacement;
        const anchor = if (placement.target) |ref| (try resolveWindow(instance, ref)).id else null;
        const ratio = placement.ratio orelse 5000;
        if (ratio == 0 or ratio >= 10000) return error.InvalidSplit;
        if (placement.edge == null and (anchor != null or placement.ratio != null)) return error.MissingEdge;
        if (candidate.tree != null and placement.edge == null) return error.MissingEdge;
        var empty = true;
        for (candidate.windows) |maybe| if (maybe) |w| {
            if (w.options.kind == .tiled and (id == null or w.id != id.?)) empty = false;
        };
        const target = id orelse try candidate.add(.{ .kind = .{ .floating = candidate.root } });
        try candidate.placeTileRatio(target, anchor, placement.edge orelse .right, ratio);
        // Scripted first tiles fill the workspace, unlike edge-drop previews.
        if (empty) {
            candidate.first_tile_edge = null;
            try candidate.resizeRoot(candidate.root);
        }
        try validateControlLayout(candidate);
        return target;
    }
    if (placement.target != null or placement.edge != null or placement.ratio != null) return error.InvalidPlacement;
    const requested = placement.rect orelse return error.MissingRect;
    const rect = try core.Rect.init(requested.x, requested.y, requested.w, requested.h);
    if (rect.w < 3 or rect.h < 3) return error.InvalidBounds;
    const options: core.Options = .{ .kind = .{ .floating = rect }, .layer = placement.layer };
    const target = if (id) |existing| blk: {
        try candidate.configure(existing, options);
        break :blk existing;
    } else try candidate.add(options);
    const actual = candidate.get(target).?.bounds;
    if (placement.fit == .exact and !std.meta.eql(rect, actual)) return error.PlacementRejected;
    try validateControlLayout(candidate);
    return target;
}
fn validateControlLayout(candidate: *const core.Scene) !void {
    for (candidate.windows) |maybe| if (maybe) |w| {
        if (!w.visible) continue;
        const bounds = decoration.contentFor(candidate, w.id);
        if (bounds.w < 1 or bounds.h < 1) return error.InvalidBounds;
    };
}
fn resizeControlLayout(candidate: *const core.Scene) !void {
    for (&slots) |*slot| if (slot.surface) |s| {
        const bounds = decoration.contentFor(candidate, slot.id);
        if (bounds.empty()) continue;
        const changed = try s.resize(.{ .columns = @intCast(bounds.w), .rows = @intCast(bounds.h), .cell_width = pixel_width, .cell_height = pixel_height });
        if (changed and host.setSize(slot.index, s.size.columns, s.size.rows, pixel_width, pixel_height) != 0) return error.ChildResizeFailed;
    };
}
fn controlArgv(a: std.mem.Allocator, req: ControlRequest) ![]const []const u8 {
    if (req.argv) |argv| {
        if (req.command != null or req.shell != null) return error.InvalidArgv;
        return argv;
    }
    const shell = req.shell orelse if (std.c.getenv("SHELL")) |v| std.mem.span(v) else "/bin/sh";
    if (shell.len == 0 or shell[0] != '/' or !validString(shell)) return error.InvalidShell;
    if (req.command) |command| {
        if (!validString(command)) return error.InvalidArgv;
        const base = std.fs.path.basename(shell);
        var supported = false;
        for ([_][]const u8{ "sh", "bash", "zsh", "dash", "ksh" }) |known| {
            if (std.mem.eql(u8, base, known)) supported = true;
        }
        if (!supported) return error.UnsupportedCommandShell;
        const argv = try a.alloc([]const u8, 4);
        // A newline also terminates trailing comments in the supplied command.
        argv[0] = shell;
        argv[1] = "-c";
        argv[2] = try std.fmt.allocPrint(a, "{s}\nexec \"$0\" -i", .{command});
        argv[3] = shell;
        return argv;
    }
    const argv = try a.alloc([]const u8, 2);
    argv[0] = shell;
    argv[1] = "-i";
    return argv;
}

pub fn controlDispatch(a: std.mem.Allocator, value: std.json.Value, instance: []const u8) ![]u8 {
    const parsed = std.json.parseFromValue(ControlRequest, a, value, .{}) catch return error.InvalidRequest;
    defer parsed.deinit();
    const req = parsed.value;
    if (std.mem.eql(u8, req.op, "startup.get") or std.mem.eql(u8, req.op, "startup.reload")) {
        for (value.object.keys()) |key| if (!std.mem.eql(u8, key, "id") and !std.mem.eql(u8, key, "op")) return error.InvalidRequest;
        if (std.mem.eql(u8, req.op, "startup.reload")) try host.requestReload();
        return std.json.Stringify.valueAlloc(a, .{ .id = req.id, .result = .{ .script = host.startup_script, .cwd = host.startup_directory, .phase = @tagName(host.startup_phase) } }, .{});
    }
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
            for ([_][]const u8{ "number", "name", "argv", "command", "shell", "cwd", "env", "focus" }) |field| if (std.mem.eql(u8, key, field)) {
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
        const number = try availableNumber(req.number);
        const argv = try controlArgv(temp, req);
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
        const id = try placementScene(&candidate, null, req.placement orelse return error.MissingPlacement, instance);
        const name = if (req.name) |name| try allocator.dupe(u8, name) else null;
        errdefer if (name) |n| allocator.free(n);
        const command = try allocator.dupe(u8, argv[0]);
        errdefer allocator.free(command);
        const bounds = decoration.contentFor(&candidate, id);
        const s = try terminal.Surface.createWithHistory(io, allocator, .{ .columns = @intCast(bounds.w), .rows = @intCast(bounds.h), .cell_width = pixel_width, .cell_height = pixel_height }, .{ .context = slot, .write = write }, 8 * 1024 * 1024);
        errdefer s.destroy();
        if (host.setSize(slot.index, @intCast(bounds.w), @intCast(bounds.h), pixel_width, pixel_height) != 0) return error.ChildResizeFailed;
        try host.spawnCommand(@intCast(slot.index), argv, req.cwd, req.env);
        errdefer host.closeWindow(@intCast(slot.index));
        errdefer resizeControlLayout(&scene) catch {};
        try resizeControlLayout(&candidate);
        scene = candidate;
        slot.id = id;
        slot.surface = s;
        slot.name = name;
        slot.number = number;
        slot.command = command;
        slot.floating_bounds = null;
        slot.drawn_revision = null;
        slot.renderer.invalidate(allocator);
        if (req.focus) focus(id) catch {
            scene.setFocus(id) catch {};
        };
    } else {
        slot = try resolveWindow(instance, req.window);
        if (place) {
            var candidate = scene;
            _ = try placementScene(&candidate, slot.id, req.placement orelse return error.MissingPlacement, instance);
            resizeControlLayout(&candidate) catch |err| {
                resizeControlLayout(&scene) catch {};
                return err;
            };
            scene = candidate;
        } else if (std.mem.eql(u8, req.op, "window.close")) {
            const removed = (try windowInfo(temp, instance, slot)).window;
            host.closeWindow(@intCast(slot.index));
            if (compositor_exit(slot.index) != 0) return error.CloseFailed;
            control_dirty = true;
            return std.json.Stringify.valueAlloc(a, .{ .id = req.id, .result = .{ .removed = removed, .scene_revision = scene.revision } }, .{});
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
    return std.json.Stringify.valueAlloc(a, .{ .id = req.id, .result = .{ .window = try windowInfo(temp, instance, slot), .requested_rect = if (req.placement) |p| p.rect else null, .scene_revision = scene.revision } }, .{});
}

// Count Unicode scalar starts, including sequences split across input chunks.
// Combining marks count separately; clipboard payloads are never modified.
fn characterCount(bytes: []const u8) usize {
    var total: usize = 0;
    for (bytes) |byte| if (byte & 0xc0 != 0x80) {
        total += 1;
    };
    return total;
}
fn showNotice(slot: *Slot, action: @FieldType(Notice, "action"), total: usize) void {
    slot.notice = .{ .count = total, .action = action, .until = host.milliseconds() +| 2000 };
    borders_dirty = true;
}
pub fn startupNotice(text: []const u8) void {
    startup_notice = .{ .text = text, .until = host.milliseconds() +| 3000 };
    borders_dirty = true;
    control_dirty = true;
}
pub fn replayTitle() void {
    help_visible = false;
    if (!title_enabled) return;
    title_animation = .{};
    title_frame = .{ .alpha = 0, .scatter = 1 };
    title_mouse_release = false;
    title_paste = false;
    layout_dirty = true;
}
pub fn closeAllWindows() void {
    paste_target = null;
    selection_drag = null;
    if (drag != null) restoreDrag();
    for (&slots) |*slot| if (slot.surface != null) {
        host.closeWindow(@intCast(slot.index));
        _ = compositor_exit(slot.index);
    };
    layout_dirty = true;
}
pub fn compositor_tick(now: u64) bool {
    var title_changed = false;
    const was_active = title_animation.active();
    if (was_active) {
        const next = title_animation.frame(now);
        title_changed = !std.meta.eql(next, title_frame);
        title_frame = next;
        if (title_changed) borders_dirty = true;
        if (!title_animation.active()) {
            layout_dirty = true;
            title_changed = true;
        }
    }
    var notice_expired = false;
    if (startup_notice) |notice| if (now >= notice.until) {
        startup_notice = null;
        // Clear a desktop notice even when no window owns the top row.
        if (!hasShells()) layout_dirty = true;
        borders_dirty = true;
        notice_expired = true;
    };
    var sync_expired = false;
    for (&slots) |*slot| if (slot.sync_until) |until| {
        if (now >= until) {
            slot.sync_until = null;
            if (slot.surface) |s| s.terminal.modes.set(.synchronized_output, false);
            sync_expired = true;
        }
    };
    var expired = false;
    for (&slots) |*slot| if (slot.notice) |notice| {
        if (now >= notice.until) {
            slot.notice = null;
            expired = true;
        }
    };
    if (expired) borders_dirty = true;
    return expired or sync_expired or notice_expired or title_changed;
}
