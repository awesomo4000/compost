//! Terminal decorations. The geometry core only knows outer rectangles.
const std = @import("std");
const core = @import("compositor");

pub const Style = enum { plain, aurora };
pub var style: Style = .aurora;
const RGB = struct { r: u8, g: u8, b: u8 };
fn mix(a: RGB, b: RGB, amount: i32, span: i32) RGB {
    const total = @max(1, span);
    const n = std.math.clamp(amount, 0, total);
    var result: RGB = undefined;
    inline for (.{ "r", "g", "b" }) |channel| {
        @field(result, channel) = @intCast(@divTrunc(@as(i64, @field(a, channel)) * (total - n) + @as(i64, @field(b, channel)) * n, total));
    }
    return result;
}
fn borderColor(r: core.Rect, x: i32, y: i32, active: bool, hover: bool) RGB {
    const upper = mix(.{ .r = 244, .g = 55, .b = 151 }, .{ .r = 111, .g = 85, .b = 240 }, x - r.x, r.w - 1);
    const lower = mix(.{ .r = 174, .g = 65, .b = 209 }, .{ .r = 49, .g = 179, .b = 144 }, x - r.x, r.w - 1);
    var color = mix(upper, lower, y - r.y, r.h - 1);
    if (!active) color = mix(.{ .r = 30, .g = 30, .b = 34 }, color, 60, 100);
    if (hover) color = mix(color, .{ .r = 255, .g = 255, .b = 255 }, 30, 100);
    return color;
}

pub fn hasBorder(bounds: core.Rect) bool {
    return bounds.w >= 3 and bounds.h >= 3;
}
pub fn content(bounds: core.Rect) core.Rect {
    if (!hasBorder(bounds)) return bounds;
    return .{ .x = bounds.x + 1, .y = bounds.y + 1, .w = bounds.w - 2, .h = bounds.h - 2 };
}
pub fn sharesLeft(scene: *const core.Scene, id: core.Id) bool {
    const window = scene.get(id).?;
    if (window.options.kind != .tiled) return false;
    for (scene.windows) |maybe| if (maybe) |other| {
        if (other.visible and (other.options.kind == .tiled or (other.options.kind == .docked and other.options.kind.docked.edge == .left)) and
            other.bounds.y < window.bounds.bottom() and other.bounds.bottom() > window.bounds.y and
            other.bounds.right() == window.bounds.x and hasBorder(other.bounds)) return true;
    };
    return false;
}
pub fn sharesTop(scene: *const core.Scene, id: core.Id) bool {
    const window = scene.get(id).?;
    if (window.options.kind != .tiled) return false;
    for (scene.windows) |maybe| if (maybe) |other| {
        if (other.visible and other.options.kind == .tiled and hasBorder(other.bounds) and
            other.bounds.bottom() == window.bounds.y and other.bounds.x < window.bounds.right() and other.bounds.right() > window.bounds.x) return true;
    };
    return false;
}
pub fn contentFor(scene: *const core.Scene, id: core.Id) core.Rect {
    const outer = scene.get(id).?.bounds;
    var inner = content(outer);
    if (hasBorder(outer) and sharesLeft(scene, id)) {
        inner.x -= 1;
        inner.w += 1;
    }
    if (hasBorder(outer) and sharesTop(scene, id)) {
        inner.y -= 1;
        inner.h += 1;
    }
    return inner;
}
pub const Edge = enum { left, right, top, bottom, move, top_left, top_right, bottom_left, bottom_right, divider, tile_vertical, tile_horizontal };
pub fn edgeAt(scene: *const core.Scene, id: core.Id, x: i32, y: i32) ?Edge {
    const window = scene.get(id).?;
    const r = window.bounds;
    if (!hasBorder(r) or !r.contains(x, y) or contentFor(scene, id).contains(x, y)) return null;
    if (window.options.kind == .docked and window.options.kind.docked.edge == .left and x == r.right() - 1) return .divider;
    if (window.options.kind == .tiled) {
        if (x == r.right() - 1 and scene.dividerFor(id, .horizontal) != null) return .tile_vertical;
        if (y == r.bottom() - 1 and scene.dividerFor(id, .vertical) != null) return .tile_horizontal;
    }
    if (window.options.kind != .floating) return null;
    // Enlarge corner handles along the border without stealing application cells.
    const near_left = x - r.x <= 2 and x - r.x <= r.right() - 1 - x;
    const near_right = r.right() - 1 - x <= 2 and !near_left;
    const near_top = y - r.y <= 1 and y - r.y <= r.bottom() - 1 - y;
    const near_bottom = r.bottom() - 1 - y <= 1 and !near_top;
    if (near_top and near_left) return .top_left;
    if (near_top and near_right) return .top_right;
    if (near_bottom and near_left) return .bottom_left;
    if (near_bottom and near_right) return .bottom_right;
    if (x == r.x) return .left;
    if (x == r.right() - 1) return .right;
    return if (y == r.y) .top else .bottom;
}
pub fn adjust(r: core.Rect, edge: Edge, dx: i32, dy: i32, area: core.Rect) core.Rect {
    var next = r;
    const min_w = @min(8, r.w);
    const min_h = @min(3, r.h);
    switch (edge) {
        .left => {
            next.x = std.math.clamp(r.x + dx, area.x, r.right() - min_w);
            next.w = r.right() - next.x;
        },
        .right => next.w = std.math.clamp(r.w + dx, min_w, area.right() - r.x),
        .top => {
            next.y = std.math.clamp(r.y + dy, area.y, r.bottom() - min_h);
            next.h = r.bottom() - next.y;
        },
        .bottom => next.h = std.math.clamp(r.h + dy, min_h, area.bottom() - r.y),
        .top_left => return adjust(adjust(r, .left, dx, 0, area), .top, 0, dy, area),
        .top_right => return adjust(adjust(r, .right, dx, 0, area), .top, 0, dy, area),
        .bottom_left => return adjust(adjust(r, .left, dx, 0, area), .bottom, 0, dy, area),
        .bottom_right => {
            next.w = std.math.clamp(r.w + dx, min_w, area.right() - r.x);
            next.h = std.math.clamp(r.h + dy, min_h, area.bottom() - r.y);
        },
        .move => {
            next.x += dx;
            next.y += dy;
        },
        .divider, .tile_vertical, .tile_horizontal => {},
    }
    return next;
}
fn borderCell(scene: *const core.Scene, x: i32, y: i32) bool {
    const id = scene.hitTest(x, y) orelse return false;
    const window = scene.get(id).?;
    return window.options.kind != .floating and hasBorder(window.bounds) and !contentFor(scene, id).contains(x, y);
}
fn joinedGlyph(scene: *const core.Scene, x: i32, y: i32) []const u8 {
    const mask: u4 = @as(u4, @intFromBool(borderCell(scene, x - 1, y))) |
        (@as(u4, @intFromBool(borderCell(scene, x + 1, y))) << 1) |
        (@as(u4, @intFromBool(borderCell(scene, x, y - 1))) << 2) |
        (@as(u4, @intFromBool(borderCell(scene, x, y + 1))) << 3);
    return switch (mask) {
        3, 1, 2 => "─",
        12, 4, 8 => "│",
        10 => "┌",
        9 => "┐",
        6 => "└",
        5 => "┘",
        11 => "┬",
        7 => "┴",
        14 => "├",
        13 => "┤",
        15 => "┼",
        else => "·",
    };
}
pub fn draw(w: *std.Io.Writer, scene: *const core.Scene, id: core.Id, hover: ?Edge) !void {
    const window = scene.get(id).?;
    const r = window.bounds;
    if (!window.visible or !hasBorder(r)) return;
    var last_color: ?u8 = null;
    var last_rgb: ?RGB = null;
    const shared_left = sharesLeft(scene, id);
    const shared_top = sharesTop(scene, id);
    var y = r.y;
    while (y < r.bottom()) : (y += 1) {
        var x = r.x;
        var adjacent = false;
        while (x < r.right()) : (x += 1) {
            const top = y == r.y and !shared_top;
            const bottom = y == r.bottom() - 1;
            const left = x == r.x and !shared_left;
            const right = x == r.right() - 1;
            if ((!top and !bottom and !left and !right) or scene.hitTest(x, y) != id) {
                adjacent = false;
                continue;
            }
            const highlighted = hover != null and edgeAt(scene, id, x, y) == hover;
            const divider = window.options.kind == .docked and window.options.kind.docked.edge == .left and right and r.right() < scene.root.right();
            const shared_active = if (scene.focus) |focused| if (scene.get(focused)) |other|
                other.options.kind == .tiled and sharesLeft(scene, focused) and other.bounds.x == r.right()
            else
                false else false;
            const tile_shared_active = if (scene.focus) |focused| if (scene.get(focused)) |other|
                window.options.kind == .tiled and other.options.kind == .tiled and
                    ((right and other.bounds.x == r.right() and y >= other.bounds.y and y < other.bounds.bottom()) or
                        (bottom and other.bounds.y == r.bottom() and x >= other.bounds.x and x < other.bounds.right()))
            else
                false else false;
            const active = scene.focus == id or (divider and shared_active) or tile_shared_active;
            const color: u8 = if (active) (if (highlighted) 96 else 36) else (if (highlighted) 37 else 90);
            if (style == .aurora) {
                const color_bounds = if ((divider and shared_active) or tile_shared_active) scene.get(scene.focus.?).?.bounds else r;
                const rgb = borderColor(color_bounds, x, y, active, highlighted);
                if (last_rgb == null or !std.meta.eql(last_rgb.?, rgb)) {
                    try w.print("\x1b[0;38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b });
                    last_rgb = rgb;
                }
            } else if (last_color != color) {
                try w.print("\x1b[0;{d}m", .{color});
                last_color = color;
            }
            if (!adjacent) try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
            const glyph: []const u8 = if (window.options.kind != .floating) joinedGlyph(scene, x, y) else if (highlighted and top and left and hover == .top_left) "↖" else if (highlighted and top and right and hover == .top_right) "↗" else if (highlighted and bottom and left and hover == .bottom_left) "↙" else if (highlighted and bottom and right and hover == .bottom_right) "↘" else if (divider and top) "┬" else if (divider and bottom) "┴" else if (top and left) (if (style == .aurora) "╭" else "┌") else if (top and right) (if (style == .aurora) "╮" else "┐") else if (bottom and left) (if (style == .aurora) "╰" else "└") else if (bottom and right) (if (style == .aurora) "╯" else "┘") else if (top or bottom) "─" else "│";
            try w.writeAll(glyph);
            adjacent = true;
        }
    }
    try w.writeAll("\x1b[0m");
}

test "corner handles resize both edges and keep the opposite corner fixed" {
    const area = try core.Rect.init(0, 0, 100, 50);
    const r = try core.Rect.init(20, 10, 30, 20);
    try std.testing.expectEqual(try core.Rect.init(17, 8, 33, 22), adjust(r, .top_left, -3, -2, area));
    try std.testing.expectEqual(try core.Rect.init(20, 8, 33, 22), adjust(r, .top_right, 3, -2, area));
    try std.testing.expectEqual(try core.Rect.init(17, 10, 33, 22), adjust(r, .bottom_left, -3, 2, area));
    try std.testing.expectEqual(try core.Rect.init(20, 10, 33, 22), adjust(r, .bottom_right, 3, 2, area));
    try std.testing.expectEqual(try core.Rect.init(42, 27, 8, 3), adjust(r, .top_left, 100, 100, area));
    var scene = try core.Scene.init(area);
    const id = try scene.add(.{ .kind = .{ .floating = r } });
    try std.testing.expectEqual(Edge.top_left, edgeAt(&scene, id, 22, 10).?);
    try std.testing.expectEqual(Edge.bottom_right, edgeAt(&scene, id, 49, 28).?);
    try std.testing.expect(edgeAt(&scene, id, 21, 11) == null);
    try std.testing.expectEqual(Edge.top, edgeAt(&scene, id, 25, 10).?);
}
