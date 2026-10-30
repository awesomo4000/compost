//! Procedural title art and a bounded entrance/exit animation. No image assets.
const std = @import("std");
const core = @import("compositor");
const Color = [3]u8;
const background: Color = .{ 18, 20, 23 };
const ink: Color = .{ 3, 16, 31 };
const Point = struct { x: f32, y: f32 };
const Box = struct { x0: f32, y0: f32, x1: f32, y1: f32, color: Color };
// Geometry and palette ported from the supplied x/ansi-art/compo.py.
const tiles = [_]Box{
    .{ .x0 = 5, .y0 = 7, .x1 = 47, .y1 = 26, .color = .{ 8, 123, 232 } },
    .{ .x0 = 5, .y0 = 43, .x1 = 47, .y1 = 213, .color = .{ 9, 191, 233 } },
    .{ .x0 = 67, .y0 = 7, .x1 = 382, .y1 = 213, .color = .{ 7, 142, 255 } },
    .{ .x0 = 401, .y0 = 7, .x1 = 647, .y1 = 94, .color = .{ 7, 159, 233 } },
    .{ .x0 = 667, .y0 = 6, .x1 = 1404, .y1 = 94, .color = .{ 89, 220, 215 } },
    .{ .x0 = 1424, .y0 = 6, .x1 = 1679, .y1 = 94, .color = .{ 28, 112, 250 } },
    .{ .x0 = 1698, .y0 = 5, .x1 = 2048, .y1 = 169, .color = .{ 149, 102, 247 } },
    .{ .x0 = 401, .y0 = 115, .x1 = 747, .y1 = 341, .color = .{ 40, 207, 238 } },
    .{ .x0 = 767, .y0 = 115, .x1 = 1028, .y1 = 213, .color = .{ 9, 139, 212 } },
    .{ .x0 = 1047, .y0 = 115, .x1 = 1254, .y1 = 213, .color = .{ 133, 157, 247 } },
    .{ .x0 = 1273, .y0 = 115, .x1 = 1483, .y1 = 325, .color = .{ 16, 158, 238 } },
    .{ .x0 = 1502, .y0 = 115, .x1 = 1679, .y1 = 325, .color = .{ 25, 60, 175 } },
    .{ .x0 = 1698, .y0 = 188, .x1 = 1948, .y1 = 351, .color = .{ 63, 181, 203 } },
    .{ .x0 = 1968, .y0 = 189, .x1 = 2048, .y1 = 436, .color = .{ 57, 48, 148 } },
    .{ .x0 = 5, .y0 = 233, .x1 = 223, .y1 = 341, .color = .{ 16, 192, 236 } },
    .{ .x0 = 243, .y0 = 233, .x1 = 382, .y1 = 341, .color = .{ 0, 103, 239 } },
    .{ .x0 = 767, .y0 = 233, .x1 = 1146, .y1 = 436, .color = .{ 101, 223, 215 } },
    .{ .x0 = 1167, .y0 = 233, .x1 = 1254, .y1 = 325, .color = .{ 7, 88, 191 } },
    .{ .x0 = 5, .y0 = 361, .x1 = 223, .y1 = 550, .color = .{ 10, 92, 183 } },
    .{ .x0 = 243, .y0 = 361, .x1 = 480, .y1 = 550, .color = .{ 27, 165, 238 } },
    .{ .x0 = 499, .y0 = 361, .x1 = 747, .y1 = 437, .color = .{ 24, 193, 239 } },
    .{ .x0 = 1167, .y0 = 344, .x1 = 1577, .y1 = 546, .color = .{ 146, 158, 249 } },
    .{ .x0 = 1597, .y0 = 344, .x1 = 1679, .y1 = 353, .color = .{ 23, 75, 168 } },
    .{ .x0 = 1597, .y0 = 372, .x1 = 1948, .y1 = 436, .color = .{ 68, 210, 208 } },
    .{ .x0 = 499, .y0 = 456, .x1 = 838, .y1 = 551, .color = .{ 4, 84, 202 } },
    .{ .x0 = 858, .y0 = 456, .x1 = 1060, .y1 = 673, .color = .{ 62, 208, 207 } },
    .{ .x0 = 1079, .y0 = 456, .x1 = 1146, .y1 = 546, .color = .{ 24, 155, 243 } },
    .{ .x0 = 1597, .y0 = 456, .x1 = 1949, .y1 = 673, .color = .{ 177, 107, 246 } },
    .{ .x0 = 1969, .y0 = 456, .x1 = 2039, .y1 = 673, .color = .{ 141, 112, 249 } },
    .{ .x0 = 5, .y0 = 569, .x1 = 706, .y1 = 673, .color = .{ 7, 140, 255 } },
    .{ .x0 = 726, .y0 = 571, .x1 = 838, .y1 = 673, .color = .{ 8, 188, 238 } },
    .{ .x0 = 1079, .y0 = 566, .x1 = 1404, .y1 = 673, .color = .{ 49, 143, 245 } },
    .{ .x0 = 1424, .y0 = 566, .x1 = 1577, .y1 = 673, .color = .{ 45, 93, 242 } },
};
const glyphs = [_][]const Point{
    &.{ .{ .x = 187, .y = 48 }, .{ .x = 284, .y = 48 }, .{ .x = 284, .y = 85 }, .{ .x = 213, .y = 85 }, .{ .x = 213, .y = 141 }, .{ .x = 284, .y = 141 }, .{ .x = 284, .y = 177 }, .{ .x = 187, .y = 177 }, .{ .x = 187, .y = 169 }, .{ .x = 178, .y = 169 }, .{ .x = 178, .y = 160 }, .{ .x = 169, .y = 160 }, .{ .x = 169, .y = 66 }, .{ .x = 178, .y = 66 }, .{ .x = 178, .y = 57 }, .{ .x = 187, .y = 57 } },
    &.{ .{ .x = 525, .y = 157 }, .{ .x = 618, .y = 157 }, .{ .x = 618, .y = 165 }, .{ .x = 627, .y = 165 }, .{ .x = 627, .y = 174 }, .{ .x = 637, .y = 174 }, .{ .x = 637, .y = 278 }, .{ .x = 627, .y = 278 }, .{ .x = 627, .y = 287 }, .{ .x = 618, .y = 287 }, .{ .x = 618, .y = 296 }, .{ .x = 525, .y = 296 }, .{ .x = 525, .y = 287 }, .{ .x = 515, .y = 287 }, .{ .x = 515, .y = 278 }, .{ .x = 506, .y = 278 }, .{ .x = 506, .y = 175 }, .{ .x = 515, .y = 175 }, .{ .x = 515, .y = 166 }, .{ .x = 525, .y = 166 } },
    &.{ .{ .x = 872, .y = 278 }, .{ .x = 951, .y = 278 }, .{ .x = 951, .y = 285 }, .{ .x = 961, .y = 285 }, .{ .x = 961, .y = 292 }, .{ .x = 974, .y = 278 }, .{ .x = 1020, .y = 278 }, .{ .x = 1020, .y = 286 }, .{ .x = 1030, .y = 286 }, .{ .x = 1030, .y = 295 }, .{ .x = 1039, .y = 295 }, .{ .x = 1039, .y = 397 }, .{ .x = 994, .y = 397 }, .{ .x = 994, .y = 315 }, .{ .x = 974, .y = 315 }, .{ .x = 974, .y = 397 }, .{ .x = 932, .y = 397 }, .{ .x = 932, .y = 315 }, .{ .x = 914, .y = 315 }, .{ .x = 914, .y = 397 }, .{ .x = 872, .y = 397 } },
    &.{ .{ .x = 1308, .y = 383 }, .{ .x = 1417, .y = 383 }, .{ .x = 1417, .y = 391 }, .{ .x = 1427, .y = 391 }, .{ .x = 1427, .y = 401 }, .{ .x = 1435, .y = 401 }, .{ .x = 1435, .y = 471 }, .{ .x = 1427, .y = 471 }, .{ .x = 1427, .y = 480 }, .{ .x = 1417, .y = 480 }, .{ .x = 1417, .y = 487 }, .{ .x = 1350, .y = 487 }, .{ .x = 1350, .y = 522 }, .{ .x = 1308, .y = 522 } },
    &.{ .{ .x = 1729, .y = 499 }, .{ .x = 1822, .y = 499 }, .{ .x = 1822, .y = 507 }, .{ .x = 1832, .y = 507 }, .{ .x = 1832, .y = 516 }, .{ .x = 1840, .y = 516 }, .{ .x = 1840, .y = 615 }, .{ .x = 1832, .y = 615 }, .{ .x = 1832, .y = 624 }, .{ .x = 1822, .y = 624 }, .{ .x = 1822, .y = 633 }, .{ .x = 1729, .y = 633 }, .{ .x = 1729, .y = 624 }, .{ .x = 1719, .y = 624 }, .{ .x = 1719, .y = 615 }, .{ .x = 1711, .y = 615 }, .{ .x = 1711, .y = 516 }, .{ .x = 1719, .y = 516 }, .{ .x = 1719, .y = 507 }, .{ .x = 1729, .y = 507 } },
};
const glyph_tiles = [_]usize{ 2, 7, 16, 21, 27 };
const counters = [_]Box{
    .{ .x0 = 914, .y0 = 315, .x1 = 932, .y1 = 397, .color = .{ 101, 223, 215 } },
    .{ .x0 = 974, .y0 = 315, .x1 = 994, .y1 = 397, .color = .{ 101, 223, 215 } },
    .{ .x0 = 550, .y0 = 195, .x1 = 592, .y1 = 258, .color = .{ 40, 207, 238 } },
    .{ .x0 = 1350, .y0 = 418, .x1 = 1391, .y1 = 452, .color = .{ 146, 158, 249 } },
    .{ .x0 = 1755, .y0 = 535, .x1 = 1797, .y1 = 595, .color = .{ 177, 107, 246 } },
};
const counter_tiles = [_]usize{ 16, 16, 7, 21, 27 };

pub const Frame = struct { alpha: u8, scatter: f32 };
pub const Animator = struct {
    phase: enum { entering, held, leaving, hidden } = .entering,
    since: ?u64 = null,
    exit_from: Frame = .{ .alpha = 255, .scatter = 0 },
    pub fn active(self: Animator) bool {
        return self.phase != .hidden;
    }
    pub fn dismiss(self: *Animator, now: u64) void {
        if (self.phase == .leaving or self.phase == .hidden) return;
        self.exit_from = self.frame(now);
        self.phase = .leaving;
        self.since = now;
    }
    pub fn frame(self: *Animator, now: u64) Frame {
        if (self.since == null) self.since = now;
        const elapsed = now -| self.since.?;
        switch (self.phase) {
            .entering => {
                const t = @as(f32, @floatFromInt(@min(elapsed, 700))) / 700;
                const rest = (1 - t) * (1 - t) * (1 - t);
                if (elapsed >= 700) self.phase = .held;
                return .{ .alpha = @intFromFloat((1 - rest) * 255), .scatter = rest };
            },
            .leaving => {
                const t = @as(f32, @floatFromInt(@min(elapsed, 280))) / 280;
                if (elapsed >= 280) self.phase = .hidden;
                return .{ .alpha = @intFromFloat(@as(f32, @floatFromInt(self.exit_from.alpha)) * (1 - t)), .scatter = self.exit_from.scatter + t * t };
            },
            .held => return .{ .alpha = 255, .scatter = 0 },
            .hidden => return .{ .alpha = 0, .scatter = 1 },
        }
    }
};
const Size = struct { width: i32, rows: i32 };
const sizes = [_]Size{ .{ .width = 96, .rows = 16 }, .{ .width = 80, .rows = 13 }, .{ .width = 64, .rows = 11 } };
fn choose(root: core.Rect) ?Size {
    for (sizes) |s| if (root.w >= s.width + 6 and root.h >= s.rows + 6) return s;
    return null;
}
pub fn bounds(root: core.Rect) core.Rect {
    const s = choose(root) orelse Size{ .width = @min(root.w, 5), .rows = @min(root.h, 1) };
    const framed = root.w >= s.width + 6 and root.h >= s.rows + 6;
    const width = s.width + @as(i32, if (framed) 6 else 0);
    const height = s.rows + @as(i32, if (framed) 6 else 0);
    return .{ .x = root.x + @divTrunc(root.w - width, 2), .y = root.y + @divTrunc(root.h - height, 2), .w = width, .h = height };
}
fn offset(index: usize, scatter: f32) Point {
    return .{ .x = @as(f32, @floatFromInt(@as(i32, @intCast(index % 7)) - 3)) * 65 * scatter, .y = @as(f32, @floatFromInt(@as(i32, @intCast(index % 5)) - 2)) * 42 * scatter };
}
fn rounded(v: f32) i32 {
    const floor = @floor(v);
    const n: i32 = @intFromFloat(floor);
    return if (v - floor > 0.5 or (v - floor == 0.5 and @mod(n, 2) != 0)) n + 1 else n;
}
fn inside(x: f32, y: f32, polygon: []const Point) bool {
    var hit = false;
    var previous = polygon[polygon.len - 1];
    for (polygon) |current| {
        if ((current.y > y) != (previous.y > y) and x < (previous.x - current.x) * (y - current.y) / (previous.y - current.y) + current.x) hit = !hit;
        previous = current;
    }
    return hit;
}
const Raster = struct {
    width: usize,
    rows: usize,
    pixels: [96 * 32]Color = @splat(ink),
    fn rectangle(self: *Raster, box: Box, delta: Point) void {
        const width: f32 = @floatFromInt(self.width);
        const height: f32 = @floatFromInt(self.rows * 2);
        const left = rounded((box.x0 + delta.x) * width / 2048);
        const top = rounded((box.y0 + delta.y) * height / 679);
        const right = @max(left + 1, rounded((box.x1 + delta.x) * width / 2048));
        const bottom = @max(top + 1, rounded((box.y1 + delta.y) * height / 679));
        const x0: usize = @intCast(std.math.clamp(left, 0, @as(i32, @intCast(self.width))));
        const x1: usize = @intCast(std.math.clamp(right, 0, @as(i32, @intCast(self.width))));
        const y0: usize = @intCast(std.math.clamp(top, 0, @as(i32, @intCast(self.rows * 2))));
        const y1: usize = @intCast(std.math.clamp(bottom, 0, @as(i32, @intCast(self.rows * 2))));
        for (y0..y1) |y| for (x0..x1) |x| {
            self.pixels[y * self.width + x] = box.color;
        };
    }
    // Snap the whole letter before sampling so its top and bottom mirror even
    // on a four-column terminal glyph. The c keeps its right side open.
    fn roundedLetter(self: *Raster, box: Box, delta: Point, kind: enum { c, o }) void {
        const left = rounded((box.x0 + delta.x) * @as(f32, @floatFromInt(self.width)) / 2048);
        const right = rounded((box.x1 + delta.x) * @as(f32, @floatFromInt(self.width)) / 2048);
        const top = rounded((box.y0 + delta.y) * @as(f32, @floatFromInt(self.rows * 2)) / 679);
        const bottom = rounded((box.y1 + delta.y) * @as(f32, @floatFromInt(self.rows * 2)) / 679);
        var y = top;
        while (y < bottom) : (y += 1) {
            var x = left;
            while (x < right) : (x += 1) {
                if (x < 0 or y < 0 or x >= self.width or y >= self.rows * 2) continue;
                const nx = @as(f32, @floatFromInt(2 * (x - left) + 1 - (right - left))) / @as(f32, @floatFromInt(right - left));
                const ny = @as(f32, @floatFromInt(2 * (y - top) + 1 - (bottom - top))) / @as(f32, @floatFromInt(bottom - top));
                const edge_x = if (kind == .c) @min(nx, 0) else nx;
                const outer = edge_x * edge_x + ny * ny <= 1;
                const hole = if (kind == .c) nx >= -0.25 and @abs(ny) < 0.45 else nx * nx / (0.38 * 0.38) + ny * ny / (0.56 * 0.56) <= 1;
                self.pixels[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))] = if (outer and !hole) ink else box.color;
            }
        }
    }
    fn render(s: Size, scatter: f32) Raster {
        var result: Raster = .{ .width = @intCast(s.width), .rows = @intCast(s.rows) };
        for (tiles, 0..) |box, i| result.rectangle(box, offset(i, scatter));
        for (0..result.rows * 2) |y| for (0..result.width) |x| {
            const sx = (@as(f32, @floatFromInt(x)) + 0.5) * 2048 / @as(f32, @floatFromInt(result.width));
            const sy = (@as(f32, @floatFromInt(y)) + 0.5) * 679 / @as(f32, @floatFromInt(result.rows * 2));
            for (glyphs, glyph_tiles) |shape, tile| {
                if (tile == 2 or tile == 7 or tile == 27) continue;
                const d = offset(tile, scatter);
                if (inside(sx - d.x, sy - d.y, shape)) result.pixels[y * result.width + x] = ink;
            }
        };
        for (counters, counter_tiles) |box, tile| {
            if (tile != 7 and tile != 27) result.rectangle(box, offset(tile, scatter));
        }
        result.roundedLetter(.{ .x0 = 506, .y0 = 157, .x1 = 638, .y1 = 297, .color = tiles[7].color }, offset(7, scatter), .o);
        result.roundedLetter(.{ .x0 = 1710, .y0 = 499, .x1 = 1842, .y1 = 639, .color = tiles[27].color }, offset(27, scatter), .o);
        result.roundedLetter(.{ .x0 = 169, .y0 = 48, .x1 = 284, .y1 = 178, .color = tiles[2].color }, offset(2, scatter), .c);
        if (s.width < 90) {
            const d = offset(16, scatter);
            const left = rounded((872 + d.x) * @as(f32, @floatFromInt(s.width)) / 2048);
            const top = rounded((278 + d.y) * @as(f32, @floatFromInt(s.rows * 2)) / 679);
            const bottom = rounded((397 + d.y) * @as(f32, @floatFromInt(s.rows * 2)) / 679);
            var y = top;
            while (y < bottom) : (y += 1) for (0..5) |dx| {
                const x = left + @as(i32, @intCast(dx));
                if (x >= 0 and x < s.width and y >= 0 and y < s.rows * 2)
                    result.pixels[@as(usize, @intCast(y)) * result.width + @as(usize, @intCast(x))] = if (y == top or dx % 2 == 0) ink else .{ 101, 223, 215 };
            };
        }
        return result;
    }
};
fn blend(color: Color, alpha: u8) Color {
    var out: Color = undefined;
    for (color, background, &out) |c, b, *v| v.* = @intCast((@as(u32, c) * alpha + @as(u32, b) * (255 - @as(u32, alpha))) / 255);
    return out;
}
fn colors(w: *std.Io.Writer, fg: Color, bg: Color) !void {
    try w.print("\x1b[38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{ fg[0], fg[1], fg[2], bg[0], bg[1], bg[2] });
}
fn move(w: *std.Io.Writer, x: i32, y: i32) !void {
    try w.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
}
/// The caller clears on geometry changes. Each frame repaints the same bounded panel.
pub fn draw(w: *std.Io.Writer, root: core.Rect, frame: Frame) !void {
    const alpha = frame.alpha;
    if (root.w < 5 or root.h < 1) return;
    const chosen = choose(root);
    const art_w = if (chosen) |a| a.width else 5;
    const art_h = if (chosen) |a| a.rows else 1;
    const framed = root.w >= art_w + 6 and root.h >= art_h + 6;
    const width = art_w + @as(i32, if (framed) 6 else 0);
    const height = art_h + @as(i32, if (framed) 6 else 0);
    const x = root.x + @divTrunc(root.w - width, 2);
    const y = root.y + @divTrunc(root.h - height, 2);
    const bg = blend(ink, alpha);
    const border = blend(.{ 48, 74, 87 }, alpha);
    for (0..@intCast(height)) |row| {
        try move(w, x, y + @as(i32, @intCast(row)));
        try colors(w, border, bg);
        if (framed and (row == 0 or row == height - 1)) {
            try w.writeAll(if (row == 0) "╭" else "╰");
            for (0..@intCast(width - 2)) |_| try w.writeAll("─");
            try w.writeAll(if (row == 0) "╮" else "╯");
        } else {
            if (framed) try w.writeAll("│");
            try w.splatByteAll(' ', @intCast(width - @as(i32, if (framed) 2 else 0)));
            if (framed) try w.writeAll("│");
        }
    }
    const ax = x + @as(i32, if (framed) 3 else 0);
    const ay = y + @as(i32, if (framed) 3 else 0);
    if (chosen) |asset| {
        const raster = Raster.render(asset, frame.scatter);
        const stride: usize = @intCast(asset.width);
        for (0..@intCast(asset.rows)) |row| {
            try move(w, ax, ay + @as(i32, @intCast(row)));
            var previous: ?[2]Color = null;
            for (0..@intCast(asset.width)) |col| {
                const top = (row * 2) * stride + col;
                const bottom = top + stride;
                const pair = [2]Color{ blend(raster.pixels[top], alpha), blend(raster.pixels[bottom], alpha) };
                if (previous == null or !std.meta.eql(previous.?, pair)) try colors(w, pair[0], pair[1]);
                try w.writeAll("▀");
                previous = pair;
            }
        }
    } else {
        try move(w, ax, ay);
        try colors(w, blend(.{ 89, 220, 215 }, alpha), bg);
        try w.writeAll("compo");
    }
    try w.writeAll("\x1b[0m");
}

test "title animation settles and dismissal stays bounded" {
    var animation: Animator = .{};
    try std.testing.expectEqual(@as(u8, 0), animation.frame(0).alpha);
    try std.testing.expectEqual(@as(u8, 255), animation.frame(700).alpha);
    try std.testing.expectEqual(@as(f32, 0), animation.frame(900).scatter);
    animation.dismiss(1000);
    try std.testing.expect(animation.frame(1100).scatter > 0);
    _ = animation.frame(1280);
    try std.testing.expect(!animation.active());
}

test "rounded letters mirror their corners and counters at every supported size" {
    for (sizes) |size| {
        for ([_]Box{
            .{ .x0 = 506, .y0 = 157, .x1 = 638, .y1 = 297, .color = tiles[7].color },
            .{ .x0 = 1710, .y0 = 499, .x1 = 1842, .y1 = 639, .color = tiles[27].color },
            .{ .x0 = 169, .y0 = 48, .x1 = 284, .y1 = 178, .color = tiles[2].color },
        }, 0..) |box, index| {
            const raster = Raster.render(size, 0);
            const left: usize = @intCast(rounded(box.x0 * @as(f32, @floatFromInt(size.width)) / 2048));
            const right: usize = @intCast(rounded(box.x1 * @as(f32, @floatFromInt(size.width)) / 2048));
            const top: usize = @intCast(rounded(box.y0 * @as(f32, @floatFromInt(size.rows * 2)) / 679));
            const bottom: usize = @intCast(rounded(box.y1 * @as(f32, @floatFromInt(size.rows * 2)) / 679));
            for (top..bottom) |y| for (left..right) |x| {
                if (index < 2) try std.testing.expectEqual(raster.pixels[y * raster.width + x], raster.pixels[y * raster.width + left + right - 1 - x]);
                try std.testing.expectEqual(raster.pixels[y * raster.width + x], raster.pixels[(top + bottom - 1 - y) * raster.width + x]);
            };
            try std.testing.expectEqual(box.color, raster.pixels[top * raster.width + left]);
        }
        for ([_]f32{ 0.2, 0.5, 1.0, 1.9 }) |scatter| _ = Raster.render(size, scatter);
    }
}
