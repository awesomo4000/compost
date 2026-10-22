const std = @import("std");

/// Integral layout units. Coordinates and extents are unrelated to terminal cells.
/// Use init at external boundaries. Internal operations preserve valid bounds.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn init(x: i32, y: i32, w: i32, h: i32) error{InvalidBounds}!Rect {
        if (w < 0 or h < 0 or @as(i64, x) + w > std.math.maxInt(i32) or
            @as(i64, y) + h > std.math.maxInt(i32)) return error.InvalidBounds;
        return .{ .x = x, .y = y, .w = w, .h = h };
    }

    pub fn right(r: Rect) i32 {
        return r.x + r.w;
    }
    pub fn bottom(r: Rect) i32 {
        return r.y + r.h;
    }
    pub fn empty(r: Rect) bool {
        return r.w == 0 or r.h == 0;
    }
    pub fn contains(r: Rect, x: i32, y: i32) bool {
        return x >= r.x and x < r.right() and y >= r.y and y < r.bottom();
    }
    pub fn intersection(a: Rect, b: Rect) ?Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        const right_edge = @min(a.right(), b.right());
        const bottom_edge = @min(a.bottom(), b.bottom());
        if (right_edge <= x or bottom_edge <= y) return null;
        return .{ .x = x, .y = y, .w = right_edge - x, .h = bottom_edge - y };
    }
    pub fn constrained(r: Rect, bounds: Rect) Rect {
        const w = @min(r.w, bounds.w);
        const h = @min(r.h, bounds.h);
        return .{
            .x = std.math.clamp(r.x, bounds.x, bounds.right() - w),
            .y = std.math.clamp(r.y, bounds.y, bounds.bottom() - h),
            .w = w,
            .h = h,
        };
    }

    /// Nonoverlapping pieces of a outside b, with half-open edges.
    pub fn subtract(a: Rect, b: Rect, out: *[4]Rect) usize {
        const overlap = a.intersection(b) orelse {
            if (a.empty()) return 0;
            out[0] = a;
            return 1;
        };
        const candidates = [_]Rect{
            .{ .x = a.x, .y = a.y, .w = a.w, .h = overlap.y - a.y },
            .{ .x = a.x, .y = overlap.bottom(), .w = a.w, .h = a.bottom() - overlap.bottom() },
            .{ .x = a.x, .y = overlap.y, .w = overlap.x - a.x, .h = overlap.h },
            .{ .x = overlap.right(), .y = overlap.y, .w = a.right() - overlap.right(), .h = overlap.h },
        };
        var count: usize = 0;
        for (candidates) |piece| {
            if (piece.empty()) continue;
            out[count] = piece;
            count += 1;
        }
        return count;
    }
};
