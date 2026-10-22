//! Docking policy and previews operate on abstract rectangles, without PTYs.
const core = @import("compositor");
pub const Destination = struct {
    target: ?core.Id = null,
    edge: core.Edge,
    wall: bool = false,
    extent: i32 = 0,
    pub fn apply(self: Destination, scene: *core.Scene, id: core.Id) !void {
        if (self.wall) try scene.configure(id, .{ .kind = .{ .docked = .{ .edge = self.edge, .extent = self.extent } }, .always_on_top = true }) else try scene.placeTile(id, self.target, self.edge);
    }
    pub fn preview(self: Destination, scene: *const core.Scene, id: core.Id) !core.Rect {
        var copy = scene.*;
        try self.apply(&copy, id);
        return copy.get(id).?.bounds;
    }
};
fn nearEdge(r: core.Rect, x: i32, y: i32) ?core.Edge {
    if (!r.contains(x, y)) return null;
    const distances = [_]i32{ x - r.x, r.right() - 1 - x, (y - r.y) * 2, (r.bottom() - 1 - y) * 2 };
    var best: usize = 0;
    for (distances, 0..) |distance, i| if (distance < distances[best]) {
        best = i;
    };
    if (distances[best] > 2) return null;
    return ([_]core.Edge{ .left, .right, .top, .bottom })[best];
}
// Broad directional zones within a tile. Normalize by its dimensions so a
// wide/short window still has usable top and bottom targets. Keep a central
// resting area for floating placement without accidentally docking.
fn tileZone(r: core.Rect, x: i32, y: i32) ?core.Edge {
    if (r.empty() or !r.contains(x, y)) return null;
    const nx = @divTrunc(@as(i64, x - r.x) * 1000, r.w);
    const ny = @divTrunc(@as(i64, y - r.y) * 1000, r.h);
    if (nx >= 300 and nx <= 700 and ny >= 300 and ny <= 700) return null;
    const distances = [_]i64{ nx, 1000 - nx, ny, 1000 - ny };
    var best: usize = 0;
    for (distances, 0..) |distance, index| if (distance < distances[best]) {
        best = index;
    };
    return ([_]core.Edge{ .left, .right, .top, .bottom })[best];
}
pub fn pick(scene: *const core.Scene, id: core.Id, x: i32, y: i32, wall: bool) ?Destination {
    if (nearEdge(scene.usable, x, y)) |edge| {
        const horizontal = edge == .left or edge == .right;
        const available = if (horizontal) scene.usable.w else scene.usable.h;
        if (available < 6) return null;
        return .{ .edge = edge, .wall = wall, .extent = @max(3, @divTrunc(available, 3)) };
    }
    if (wall) return null;
    for (scene.windows) |maybe| if (maybe) |window| {
        if (window.id == id or !window.visible or window.options.kind != .tiled) continue;
        if (tileZone(window.bounds, x, y)) |edge| {
            if ((edge == .left or edge == .right) and window.bounds.w < 6) return null;
            if ((edge == .top or edge == .bottom) and window.bounds.h < 6) return null;
            return .{ .target = window.id, .edge = edge };
        }
    };
    return null;
}

test "preview matches committed geometry without mutating the scene" {
    const std = @import("std");
    var scene = try core.Scene.init(try core.Rect.init(0, 0, 80, 24));
    _ = try scene.add(.{ .kind = .tiled });
    const id = try scene.add(.{ .kind = .{ .floating = try core.Rect.init(10, 4, 30, 12) } });
    const original = scene.get(id).?.bounds;
    for ([_]bool{ false, true }) |wall| {
        var copy = scene;
        const dest = pick(&copy, id, 0, 12, wall).?;
        const preview = try dest.preview(&copy, id);
        try std.testing.expectEqual(original, copy.get(id).?.bounds);
        try dest.apply(&copy, id);
        try std.testing.expectEqual(preview, copy.get(id).?.bounds);
    }
    try std.testing.expect(pick(&scene, id, 40, 12, false) == null);
}

test "first edge drop occupies the selected half and follows root resizing" {
    const std = @import("std");
    const edges = [_]core.Edge{ .left, .right, .top, .bottom };
    const expected = [_]core.Rect{
        try core.Rect.init(0, 0, 40, 24),
        try core.Rect.init(40, 0, 40, 24),
        try core.Rect.init(0, 0, 80, 12),
        try core.Rect.init(0, 12, 80, 12),
    };
    for (edges, expected) |edge, bounds| {
        var scene = try core.Scene.init(try core.Rect.init(0, 0, 80, 24));
        const id = try scene.add(.{ .kind = .{ .floating = try core.Rect.init(10, 4, 30, 12) } });
        const dest: Destination = .{ .edge = edge };
        try std.testing.expectEqual(bounds, try dest.preview(&scene, id));
        try dest.apply(&scene, id);
        try std.testing.expectEqual(bounds, scene.get(id).?.bounds);
        try scene.resizeRoot(try core.Rect.init(0, 0, 160, 48));
        try std.testing.expectEqual(try core.Rect.init(bounds.x * 2, bounds.y * 2, bounds.w * 2, bounds.h * 2), scene.get(id).?.bounds);
        try scene.configure(id, .{ .kind = .{ .floating = bounds } });
        const tile = try scene.add(.{ .kind = .tiled });
        try std.testing.expectEqual(scene.usable, scene.get(tile).?.bounds);
    }
}

test "broad tile zones split locally while workspace edges split globally" {
    const std = @import("std");
    var scene = try core.Scene.init(try core.Rect.init(0, 0, 160, 60));
    const left = try scene.add(.{ .kind = .tiled });
    const right = try scene.splitTile(left, .horizontal, 5000, .{ .kind = .tiled });
    const id = try scene.add(.{ .kind = .{ .floating = try core.Rect.init(40, 10, 60, 30) } });
    const points = [_][2]i32{ .{ 100, 30 }, .{ 140, 30 }, .{ 120, 15 }, .{ 120, 45 } };
    for (points, [_]core.Edge{ .left, .right, .top, .bottom }) |point, edge| {
        const dest = pick(&scene, id, point[0], point[1], false).?;
        try std.testing.expectEqual(right, dest.target.?);
        try std.testing.expectEqual(edge, dest.edge);
        var copy = scene;
        try dest.apply(&copy, id);
        try std.testing.expectEqual(scene.get(left).?.bounds, copy.get(left).?.bounds);
    }
    const global = pick(&scene, id, 159, 30, false).?;
    try std.testing.expect(global.target == null);
    try std.testing.expectEqual(core.Edge.right, global.edge);
    try std.testing.expect(pick(&scene, id, 120, 30, false) == null);
    try std.testing.expect(pick(&scene, id, 100, 30, true) == null);
}
