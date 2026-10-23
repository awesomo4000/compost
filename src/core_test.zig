const std = @import("std");
const core = @import("core.zig");
const Rect = core.Rect;
const Scene = core.Scene;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;

fn rect(x: i32, y: i32, w: i32, h: i32) Rect {
    return Rect.init(x, y, w, h) catch unreachable;
}

test "dock ordering assigns corners; raising does not change reservation" {
    var scene = try Scene.init(rect(-10, -5, 101, 51));
    const left = try scene.add(.{ .kind = .{ .docked = .{ .edge = .left, .extent = 20 } }, .always_on_top = true });
    const top = try scene.add(.{ .kind = .{ .docked = .{ .edge = .top, .extent = 7 } }, .always_on_top = true });
    const tile = try scene.add(.{ .kind = .tiled });
    try equal(rect(-10, -5, 20, 51), scene.get(left).?.bounds);
    try equal(rect(10, -5, 81, 7), scene.get(top).?.bounds);
    try equal(rect(10, 2, 81, 44), scene.get(tile).?.bounds);
    try scene.raise(left);
    try scene.resizeRoot(scene.root);
    try equal(rect(10, 2, 81, 44), scene.usable);
    try scene.remove(left);
    const right = try scene.add(.{ .kind = .{ .docked = .{ .edge = .right, .extent = 9 } } });
    // Reusing the left dock's slot must not move the new dock ahead of the top.
    try equal(rect(-10, -5, 101, 7), scene.get(top).?.bounds);
    try equal(rect(82, 2, 9, 44), scene.get(right).?.bounds);
}

test "nested tiles partition odd dimensions and removal collapses branches" {
    var scene = try Scene.init(rect(0, 0, 101, 51));
    const a = try scene.add(.{ .kind = .tiled });
    const b = try scene.splitTile(a, .horizontal, 3333, .{ .kind = .tiled });
    const c = try scene.splitTile(b, .vertical, 5000, .{ .kind = .tiled });
    try equal(rect(0, 0, 33, 51), scene.get(a).?.bounds);
    try equal(rect(33, 0, 68, 25), scene.get(b).?.bounds);
    try equal(rect(33, 25, 68, 26), scene.get(c).?.bounds);
    try scene.setVisible(b, false);
    try equal(rect(33, 0, 68, 51), scene.get(c).?.bounds);
    try scene.remove(a);
    try equal(scene.root, scene.get(c).?.bounds);
    try scene.remove(b);
    try scene.remove(c);
    try equal(@as(?usize, null), scene.tree);
    const d = try scene.add(.{ .kind = .tiled });
    try expect(d > c);
    try equal(scene.root, scene.get(d).?.bounds);
}

test "floats cross reserved walls and shrink only with root; minimum failures are explicit" {
    var scene = try Scene.init(rect(0, 0, 100, 50));
    const wall = try scene.add(.{ .kind = .{ .docked = .{ .edge = .left, .extent = 20 } }, .always_on_top = true });
    const floating = try scene.add(.{ .kind = .{ .floating = rect(-100, 40, 60, 30) }, .min_width = 40 });
    try equal(rect(0, 20, 60, 30), scene.get(floating).?.bounds);
    try scene.moveResize(floating, rect(99, -99, 60, 30));
    try equal(rect(40, 0, 60, 30), scene.get(floating).?.bounds);
    try scene.setFocus(floating);
    try scene.capturePointer(floating);
    try scene.resizeRoot(rect(0, 0, 10, 5));
    try expect(scene.get(wall).?.constraints_unmet);
    try expect(scene.get(floating).?.constraints_unmet);
    try equal(rect(0, 0, 10, 5), scene.get(floating).?.bounds);
    try equal(@as(?core.Id, floating), scene.focus);
    try equal(@as(?core.Id, floating), scene.capture);
    try scene.resizeRoot(rect(0, 0, 100, 50));
    try equal(rect(40, 0, 60, 30), scene.get(floating).?.bounds);
}

test "overlay stacking is independent of reservation and pointer capture" {
    var scene = try Scene.init(rect(0, 0, 30, 20));
    const tile = try scene.add(.{ .kind = .tiled });
    const overlay = try scene.add(.{ .kind = .{ .docked = .{ .edge = .top, .extent = 5, .reserves_space = false } }, .always_on_top = true });
    try equal(scene.root, scene.usable);
    try scene.raise(tile);
    try equal(@as(?core.Id, overlay), scene.hitTest(0, 0));
    try equal(@as(?core.Id, tile), scene.hitTest(0, 5));
    try equal(@as(?core.Id, null), scene.hitTest(30, 0));
    try scene.setFocus(tile);
    try scene.capturePointer(tile);
    try equal(@as(?core.Id, tile), scene.pointerTarget(-100, -100));
    try scene.setVisible(tile, false);
    try equal(@as(?core.Id, null), scene.focus);
    try equal(@as(?core.Id, overlay), scene.pointerTarget(0, 0));
    try scene.capturePointer(overlay);
    try scene.remove(overlay);
    try equal(@as(?core.Id, null), scene.capture);
}

fn verifyVisible(scene: *const Scene) !void {
    for (scene.windows) |maybe| if (maybe) |w| {
        var region = try scene.visibleRegion(std.testing.allocator, w.id);
        defer region.deinit(std.testing.allocator);
        var y = scene.root.y;
        while (y < scene.root.bottom()) : (y += 1) {
            var x = scene.root.x;
            while (x < scene.root.right()) : (x += 1) {
                var count: usize = 0;
                for (region.items) |piece| if (piece.contains(x, y)) {
                    count += 1;
                };
                try equal(@as(usize, if (scene.hitTest(x, y) == w.id) 1 else 0), count);
            }
        }
    };
}

test "visible regions agree with topmost hits through overlapping moves" {
    var scene = try Scene.init(rect(-3, -2, 23, 17));
    _ = try scene.add(.{ .kind = .tiled });
    _ = try scene.add(.{ .kind = .{ .docked = .{ .edge = .right, .extent = 3 } }, .always_on_top = true });
    const a = try scene.add(.{ .kind = .{ .floating = rect(0, 0, 10, 9) } });
    const b = try scene.add(.{ .kind = .{ .floating = rect(5, 3, 8, 8) } });
    _ = try scene.add(.{ .kind = .{ .docked = .{ .edge = .top, .extent = 2, .reserves_space = false } }, .always_on_top = true });
    var step: i32 = 0;
    while (step < 24) : (step += 1) {
        try scene.moveResize(a, rect(step - 8, 8 - step, 10, 9));
        if (@mod(step, 3) == 0) try scene.raise(a);
        if (@mod(step, 4) == 0) try scene.raise(b);
        try scene.setVisible(b, @mod(step, 5) != 0);
        try verifyVisible(&scene);
    }
}

test "bounds and capacity errors preserve existing windows" {
    try std.testing.expectError(error.InvalidBounds, Rect.init(0, 0, -1, 1));
    try std.testing.expectError(error.InvalidBounds, Rect.init(std.math.maxInt(i32), 0, 1, 1));
    var scene = try Scene.init(rect(0, 0, 1, 1));
    const first = try scene.add(.{ .kind = .tiled });
    try std.testing.expectError(error.InvalidSplit, scene.splitTile(first, .horizontal, 10001, .{ .kind = .tiled }));
    for (1..Scene.capacity) |_| _ = try scene.add(.{ .kind = .tiled });
    const revision = scene.revision;
    try std.testing.expectError(error.CapacityExceeded, scene.splitTile(first, .vertical, 5000, .{ .kind = .tiled }));
    try equal(revision, scene.revision);
    try scene.remove(first);
    const replacement = try scene.add(.{ .kind = .tiled });
    try expect(replacement > first);
    try std.testing.expectError(error.UnknownWindow, scene.setFocus(first));
    try verifyVisible(&scene);
}

test "presentation changes preserve identity and capture while relaying out neighbors" {
    var scene = try Scene.init(rect(0, 0, 100, 50));
    const a = try scene.add(.{ .kind = .tiled });
    const b = try scene.add(.{ .kind = .tiled });
    try scene.setFocus(a);
    try scene.capturePointer(a);
    try scene.configure(a, .{ .kind = .{ .docked = .{ .edge = .left, .extent = 20 } }, .always_on_top = true });
    try equal(rect(20, 0, 80, 50), scene.get(b).?.bounds);
    try scene.configure(a, .{ .kind = .{ .floating = rect(10, 10, 40, 20) } });
    try equal(scene.root, scene.get(b).?.bounds);
    try equal(@as(?core.Id, a), scene.focus);
    try equal(@as(?core.Id, a), scene.capture);
    try scene.configure(a, .{ .kind = .tiled });
    try equal(rect(50, 0, 50, 50), scene.get(a).?.bounds);
    try verifyVisible(&scene);
    const old = scene.get(a).?;
    try std.testing.expectError(error.InvalidBounds, scene.configure(a, .{ .kind = .{ .docked = .{ .edge = .left, .extent = -1 } } }));
    try equal(old, scene.get(a).?);
}

test "rectangle subtraction covers exactly the difference including negative origins" {
    const a = rect(-4, -3, 9, 8);
    var bx: i32 = -6;
    while (bx < 7) : (bx += 1) {
        var by: i32 = -5;
        while (by < 7) : (by += 1) {
            const b = rect(bx, by, 3, 4);
            var pieces: [4]Rect = undefined;
            const n = a.subtract(b, &pieces);
            var y: i32 = -6;
            while (y < 8) : (y += 1) {
                var x: i32 = -7;
                while (x < 8) : (x += 1) {
                    var count: usize = 0;
                    for (pieces[0..n]) |piece| if (piece.contains(x, y)) {
                        count += 1;
                    };
                    try equal(@as(usize, if (a.contains(x, y) and !b.contains(x, y)) 1 else 0), count);
                }
            }
        }
    }
}

test "docking existing windows splits only the target and preserves identities" {
    var scene = try Scene.init(rect(0, 0, 80, 24));
    const a = try scene.add(.{ .kind = .tiled });
    const b = try scene.add(.{ .kind = .{ .floating = rect(10, 4, 30, 12) } });
    const c = try scene.add(.{ .kind = .{ .floating = rect(12, 5, 30, 12) } });
    try scene.placeTile(b, null, .left);
    try equal(rect(0, 0, 40, 24), scene.get(b).?.bounds);
    try equal(rect(40, 0, 40, 24), scene.get(a).?.bounds);
    try scene.placeTile(c, b, .bottom);
    try equal(rect(0, 12, 40, 12), scene.get(c).?.bounds);
    try equal(rect(0, 0, 40, 12), scene.get(b).?.bounds);
    try equal(rect(40, 0, 40, 24), scene.get(a).?.bounds);
    const revision = scene.revision;
    try std.testing.expectError(error.InvalidSplit, scene.placeTile(b, b, .left));
    try equal(revision, scene.revision);
    try scene.configure(c, .{ .kind = .{ .floating = rect(10, 4, 30, 12) } });
    try equal(rect(0, 0, 40, 24), scene.get(b).?.bounds);
    try scene.placeTile(c, a, .right);
    try equal(rect(60, 0, 20, 24), scene.get(c).?.bounds);
}

test "divider resizing adjusts a nested split while preserving its sibling" {
    var scene = try Scene.init(rect(0, 0, 90, 30));
    const a = try scene.add(.{ .kind = .tiled });
    const b = try scene.splitTile(a, .horizontal, 5000, .{ .kind = .tiled });
    const c = try scene.splitTile(b, .vertical, 5000, .{ .kind = .tiled });
    const vertical = scene.dividerFor(a, .horizontal).?;
    try scene.resizeDivider(vertical, 30);
    try equal(rect(0, 0, 30, 30), scene.get(a).?.bounds);
    try equal(rect(30, 0, 60, 15), scene.get(b).?.bounds);
    const horizontal = scene.dividerFor(b, .vertical).?;
    try scene.resizeDivider(horizontal, 10);
    try equal(rect(30, 0, 60, 10), scene.get(b).?.bounds);
    try equal(rect(30, 10, 60, 20), scene.get(c).?.bounds);
    try equal(rect(0, 0, 30, 30), scene.get(a).?.bounds);
    try scene.resizeDivider(horizontal, -200);
    try equal(@as(i32, 3), scene.get(b).?.bounds.h);
    try scene.resizeDivider(horizontal, 200);
    try equal(@as(i32, 3), scene.get(c).?.bounds.h);
}

test "numeric layers dominate raise and always on top for hit testing and occlusion" {
    var scene = try core.Scene.init(try core.Rect.init(0, 0, 80, 24));
    const bounds = try core.Rect.init(4, 3, 30, 12);
    const low = try scene.add(.{ .kind = .{ .floating = bounds }, .layer = -100, .always_on_top = true });
    const high = try scene.add(.{ .kind = .{ .floating = bounds } });
    try scene.raise(low);
    try std.testing.expectEqual(high, scene.hitTest(5, 5).?);
    var region = try scene.visibleRegion(std.testing.allocator, low);
    defer region.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), region.items.len);
    const peer = try scene.add(.{ .kind = .{ .floating = bounds } });
    try std.testing.expectEqual(peer, scene.hitTest(5, 5).?);
    try scene.lower(peer);
    try std.testing.expectEqual(high, scene.hitTest(5, 5).?);
    try std.testing.expectError(error.InvalidLayer, scene.configure(low, .{ .kind = .tiled, .layer = -100 }));
}
