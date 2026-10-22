const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("compositor");
const decoration = @import("frame.zig");
const terminal = @import("terminal");

pub const Tint = struct {
    bounds: core.Rect,
    color: vt.color.RGB = .{ .r = 80, .g = 110, .b = 130 },
    alpha: u8 = 64,
};
fn blend(base: vt.color.RGB, tint: Tint) vt.color.RGB {
    var result: vt.color.RGB = undefined;
    inline for (.{ "r", "g", "b" }) |channel| {
        @field(result, channel) = @intCast((@as(u32, @field(base, channel)) * (255 - @as(u32, tint.alpha)) + @as(u32, @field(tint.color, channel)) * tint.alpha + 127) / 255);
    }
    return result;
}
fn resolveColor(value: vt.Style.Color, fallback: vt.color.RGB, palette: vt.color.Palette) vt.color.RGB {
    return switch (value) {
        .none => fallback,
        .rgb => |rgb| rgb,
        .palette => |index| palette[index],
    };
}

/// Row-diff renderer. Owns outer image IDs, never forwards APC bytes.
pub const Renderer = struct {
    tint: ?Tint = null,
    previous_tint: ?Tint = null,
    state: vt.RenderState = .empty,
    images: std.AutoHashMapUnmanaged(u32, u32) = .{},
    generation: u64 = 0,
    image_dirty: ?u64 = null,
    image_scene: ?u64 = null,
    next_image: u32 = 1,
    image_stride: u32 = 1,
    framed: bool = true,
    bordered: bool = false,
    rows: std.ArrayList(std.ArrayList(u8)) = .empty,
    row_ids: std.ArrayList(vt.RenderState.Row.Id) = .empty,
    text_scene: ?u64 = null,
    output: ?std.Io.Writer.Allocating = null,
    row_output: ?std.Io.Writer.Allocating = null,
    region: std.ArrayList(core.Rect) = .empty,
    region_scene: ?u64 = null,
    region_id: ?core.Id = null,

    pub fn invalidate(self: *Renderer, allocator: std.mem.Allocator) void {
        _ = allocator;
        for (self.rows.items) |*row| row.clearRetainingCapacity();
        self.image_dirty = null;
        self.row_ids.clearRetainingCapacity();
    }

    pub fn deinit(self: *Renderer, allocator: std.mem.Allocator) void {
        self.invalidate(allocator);
        for (self.rows.items) |*row| row.deinit(allocator);
        self.rows.deinit(allocator);
        if (self.output) |*output| output.deinit();
        if (self.row_output) |*output| output.deinit();
        self.region.deinit(allocator);
        self.row_ids.deinit(allocator);
        self.state.deinit(allocator);
        self.images.deinit(allocator);
    }
    /// Borrowed frame, valid until the next draw or deinit. Use the same allocator throughout.
    pub fn draw(self: *Renderer, allocator: std.mem.Allocator, scene: *const core.Scene, id: core.Id, surface: *terminal.Surface) ![]const u8 {
        try self.state.update(allocator, &surface.terminal);
        if (!std.meta.eql(self.tint, self.previous_tint)) self.row_ids.clearRetainingCapacity();
        if (self.region_scene != scene.revision or self.region_id != id) {
            var region = try scene.visibleRegion(allocator, id);
            if (self.bordered) {
                const inner = decoration.contentFor(scene, id);
                var kept: usize = 0;
                for (region.items) |rect| if (rect.intersection(inner)) |clipped| {
                    region.items[kept] = clipped;
                    kept += 1;
                };
                region.items.len = kept;
            }
            self.region.deinit(allocator);
            self.region = region;
            self.region_scene = scene.revision;
            self.region_id = id;
        }
        const region = self.region;
        const outer = scene.get(id).?.bounds;
        const bounds = if (self.bordered) decoration.contentFor(scene, id) else outer;
        if (self.output == null) self.output = .init(allocator);
        const output = &self.output.?;
        output.clearRetainingCapacity();
        const w = &output.writer;
        if (self.framed) try w.writeAll("\x1b[?2026h\x1b[?25l\x1b[?7l");
        const range = self.state.rowDataRange();
        if (self.row_output == null) self.row_output = .init(allocator);
        const row_output = &self.row_output.?;
        try self.row_ids.ensureTotalCapacity(allocator, range.end - range.start);
        for (range.start..range.end, 0..) |row_index, y| {
            const row_id = self.state.row_data.get(row_index).id();
            if (self.text_scene == scene.revision and y < self.row_ids.items.len and
                std.meta.eql(self.row_ids.items[y], row_id) and
                !self.state.row_data.items(.dirty)[row_index]) continue;
            row_output.clearRetainingCapacity();
            const row_writer = &row_output.writer;
            const cells = self.state.row_data.items(.cells)[row_index];
            const raws = cells.items(.raw);
            var x: usize = 0;
            var next_x: ?i32 = null;
            var previous_style: ?vt.Style = null;
            while (x < raws.len) {
                const raw = raws[x];
                const width: usize = @max(1, raw.gridWidth());
                const px = bounds.x + @as(i32, @intCast(x));
                const py = bounds.y + @as(i32, @intCast(y));
                if (!visible(region.items, px, py)) {
                    x += width;
                    continue;
                }
                if (next_x != px) try row_writer.print("\x1b[{d};{d}H", .{ py + 1, px + 1 });
                var style: vt.Style = if (raw.hasStyling()) cells.items(.style)[x] else .{};
                // Background-only cells carry their color in the cell, not the style.
                switch (raw.content_tag) {
                    .bg_color_palette => style.bg_color = .{ .palette = raw.content.color_palette.data },
                    .bg_color_rgb => style.bg_color = .{ .rgb = .{ .r = raw.content.color_rgb.r, .g = raw.content.color_rgb.g, .b = raw.content.color_rgb.b } },
                    else => {},
                }
                if (self.tint) |tint| if (tint.bounds.contains(px, py) or (width == 2 and tint.bounds.contains(px + 1, py))) {
                    // Resolve palette/default colors before blending. Preserve glyphs,
                    // inverse video and all other attributes in the retained screen.
                    const bg = self.state.colors.background;
                    const fg = self.state.colors.foreground;
                    style.bg_color = .{ .rgb = blend(resolveColor(style.bg_color, bg, self.state.colors.palette), tint) };
                    style.fg_color = .{ .rgb = blend(resolveColor(style.fg_color, fg, self.state.colors.palette), tint) };
                    if (style.underline_color != .none) style.underline_color = .{ .rgb = blend(resolveColor(style.underline_color, fg, self.state.colors.palette), tint) };
                };
                if (previous_style == null or !previous_style.?.eql(style)) {
                    try row_writer.writeAll("\x1b[0m");
                    try colors(row_writer, style, null);
                    previous_style = style;
                }
                next_x = px + @as(i32, @intCast(width));
                if (width == 2 and !visible(region.items, px + 1, py)) {
                    try row_writer.writeAll(" ");
                    next_x = px + 1;
                } else if (!raw.hasText() or raw.codepoint() == vt.kitty.graphics.unicode.placeholder) {
                    try row_writer.writeAll(" ");
                } else {
                    try codepoint(row_writer, raw.codepoint());
                    if (raw.content_tag == .codepoint_grapheme) {
                        for (cells.items(.grapheme)[x]) |cp| try codepoint(row_writer, cp);
                    }
                }
                x += width;
            }
            self.state.row_data.items(.dirty)[row_index] = false;
            if (y >= self.row_ids.items.len) self.row_ids.appendAssumeCapacity(row_id) else self.row_ids.items[y] = row_id;
            const bytes = row_output.written();
            if (y >= self.rows.items.len) try self.rows.append(allocator, .empty);
            const cached = &self.rows.items[y];
            if (!std.mem.eql(u8, cached.items, bytes)) {
                try cached.ensureTotalCapacity(allocator, bytes.len);
                cached.clearRetainingCapacity();
                cached.appendSliceAssumeCapacity(bytes);
                try w.writeAll(bytes);
            }
        }
        self.state.dirty = .false;
        self.text_scene = scene.revision;
        self.previous_tint = self.tint;
        try w.writeAll("\x1b[0m");
        const storage = &surface.terminal.screens.active.kitty_images;
        if (self.image_dirty != storage.dirty or self.generation != storage.generation or self.image_scene != scene.revision) {
            try self.drawImages(allocator, w, surface, bounds, region.items);
            self.image_dirty = storage.dirty;
            self.image_scene = scene.revision;
        }
        // Standalone rendering owns input modes; an embedded renderer leaves them to its host.
        if (self.framed and scene.focus == id) {
            inline for (.{ .{ "cursor_keys", 1 }, .{ "bracketed_paste", 2004 }, .{ "mouse_event_normal", 1000 }, .{ "mouse_event_button", 1002 }, .{ "mouse_event_any", 1003 }, .{ "mouse_format_sgr", 1006 }, .{ "focus_event", 1004 } }) |mode| {
                try w.print("\x1b[?{d}{s}", .{ mode[1], if (surface.terminal.modes.get(@field(vt.modes.Mode, mode[0]))) "h" else "l" });
            }
        }
        const cursor = self.state.cursor;
        if (self.framed and scene.focus == id and cursor.visible) if (cursor.viewport) |position| {
            const x = bounds.x + @as(i32, position.x);
            const y = bounds.y + @as(i32, @intCast(position.y));
            if (visible(region.items, x, y)) try w.print("\x1b[{d};{d}H\x1b[?25h", .{ y + 1, x + 1 });
        };
        if (self.framed) try w.writeAll("\x1b[?2026l");
        return output.written();
    }
    fn visible(region: []const core.Rect, x: i32, y: i32) bool {
        for (region) |r| if (r.contains(x, y)) return true;
        return false;
    }
    fn codepoint(w: *std.Io.Writer, cp: u21) !void {
        var bytes: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &bytes);
        try w.writeAll(bytes[0..len]);
    }
    fn color(w: *std.Io.Writer, value: vt.Style.Color, which: u8) !void {
        switch (value) {
            .none => {},
            .palette => |index| try w.print("\x1b[{d};5;{d}m", .{ which, index }),
            .rgb => |rgb| try w.print("\x1b[{d};2;{d};{d};{d}m", .{ which, rgb.r, rgb.g, rgb.b }),
        }
    }
    fn colors(w: *std.Io.Writer, style: vt.Style, raw: ?vt.Cell) !void {
        try color(w, style.fg_color, 38);
        var background = style.bg_color;
        if (raw) |cell| switch (cell.content_tag) {
            .bg_color_palette => background = .{ .palette = cell.content.color_palette.data },
            .bg_color_rgb => background = .{ .rgb = .{ .r = cell.content.color_rgb.r, .g = cell.content.color_rgb.g, .b = cell.content.color_rgb.b } },
            else => {},
        };
        try color(w, background, 48);
        try color(w, style.underline_color, 58);
        inline for (.{ .{ "bold", 1 }, .{ "faint", 2 }, .{ "italic", 3 }, .{ "blink", 5 }, .{ "inverse", 7 }, .{ "invisible", 8 }, .{ "strikethrough", 9 } }) |flag| {
            if (@field(style.flags, flag[0])) try w.print("\x1b[{d}m", .{flag[1]});
        }
        const underline: u8 = switch (style.flags.underline) {
            .none => 0,
            .single => 1,
            .double => 2,
            .curly => 3,
            .dotted => 4,
            .dashed => 5,
        };
        if (underline != 0) try w.print("\x1b[4:{d}m", .{underline});
    }
    fn drawImages(self: *Renderer, allocator: std.mem.Allocator, w: *std.Io.Writer, surface: *terminal.Surface, bounds: core.Rect, region: []const core.Rect) !void {
        const storage = &surface.terminal.screens.active.kitty_images;
        var cached = self.images.valueIterator();
        while (cached.next()) |id| try w.print("\x1b_Ga=d,d={s},i={d},q=2;\x1b\\", .{ if (self.generation != storage.generation) "I" else "i", id.* });
        if (self.generation != storage.generation) {
            self.images.clearRetainingCapacity();
            self.generation = storage.generation;
        }
        if (surface.size.cell_width == 0 or surface.size.cell_height == 0) return;
        var placements = storage.placements.iterator();
        while (placements.next()) |entry| {
            const p = entry.value_ptr;
            // Virtual and relative placements need a separate projection pass.
            const pin = switch (p.location) {
                .pin => |value| value,
                else => continue,
            };
            const point = surface.terminal.screens.active.pages.pointFromPin(.viewport, pin.*) orelse continue;
            const image = storage.imageById(entry.key_ptr.image_id) orelse continue;
            const bytes = switch (image.data) {
                .complete => |data| data,
                else => continue,
            };
            const format: u32 = switch (image.format) {
                .rgb => 24,
                .rgba => 32,
                else => continue,
            };
            const source = p.sourceRect(image);
            // Only emit placements fully inside a visible rectangle for now. Never
            // allow an image to cross a compositor wall while clipping is unfinished.
            if (source.width == 0 or source.height == 0) continue;
            var pixel_width: u64 = source.width;
            var pixel_height: u64 = source.height;
            if (p.columns != 0) pixel_width = @as(u64, p.columns) * surface.size.cell_width;
            if (p.rows != 0) pixel_height = @as(u64, p.rows) * surface.size.cell_height;
            if (p.columns != 0 and p.rows == 0) pixel_height = (pixel_width * source.height + source.width - 1) / source.width;
            if (p.rows != 0 and p.columns == 0) pixel_width = (pixel_height * source.width + source.height - 1) / source.height;
            const cols = (pixel_width + p.x_offset + surface.size.cell_width - 1) / surface.size.cell_width;
            const rows = (pixel_height + p.y_offset + surface.size.cell_height - 1) / surface.size.cell_height;
            const x = bounds.x + @as(i32, point.viewport.x);
            const y = bounds.y + @as(i32, @intCast(point.viewport.y));
            var fits = false;
            for (region) |r| {
                if (x >= r.x and y >= r.y and @as(i64, x) + @as(i64, @intCast(cols)) <= r.right() and @as(i64, y) + @as(i64, @intCast(rows)) <= r.bottom()) fits = true;
            }
            if (!fits) continue;
            const outer_id = self.images.get(entry.key_ptr.image_id) orelse upload: {
                const id = self.next_image;
                self.next_image = std.math.add(u32, id, self.image_stride) catch return error.ImageIdExhausted;
                var offset: usize = 0;
                while (offset < bytes.len) {
                    const end = @min(offset + 3072, bytes.len);
                    var encoded: [4096]u8 = undefined;
                    const payload = std.base64.standard.Encoder.encode(&encoded, bytes[offset..end]);
                    if (offset == 0) try w.print("\x1b_Ga=t,f={d},s={d},v={d},i={d},q=2,m={d};", .{ format, image.width, image.height, id, @as(u8, if (end < bytes.len) 1 else 0) }) else try w.print("\x1b_Gq=2,m={d};", .{@as(u8, if (end < bytes.len) 1 else 0)});
                    try w.writeAll(payload);
                    try w.writeAll("\x1b\\");
                    offset = end;
                }
                try self.images.put(allocator, entry.key_ptr.image_id, id);
                break :upload id;
            };
            try w.print("\x1b[{d};{d}H\x1b_Ga=p,i={d},q=2,C=1,x={d},y={d},w={d},h={d},c={d},r={d},X={d},Y={d},z={d};\x1b\\", .{
                y + 1, x + 1, outer_id, source.x, source.y, source.width, source.height, p.columns, p.rows, p.x_offset, p.y_offset, p.z,
            });
        }
    }
};

fn discard(_: *anyopaque, _: []const u8) !void {}

fn visualText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try output.writer.writeAll(std.mem.trimEnd(u8, line, " "));
        try output.writer.writeAll("\n");
    }
    return allocator.dupe(u8, std.mem.trimEnd(u8, output.written(), "\n"));
}

test "rendered styled Unicode screen reconstructs in another terminal" {
    const alloc = std.testing.allocator;
    var context: u8 = 0;
    const size: terminal.Size = .{ .columns = 24, .rows = 6, .cell_width = 8, .cell_height = 16 };
    const source = try terminal.Surface.create(std.testing.io, alloc, size, .{ .context = &context, .write = discard });
    defer source.destroy();
    const destination = try terminal.Surface.create(std.testing.io, alloc, size, .{ .context = &context, .write = discard });
    defer destination.destroy();
    var scene = try core.Scene.init(try core.Rect.init(0, 0, 24, 6));
    const id = try scene.add(.{ .kind = .tiled });
    try scene.setFocus(id);
    var renderer: Renderer = .{};
    defer renderer.deinit(alloc);
    try source.feed("\x1b[31;1mred\x1b[0m 世界 e\xcc\x81\r\nsecond\x1b[?1h");
    const frame = try renderer.draw(alloc, &scene, id, source);
    try destination.feed(frame);
    const expected = try source.plainText(alloc);
    defer alloc.free(expected);
    const actual = try destination.plainText(alloc);
    defer alloc.free(actual);
    // Repainting materializes empty cells as spaces; their visual content is equal.
    const expected_visual = try visualText(alloc, expected);
    defer alloc.free(expected_visual);
    const actual_visual = try visualText(alloc, actual);
    defer alloc.free(actual_visual);
    try std.testing.expectEqualStrings(expected_visual, actual_visual);
    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &destination.terminal);
    const style = state.row_data.items(.cells)[state.rowDataRange().start].items(.style)[0];
    try std.testing.expect(style.flags.bold);
    try std.testing.expectEqual(@as(u8, 1), style.fg_color.palette);
    try std.testing.expect(destination.terminal.modes.get(.cursor_keys));
}

test "outer Kitty image IDs are independent and uploads survive text-only redraws" {
    const alloc = std.testing.allocator;
    var context: u8 = 0;
    const size: terminal.Size = .{ .columns = 24, .rows = 6, .cell_width = 8, .cell_height = 16 };
    const source = try terminal.Surface.create(std.testing.io, alloc, size, .{ .context = &context, .write = discard });
    defer source.destroy();
    const destination = try terminal.Surface.create(std.testing.io, alloc, size, .{ .context = &context, .write = discard });
    defer destination.destroy();
    var scene = try core.Scene.init(try core.Rect.init(0, 0, 24, 6));
    const id = try scene.add(.{ .kind = .tiled });
    var renderer: Renderer = .{};
    defer renderer.deinit(alloc);
    try source.feed("\x1b_Ga=T,f=24,s=1,v=1,i=42;/wAA\x1b\\");
    const first = try renderer.draw(alloc, &scene, id, source);
    try destination.feed(first);
    const image = destination.terminal.screens.active.kitty_images.imageById(1) orelse return error.ImageMissing;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, image.data.complete);
    try source.feed("text");
    const next = try renderer.draw(alloc, &scene, id, source);
    try std.testing.expect(std.mem.indexOf(u8, next, "a=t") == null);
    try std.testing.expect(std.mem.indexOf(u8, next, "a=d") == null);
    try destination.feed(next);
    try std.testing.expectEqual(@as(u32, 1), destination.terminal.screens.active.kitty_images.placements.count());
    renderer.tint = .{ .bounds = try core.Rect.init(0, 0, 12, 6) };
    const tinted = try renderer.draw(alloc, &scene, id, source);
    try std.testing.expect(std.mem.indexOf(u8, tinted, "\x1b_G") == null);
    try destination.feed(tinted);
    try std.testing.expectEqual(@as(u32, 1), destination.terminal.screens.active.kitty_images.placements.count());
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, destination.terminal.screens.active.kitty_images.imageById(1).?.data.complete);
    renderer.tint = null;
    try destination.feed(try renderer.draw(alloc, &scene, id, source));
    try source.feed("\x1b_Ga=d,d=I,i=42;\x1b\\");
    const deleted = try renderer.draw(alloc, &scene, id, source);
    try destination.feed(deleted);
    try std.testing.expect(destination.terminal.screens.active.kitty_images.imageById(1) == null);
}

test "compact runs preserve incremental edits scrolling backgrounds and cursor-only updates" {
    const alloc = std.testing.allocator;
    var context: u8 = 0;
    const size: terminal.Size = .{ .columns = 80, .rows = 24 };
    const source = try terminal.Surface.create(std.testing.io, alloc, size, .{ .context = &context, .write = discard });
    defer source.destroy();
    const destination = try terminal.Surface.create(std.testing.io, alloc, size, .{ .context = &context, .write = discard });
    defer destination.destroy();
    var scene = try core.Scene.init(try core.Rect.init(0, 0, 80, 24));
    const id = try scene.add(.{ .kind = .tiled });
    try scene.setFocus(id);
    var renderer: Renderer = .{};
    defer renderer.deinit(alloc);
    for ([_][]const u8{
        "\x1b[31mred red red\x1b[0m plain 世界 e\xcc\x81\r\nsecond",
        "\x1b[1;5HEDIT\x1b[2;1H\x1b[44m\x1b[K\x1b[0m",
        "\x1b[24;1Hbottom\r\nscrolled\r\nagain",
        "\x1b[?1049h\x1b[Halternate",
        "\x1b[?1049l",
    }) |update| {
        try source.feed(update);
        const frame = try renderer.draw(alloc, &scene, id, source);
        try std.testing.expect(frame.len < 4000);
        try destination.feed(frame);
        const expected = try source.plainText(alloc);
        defer alloc.free(expected);
        const actual = try destination.plainText(alloc);
        defer alloc.free(actual);
        const a = try visualText(alloc, expected);
        defer alloc.free(a);
        const b = try visualText(alloc, actual);
        defer alloc.free(b);
        try std.testing.expectEqualStrings(a, b);
        var state: vt.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &destination.terminal);
        const range = state.rowDataRange();
        const source_range = renderer.state.rowDataRange();
        for (range.start..range.end, source_range.start..) |ri, si| {
            const actual_cells = state.row_data.items(.cells)[ri];
            const source_cells = renderer.state.row_data.items(.cells)[si];
            for (actual_cells.items(.raw), source_cells.items(.raw), 0..) |ac, sc, x| {
                var aw: std.Io.Writer.Allocating = .init(alloc);
                defer aw.deinit();
                var sw: std.Io.Writer.Allocating = .init(alloc);
                defer sw.deinit();
                try Renderer.colors(&aw.writer, if (ac.hasStyling()) actual_cells.items(.style)[x] else .{}, ac);
                try Renderer.colors(&sw.writer, if (sc.hasStyling()) source_cells.items(.style)[x] else .{}, sc);
                try std.testing.expectEqualStrings(sw.written(), aw.written());
            }
        }
    }
    try source.feed("\x1b[3;7H");
    const cursor_frame = try renderer.draw(alloc, &scene, id, source);
    try std.testing.expect(cursor_frame.len < 150);
    try destination.feed(cursor_frame);
    try std.testing.expectEqual(source.terminal.screens.active.cursor.x, destination.terminal.screens.active.cursor.x);
    try std.testing.expectEqual(source.terminal.screens.active.cursor.y, destination.terminal.screens.active.cursor.y);
}

test "warmed text redraws reuse storage without allocations" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = counting.allocator();
    var context: u8 = 0;
    const source = try terminal.Surface.create(std.testing.io, alloc, .{ .columns = 80, .rows = 24 }, .{ .context = &context, .write = discard });
    defer source.destroy();
    var scene = try core.Scene.init(try core.Rect.init(0, 0, 80, 24));
    const id = try scene.add(.{ .kind = .tiled });
    var renderer: Renderer = .{};
    defer renderer.deinit(alloc);
    try source.feed("\x1b[Haaaa");
    _ = try renderer.draw(alloc, &scene, id, source);
    try source.feed("\x1b[Hbbbb");
    _ = try renderer.draw(alloc, &scene, id, source);
    const allocations = counting.allocations;
    const allocated_bytes = counting.allocated_bytes;
    const deallocations = counting.deallocations;
    for (0..20) |i| {
        try source.feed(if (i % 2 == 0) "\x1b[Haaaa" else "\x1b[Hbbbb");
        const frame = try renderer.draw(alloc, &scene, id, source);
        try std.testing.expect(std.mem.indexOf(u8, frame, if (i % 2 == 0) "aaaa" else "bbbb") != null);
    }
    try std.testing.expectEqual(allocations, counting.allocations);
    try std.testing.expectEqual(allocated_bytes, counting.allocated_bytes);
    try std.testing.expectEqual(deallocations, counting.deallocations);
    // An explicit repaint must still emit text while retaining the warmed buffers.
    renderer.invalidate(alloc);
    const repaint = try renderer.draw(alloc, &scene, id, source);
    try std.testing.expect(std.mem.indexOf(u8, repaint, "bbbb") != null);
    try std.testing.expectEqual(allocations, counting.allocations);
}

test "moving an opaque float restores covered text and Kitty placements" {
    const alloc = std.testing.allocator;
    var context: u8 = 0;
    const base = try terminal.Surface.create(std.testing.io, alloc, .{ .columns = 24, .rows = 6, .cell_width = 8, .cell_height = 16 }, .{ .context = &context, .write = discard });
    defer base.destroy();
    const top = try terminal.Surface.create(std.testing.io, alloc, .{ .columns = 8, .rows = 3, .cell_width = 8, .cell_height = 16 }, .{ .context = &context, .write = discard });
    defer top.destroy();
    const dest = try terminal.Surface.create(std.testing.io, alloc, base.size, .{ .context = &context, .write = discard });
    defer dest.destroy();
    var scene = try core.Scene.init(try core.Rect.init(0, 0, 24, 6));
    const base_id = try scene.add(.{ .kind = .tiled });
    const top_id = try scene.add(.{ .kind = .{ .floating = try core.Rect.init(3, 1, 8, 3) } });
    try base.feed("\x1b[2;1Habcdefghijklmnopqrstuvwx\x1b[3;5H\x1b_Ga=T,f=24,s=1,v=1,i=42;/wAA\x1b\\");
    try top.feed("FLOAT");
    var base_renderer: Renderer = .{ .framed = false };
    defer base_renderer.deinit(alloc);
    var top_renderer: Renderer = .{ .framed = false };
    defer top_renderer.deinit(alloc);
    for (0..2) |pass| {
        if (pass == 1) try scene.moveResize(top_id, try core.Rect.init(12, 2, 8, 3));
        try dest.feed("\x1b[?7l\x1b[2J");
        base_renderer.invalidate(alloc);
        top_renderer.invalidate(alloc);
        try dest.feed(try base_renderer.draw(alloc, &scene, base_id, base));
        try dest.feed(try top_renderer.draw(alloc, &scene, top_id, top));
        const text = try dest.plainText(alloc);
        defer alloc.free(text);
        if (pass == 0) {
            try std.testing.expect(std.mem.indexOf(u8, text, "abcFLOAT   lmnopqrstuvwx") != null);
            try std.testing.expectEqual(@as(u32, 0), dest.terminal.screens.active.kitty_images.placements.count());
        } else {
            try std.testing.expect(std.mem.indexOf(u8, text, "abcdefghijklmnopqrstuvwx") != null);
            try std.testing.expectEqual(@as(u32, 1), dest.terminal.screens.active.kitty_images.placements.count());
        }
    }
}

test "border cells remain separate from terminal content" {
    const alloc = std.testing.allocator;
    var context: u8 = 0;
    const source = try terminal.Surface.create(std.testing.io, alloc, .{ .columns = 4, .rows = 2 }, .{ .context = &context, .write = discard });
    defer source.destroy();
    const dest = try terminal.Surface.create(std.testing.io, alloc, .{ .columns = 6, .rows = 4 }, .{ .context = &context, .write = discard });
    defer dest.destroy();
    var scene = try core.Scene.init(try core.Rect.init(0, 0, 6, 4));
    const id = try scene.add(.{ .kind = .tiled });
    try scene.setFocus(id);
    var renderer: Renderer = .{ .framed = false, .bordered = true };
    defer renderer.deinit(alloc);
    try source.feed("abcd\r\nefgh");
    try dest.feed("\x1b[?7l");
    try dest.feed(try renderer.draw(alloc, &scene, id, source));
    var border: std.Io.Writer.Allocating = .init(alloc);
    defer border.deinit();
    try decoration.draw(&border.writer, &scene, id, null);
    try dest.feed(border.written());
    const text = try dest.plainText(alloc);
    defer alloc.free(text);
    try std.testing.expectEqualStrings("┌────┐\n│abcd│\n│efgh│\n└────┘", text);
    try std.testing.expectEqual(try core.Rect.init(0, 0, 2, 2), decoration.content(try core.Rect.init(0, 0, 2, 2)));
}

test "preview tint preserves Unicode and styles and restores unchanged cells" {
    const alloc = std.testing.allocator;
    var context: u8 = 0;
    const size: terminal.Size = .{ .columns = 24, .rows = 4, .cell_width = 8, .cell_height = 16 };
    const source = try terminal.Surface.create(std.testing.io, alloc, size, .{ .context = &context, .write = discard });
    defer source.destroy();
    const destination = try terminal.Surface.create(std.testing.io, alloc, size, .{ .context = &context, .write = discard });
    defer destination.destroy();
    var scene = try core.Scene.init(try core.Rect.init(0, 0, 24, 4));
    const id = try scene.add(.{ .kind = .tiled });
    var renderer: Renderer = .{ .framed = false };
    defer renderer.deinit(alloc);
    try source.feed("\x1b[1;38;2;200;100;50;48;2;40;60;80mA世界 e\xcc\x81\x1b[7mI\x1b[0m\r\n\x1b[44m\x1b[2Kpalette\x1b[0m");
    try destination.feed(try renderer.draw(alloc, &scene, id, source));
    const before = try destination.plainText(alloc);
    defer alloc.free(before);
    renderer.tint = .{ .bounds = try core.Rect.init(0, 0, 12, 4) };
    try destination.feed(try renderer.draw(alloc, &scene, id, source));
    const tinted = try destination.plainText(alloc);
    defer alloc.free(tinted);
    try std.testing.expectEqualStrings(before, tinted);
    var state: vt.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &destination.terminal);
    const style = state.row_data.items(.cells)[state.rowDataRange().start].items(.style)[0];
    try std.testing.expect(style.flags.bold);
    try std.testing.expectEqual(vt.color.RGB{ .r = 50, .g = 73, .b = 93 }, style.bg_color.rgb);
    try std.testing.expect(state.row_data.items(.cells)[state.rowDataRange().start].items(.style)[7].flags.inverse);
    renderer.tint.?.bounds.x = 12;
    try destination.feed(try renderer.draw(alloc, &scene, id, source));
    try state.update(alloc, &destination.terminal);
    try std.testing.expectEqual(vt.color.RGB{ .r = 40, .g = 60, .b = 80 }, state.row_data.items(.cells)[state.rowDataRange().start].items(.style)[0].bg_color.rgb);
    // A preview must not mutate the source; removing it repaints even with no PTY output.
    renderer.tint = null;
    try destination.feed(try renderer.draw(alloc, &scene, id, source));
    try state.update(alloc, &destination.terminal);
    const restored = state.row_data.items(.cells)[state.rowDataRange().start].items(.style)[0];
    try std.testing.expectEqual(vt.color.RGB{ .r = 40, .g = 60, .b = 80 }, restored.bg_color.rgb);
    const after = try destination.plainText(alloc);
    defer alloc.free(after);
    try std.testing.expectEqualStrings(before, after);
}
