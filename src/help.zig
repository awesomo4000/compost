//! Compact help overlay. Bindings come from the same table as input dispatch.
const std = @import("std");
const core = @import("compositor");
const input = @import("input.zig");
pub fn bounds(root: core.Rect) core.Rect {
    const width = @min(root.w, 58);
    return .{ .x = root.right() - width, .y = root.y, .w = width, .h = @min(root.h, 21) };
}
fn line(w: *std.Io.Writer, r: core.Rect, row: i32, text: []const u8) !void {
    if (row >= r.h - 1 or r.w < 4) return;
    const n = @min(text.len, @as(usize, @intCast(r.w - 4)));
    try w.print("\x1b[{d};{d}H{s}", .{ r.y + row + 1, r.x + 3, text[0..n] });
}
pub fn draw(w: *std.Io.Writer, root: core.Rect, prefix: input.Prefix) !void {
    const r = bounds(root);
    if (r.w < 2 or r.h < 2) return;
    try w.writeAll("\x1b[0;38;2;100;160;153;48;2;18;24;28m");
    for (0..@intCast(r.h)) |y| {
        try w.print("\x1b[{d};{d}H", .{ r.y + @as(i32, @intCast(y)) + 1, r.x + 1 });
        for (0..@intCast(r.w)) |x| {
            const edge_y = y == 0 or y == r.h - 1;
            const edge_x = x == 0 or x == r.w - 1;
            try w.writeAll(if (edge_x and edge_y) "+" else if (edge_y) "─" else if (edge_x) "│" else " ");
        }
    }
    try line(w, r, 1, "COMPO keybindings");
    var buffer: [128]u8 = undefined;
    for (input.bindings, 0..) |binding, index| {
        const text = try std.mem.print(&buffer, "{s} {s}: {s}", .{ prefix.label(), binding.label, binding.description });
        try line(w, r, @intCast(index + 3), text);
    }
    try line(w, r, 13, try std.mem.print(&buffer, "{s} 1-9, 0: focus window 1-10", .{prefix.label()}));
    try line(w, r, 14, try std.mem.print(&buffer, "{s} twice: send literal prefix", .{prefix.label()}));
    try line(w, r, 16, "Alt-drag: move/dock / Ctrl-Alt-drag: free move");
    try line(w, r, 17, "Border drag: resize / Shift-PgUp/PgDn: scroll");
    try line(w, r, 19, "Esc, help shortcut, or click outside: dismiss");
    try w.writeAll("\x1b[0m");
}
