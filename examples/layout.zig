const std = @import("std");
const core = @import("compositor");

pub fn main() !void {
    var scene = try core.Scene.init(try core.Rect.init(0, 0, 60, 18));
    _ = try scene.add(.{ .kind = .{ .docked = .{ .edge = .left, .extent = 8 } }, .always_on_top = true });
    _ = try scene.add(.{ .kind = .{ .docked = .{ .edge = .top, .extent = 3 } }, .always_on_top = true });
    const tile = try scene.add(.{ .kind = .tiled });
    _ = try scene.splitTile(tile, .horizontal, 5000, .{ .kind = .tiled });
    _ = try scene.add(.{ .kind = .{ .floating = try core.Rect.init(24, 7, 22, 7) } });
    std.debug.print("1 left wall; 2 top wall; 3/4 tiles; 5 floating window\n\n", .{});
    for (0..18) |y| {
        var row: [60]u8 = undefined;
        for (&row, 0..) |*cell, x| {
            const id = scene.hitTest(@intCast(x), @intCast(y));
            cell.* = if (id) |value| '0' + @as(u8, @intCast(value)) else '.';
        }
        std.debug.print("{s}\n", .{row});
    }
}
