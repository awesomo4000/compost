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
        if (nearEdge(window.bounds, x, y)) |edge| {
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
