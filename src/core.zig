const std = @import("std");
pub const Rect = @import("geometry.zig").Rect;
pub const Id = u64;
pub const Axis = enum { horizontal, vertical };
pub const Edge = enum { left, right, top, bottom };
pub const Kind = union(enum) {
    tiled,
    floating: Rect,
    docked: struct { edge: Edge, extent: i32, reserves_space: bool = true },
};
pub const Options = struct {
    kind: Kind,
    always_on_top: bool = false,
    layer: i32 = 0,
    min_width: i32 = 0,
    min_height: i32 = 0,
};
pub const Window = struct {
    id: Id,
    options: Options,
    bounds: Rect,
    visible: bool = true,
    constraints_unmet: bool = false,
    order: u64,
};
const Split = struct { axis: Axis, first: usize, second: usize, ratio: u16 };
const Node = union(enum) { leaf: Id, split: Split };

/// Bounded, allocation-free first implementation. Capacity errors never evict windows.
/// Content, rendering, input decoding and process ownership all belong to the host.
pub const Scene = struct {
    pub const capacity = 32;
    root: Rect,
    usable: Rect,
    windows: [capacity]?Window = @splat(null),
    nodes: [capacity * 2 - 1]?Node = @splat(null),
    tree: ?usize = null,
    // First edge drop leaves the opposite half empty until another tile joins.
    first_tile_edge: ?Edge = null,
    focus: ?Id = null,
    capture: ?Id = null,
    next_id: Id = 1,
    next_order: u64 = 1,
    /// Conservative damage contract: every mutation invalidates the entire root.
    /// old_root also needs clearing when the host changes the display bounds.
    revision: u64 = 0,

    pub fn init(root: Rect) !Scene {
        _ = try Rect.init(root.x, root.y, root.w, root.h);
        return .{ .root = root, .usable = root };
    }
    pub fn get(self: *const Scene, id: Id) ?Window {
        for (self.windows) |maybe| {
            if (maybe) |w| if (w.id == id) return w;
        }
        return null;
    }
    fn window(self: *Scene, id: Id) !*Window {
        for (&self.windows) |*maybe| {
            if (maybe.*) |*w| if (w.id == id) return w;
        }
        return error.UnknownWindow;
    }
    fn freeNode(self: *Scene) usize {
        for (self.nodes, 0..) |n, i| if (n == null) return i;
        unreachable; // A full binary tree has at most 2 * capacity - 1 nodes.
    }
    fn validate(options: Options) !void {
        if (options.layer != 0 and options.kind != .floating) return error.InvalidLayer;
        if (options.min_width < 0 or options.min_height < 0) return error.InvalidBounds;
        switch (options.kind) {
            .floating => |r| _ = try Rect.init(r.x, r.y, r.w, r.h),
            .docked => |d| if (d.extent < 0) return error.InvalidBounds,
            .tiled => {},
        }
    }
    /// Adds a tile by splitting the whole tiled area. splitTile targets a leaf.
    pub fn add(self: *Scene, options: Options) !Id {
        try validate(options);
        var slot: ?usize = null;
        for (self.windows, 0..) |w, i| if (w == null) {
            slot = i;
            break;
        };
        const index = slot orelse return error.CapacityExceeded;
        const id = self.next_id;
        self.next_id += 1;
        self.windows[index] = .{ .id = id, .options = options, .bounds = self.root, .order = self.next_order };
        self.next_order += 1;
        if (options.kind == .tiled) {
            const leaf = self.freeNode();
            self.nodes[leaf] = .{ .leaf = id };
            if (self.tree) |previous| {
                const branch = self.freeNode();
                self.nodes[branch] = .{ .split = .{ .axis = .horizontal, .first = previous, .second = leaf, .ratio = 5000 } };
                self.tree = branch;
            } else self.tree = leaf;
        }
        self.layout();
        return id;
    }
    /// Ratio is in basis points, 0..10000. Failure leaves the scene unchanged.
    pub fn splitTile(self: *Scene, target: Id, axis: Axis, ratio: u16, options: Options) !Id {
        if (ratio > 10000 or options.kind != .tiled) return error.InvalidSplit;
        _ = self.get(target) orelse return error.UnknownWindow;
        var target_node: ?usize = null;
        for (self.nodes, 0..) |maybe, i| if (maybe) |n| {
            if (n == .leaf and n.leaf == target) target_node = i;
        };
        const index = target_node orelse return error.NotTiled;
        // Add as a floating placeholder so add does not change the tree.
        var placeholder = options;
        placeholder.kind = .{ .floating = self.root };
        const id = try self.add(placeholder);
        (try self.window(id)).options = options;
        const first = self.freeNode();
        self.nodes[first] = .{ .leaf = target };
        const second = self.freeNode();
        self.nodes[second] = .{ .leaf = id };
        self.nodes[index] = .{ .split = .{ .axis = axis, .first = first, .second = second, .ratio = ratio } };
        self.layout();
        return id;
    }
    /// Place an existing window beside a tile, or beside the whole tree when
    /// target is null. Preserve its ID; failures leave the scene unchanged.
    pub fn placeTile(self: *Scene, id: Id, target: ?Id, edge: Edge) !void {
        return self.placeTileRatio(id, target, edge, 5000);
    }
    /// New window share in basis points. Existing pointer docking stays 50/50.
    pub fn placeTileRatio(self: *Scene, id: Id, target: ?Id, edge: Edge, ratio: u16) !void {
        if (ratio == 0 or ratio >= 10000) return error.InvalidSplit;
        var next = self.*;
        _ = try next.window(id);
        if (target == id) return error.InvalidSplit;
        if (target) |other| {
            const w = next.get(other) orelse return error.UnknownWindow;
            if (w.options.kind != .tiled or !w.visible) return error.NotTiled;
        }
        if (next.tree) |root| next.tree = next.removeLeaf(root, id);
        const window_ptr = try next.window(id);
        window_ptr.options = .{ .kind = .tiled };
        window_ptr.visible = true;
        var anchor = next.tree;
        if (target) |other| {
            anchor = null;
            for (next.nodes, 0..) |maybe, index| if (maybe) |node| {
                if (node == .leaf and node.leaf == other) {
                    anchor = index;
                    break;
                }
            };
        }
        if (anchor) |index| {
            const old = next.nodes[index].?;
            const old_index = next.freeNode();
            next.nodes[old_index] = old;
            const new_index = next.freeNode();
            next.nodes[new_index] = .{ .leaf = id };
            const before = edge == .left or edge == .top;
            next.nodes[index] = .{ .split = .{
                .axis = if (edge == .left or edge == .right) .horizontal else .vertical,
                .first = if (before) new_index else old_index,
                .second = if (before) old_index else new_index,
                .ratio = if (before) ratio else 10000 - ratio,
            } };
        } else {
            const index = next.freeNode();
            next.nodes[index] = .{ .leaf = id };
            next.tree = index;
            next.first_tile_edge = edge;
        }
        next.layout();
        self.* = next;
    }
    fn removeLeaf(self: *Scene, index: usize, id: Id) ?usize {
        switch (self.nodes[index].?) {
            .leaf => |leaf| {
                if (leaf != id) return index;
                self.nodes[index] = null;
                return null;
            },
            .split => |s| {
                const first = self.removeLeaf(s.first, id);
                const second = self.removeLeaf(s.second, id);
                if (first == null or second == null) {
                    self.nodes[index] = null;
                    return first orelse second;
                }
                self.nodes[index] = .{ .split = .{ .first = first.?, .second = second.?, .axis = s.axis, .ratio = s.ratio } };
                return index;
            },
        }
    }
    fn nodeBounds(self: *const Scene, index: usize) Rect {
        return switch (self.nodes[index].?) {
            .leaf => |id| self.get(id).?.bounds,
            .split => |split| blk: {
                const a = self.nodeBounds(split.first);
                const b = self.nodeBounds(split.second);
                const x = @min(a.x, b.x);
                const y = @min(a.y, b.y);
                break :blk .{ .x = x, .y = y, .w = @max(a.right(), b.right()) - x, .h = @max(a.bottom(), b.bottom()) - y };
            },
        };
    }
    /// Identify the split touching the right/bottom edge of a visible tile.
    pub fn dividerFor(self: *const Scene, id: Id, axis: Axis) ?usize {
        const tile = self.get(id) orelse return null;
        if (tile.options.kind != .tiled or !tile.visible) return null;
        for (self.nodes, 0..) |maybe, index| if (maybe) |node| {
            if (node != .split or node.split.axis != axis or !self.tileVisible(node.split.first) or !self.tileVisible(node.split.second)) continue;
            const first = self.nodeBounds(node.split.first);
            const r = tile.bounds;
            if (axis == .horizontal) {
                if (first.right() == r.right() and r.y >= first.y and r.bottom() <= first.bottom()) return index;
            } else if (first.bottom() == r.bottom() and r.x >= first.x and r.right() <= first.right()) return index;
        };
        return null;
    }
    fn minimumSpan(self: *const Scene, index: usize, axis: Axis) i32 {
        return switch (self.nodes[index].?) {
            .leaf => 3,
            .split => |s| if (s.axis == axis) self.minimumSpan(s.first, axis) + self.minimumSpan(s.second, axis) else @max(self.minimumSpan(s.first, axis), self.minimumSpan(s.second, axis)),
        };
    }
    pub fn resizeDivider(self: *Scene, index: usize, position: i32) !void {
        if (index >= self.nodes.len) return error.InvalidSplit;
        const node = self.nodes[index] orelse return error.InvalidSplit;
        if (node != .split) return error.InvalidSplit;
        const split = node.split;
        const bounds = self.nodeBounds(index);
        const span = if (split.axis == .horizontal) bounds.w else bounds.h;
        if (span < 6) return;
        const start = if (split.axis == .horizontal) bounds.x else bounds.y;
        const min_first = self.minimumSpan(split.first, split.axis);
        const min_second = self.minimumSpan(split.second, split.axis);
        if (span < min_first + min_second) return;
        const extent = std.math.clamp(position - start, min_first, span - min_second);
        self.nodes[index].?.split.ratio = @intCast(@divTrunc(@as(i64, extent) * 10000 + span - 1, span));
        self.layout();
    }
    pub fn remove(self: *Scene, id: Id) !void {
        _ = try self.window(id);
        if (self.tree) |root| self.tree = self.removeLeaf(root, id);
        for (&self.windows) |*w| if (w.* != null and w.*.?.id == id) {
            w.* = null;
            break;
        };
        if (self.focus == id) self.focus = null;
        if (self.capture == id) self.capture = null;
        self.layout();
    }
    pub fn resizeRoot(self: *Scene, root: Rect) !void {
        _ = try Rect.init(root.x, root.y, root.w, root.h);
        self.root = root;
        self.layout();
    }
    /// Change presentation without changing content identity or docking order.
    pub fn configure(self: *Scene, id: Id, options: Options) !void {
        try validate(options);
        const w = try self.window(id);
        const was_tiled = w.options.kind == .tiled;
        const is_tiled = options.kind == .tiled;
        if (was_tiled and !is_tiled) {
            if (self.tree) |root| self.tree = self.removeLeaf(root, id);
        } else if (!was_tiled and is_tiled) {
            const leaf = self.freeNode();
            self.nodes[leaf] = .{ .leaf = id };
            if (self.tree) |root| {
                const branch = self.freeNode();
                self.nodes[branch] = .{ .split = .{ .axis = .horizontal, .first = root, .second = leaf, .ratio = 5000 } };
                self.tree = branch;
            } else self.tree = leaf;
        }
        w.options = options;
        self.layout();
    }
    pub fn moveResize(self: *Scene, id: Id, requested: Rect) !void {
        _ = try Rect.init(requested.x, requested.y, requested.w, requested.h);
        const w = try self.window(id);
        if (w.options.kind != .floating) return error.NotFloating;
        w.options.kind = .{ .floating = requested };
        self.layout();
    }
    pub fn setVisible(self: *Scene, id: Id, visible: bool) !void {
        (try self.window(id)).visible = visible;
        if (!visible) {
            if (self.focus == id) self.focus = null;
            if (self.capture == id) self.capture = null;
        }
        self.layout();
    }
    pub fn setFocus(self: *Scene, id: Id) !void {
        const w = try self.window(id);
        if (!w.visible or w.bounds.empty()) return error.NotVisible;
        self.focus = id;
        self.revision += 1;
    }
    pub fn capturePointer(self: *Scene, id: Id) !void {
        const w = try self.window(id);
        if (!w.visible or w.bounds.empty()) return error.NotVisible;
        self.capture = id;
    }
    pub fn releasePointer(self: *Scene) void {
        self.capture = null;
    }
    pub fn raise(self: *Scene, id: Id) !void {
        (try self.window(id)).order = self.next_order;
        self.next_order += 1;
        self.revision += 1;
    }
    pub fn lower(self: *Scene, id: Id) !void {
        const target = try self.window(id);
        // Preserve all other relative orders while moving the target to the back.
        for (&self.windows) |*maybe| if (maybe.*) |*w| {
            w.order += 1;
        };
        target.order = 0;
        self.next_order += 1;
        self.revision += 1;
    }
    fn above(a: Window, b: Window) bool {
        if (a.options.layer != b.options.layer) return a.options.layer > b.options.layer;
        if (a.options.always_on_top != b.options.always_on_top) return a.options.always_on_top;
        return a.order > b.order;
    }
    pub fn hitTest(self: *const Scene, x: i32, y: i32) ?Id {
        if (!self.root.contains(x, y)) return null;
        var result: ?Window = null;
        for (self.windows) |maybe| if (maybe) |w| {
            if (w.visible and w.bounds.contains(x, y) and (result == null or above(w, result.?))) result = w;
        };
        return if (result) |w| w.id else null;
    }
    pub fn pointerTarget(self: *const Scene, x: i32, y: i32) ?Id {
        return self.capture orelse self.hitTest(x, y);
    }
    fn tileVisible(self: *const Scene, index: usize) bool {
        return switch (self.nodes[index].?) {
            .leaf => |id| self.get(id).?.visible,
            .split => |s| self.tileVisible(s.first) or self.tileVisible(s.second),
        };
    }
    fn layoutTiles(self: *Scene, index: usize, r: Rect) void {
        switch (self.nodes[index].?) {
            .leaf => |id| (self.window(id) catch unreachable).bounds = r,
            .split => |s| {
                const a_visible = self.tileVisible(s.first);
                const b_visible = self.tileVisible(s.second);
                if (!a_visible) return self.layoutTiles(s.second, r);
                if (!b_visible) return self.layoutTiles(s.first, r);
                var a = r;
                var b = r;
                if (s.axis == .horizontal) {
                    a.w = @intCast(@divTrunc(@as(i64, r.w) * s.ratio, 10000));
                    b.x += a.w;
                    b.w -= a.w;
                } else {
                    a.h = @intCast(@divTrunc(@as(i64, r.h) * s.ratio, 10000));
                    b.y += a.h;
                    b.h -= a.h;
                }
                self.layoutTiles(s.first, a);
                self.layoutTiles(s.second, b);
            },
        }
    }
    fn layout(self: *Scene) void {
        var available = self.root;
        // IDs preserve insertion/docking order even when slots are reused or raised.
        var previous: Id = 0;
        while (true) {
            var next: ?*Window = null;
            for (&self.windows) |*maybe| if (maybe.*) |*w| {
                if (w.visible and w.options.kind == .docked and w.id > previous and (next == null or w.id < next.?.id)) next = w;
            };
            const w = next orelse break;
            previous = w.id;
            const d = w.options.kind.docked;
            var r = available;
            switch (d.edge) {
                .left, .right => {
                    r.w = @min(d.extent, available.w);
                    if (d.edge == .right) r.x = available.right() - r.w;
                    if (d.reserves_space) {
                        available.w -= r.w;
                        if (d.edge == .left) available.x += r.w;
                    }
                },
                .top, .bottom => {
                    r.h = @min(d.extent, available.h);
                    if (d.edge == .bottom) r.y = available.bottom() - r.h;
                    if (d.reserves_space) {
                        available.h -= r.h;
                        if (d.edge == .top) available.y += r.h;
                    }
                },
            }
            w.bounds = r;
        }
        self.usable = available;
        if (self.tree) |root| {
            var tile_area = available;
            if (self.nodes[root].? == .split) self.first_tile_edge = null;
            if (self.first_tile_edge) |edge| {
                switch (edge) {
                    .left => tile_area.w = @divTrunc(available.w, 2),
                    .right => {
                        const half = @divTrunc(available.w, 2);
                        tile_area.x += half;
                        tile_area.w -= half;
                    },
                    .top => tile_area.h = @divTrunc(available.h, 2),
                    .bottom => {
                        const half = @divTrunc(available.h, 2);
                        tile_area.y += half;
                        tile_area.h -= half;
                    },
                }
            }
            self.layoutTiles(root, tile_area);
        } else self.first_tile_edge = null;
        for (&self.windows) |*maybe| if (maybe.*) |*w| {
            if (w.options.kind == .floating) w.bounds = w.options.kind.floating.constrained(self.root);
            w.constraints_unmet = w.bounds.w < w.options.min_width or w.bounds.h < w.options.min_height;
            if (w.options.kind == .docked) {
                const d = w.options.kind.docked;
                const actual = if (d.edge == .left or d.edge == .right) w.bounds.w else w.bounds.h;
                w.constraints_unmet = w.constraints_unmet or actual < d.extent;
            }
            if (w.bounds.empty()) {
                if (self.focus == w.id) self.focus = null;
                if (self.capture == w.id) self.capture = null;
            }
        };
        self.revision += 1;
    }

    /// Caller owns returned region storage. All current windows are opaque.
    pub fn visibleRegion(self: *const Scene, allocator: std.mem.Allocator, id: Id) !std.ArrayList(Rect) {
        const w = self.get(id) orelse return error.UnknownWindow;
        var result: std.ArrayList(Rect) = .empty;
        errdefer result.deinit(allocator);
        if (!w.visible) return result;
        const clipped = w.bounds.intersection(self.root) orelse return result;
        try result.append(allocator, clipped);
        for (self.windows) |maybe| if (maybe) |other| {
            if (!other.visible or !above(other, w)) continue;
            var next: std.ArrayList(Rect) = .empty;
            errdefer next.deinit(allocator);
            for (result.items) |piece| {
                var pieces: [4]Rect = undefined;
                const count = piece.subtract(other.bounds, &pieces);
                try next.appendSlice(allocator, pieces[0..count]);
            }
            result.deinit(allocator);
            result = next;
        };
        return result;
    }
};

test {
    _ = @import("core_test.zig");
}
