//! Terminal-specific state. The geometry core never imports this module.
const std = @import("std");
const vt = @import("ghostty-vt");
const core = @import("compositor");
const wuffs = @import("wuffs");

fn decodePng(allocator: std.mem.Allocator, bytes: []const u8) vt.sys.DecodeError!vt.sys.Image {
    const image = wuffs.png.decode(allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
    return .{ .width = image.width, .height = image.height, .data = image.data };
}

pub const Size = struct {
    columns: u16,
    rows: u16,
    /// Zero for both means the host has not measured pixel geometry yet.
    cell_width: u16 = 0,
    cell_height: u16 = 0,
};
pub const Sink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) anyerror!void,
    /// Reports borrow parser memory and must be consumed or copied synchronously.
    status: ?*const fn (*anyopaque, vt.osc.Command.ProgramStatus.Report) void = null,
};

/// Heap-pinned because the stream handler borrows the terminal's address.
/// Single-threaded. Host owns PTY I/O, window mapping, and rendering.
pub const Surface = struct {
    allocator: std.mem.Allocator,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    sink: Sink,
    size: Size,
    revision: u64 = 0,
    viewport_revision: u64 = 0,
    output_error: ?anyerror = null,

    pub fn create(io: std.Io, allocator: std.mem.Allocator, size: Size, sink: Sink) !*Surface {
        return createWithHistory(io, allocator, size, sink, 0);
    }

    pub fn createWithHistory(io: std.Io, allocator: std.mem.Allocator, size: Size, sink: Sink, limit: usize) !*Surface {
        try validate(size);
        // This host is single-threaded; initialize the library-wide decoder before feeding.
        vt.sys.decode_png = decodePng;
        const self = try allocator.create(Surface);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .terminal = try vt.Terminal.init(io, allocator, .{
                .cols = size.columns,
                .rows = size.rows,
                .max_scrollback_bytes = limit,
                .kitty_image_storage_limit = 16 * 1024 * 1024,
            }),
            .stream = undefined,
            .sink = sink,
            .size = size,
        };
        errdefer self.terminal.deinit(allocator);
        try self.terminal.resize(allocator, .{
            .cols = size.columns,
            .rows = size.rows,
            .cell_size_px = if (size.cell_width == 0) null else .{ .width = size.cell_width, .height = size.cell_height },
        });
        var handler = vt.TerminalStream.Handler.init(&self.terminal);
        handler.effects = .readonly;
        handler.effects.write_pty = writeReply;
        handler.effects.size = reportSize;
        handler.effects.device_attributes = deviceAttributes;
        if (sink.status != null) handler.effects.program_status = reportStatus;
        self.stream = .init(.{ .handler = handler, .allocator = allocator });
        return self;
    }

    pub fn destroy(self: *Surface) void {
        self.stream.deinit();
        self.terminal.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn validate(size: Size) !void {
        if (size.columns == 0 or size.rows == 0 or (size.cell_width == 0) != (size.cell_height == 0))
            return error.InvalidSize;
    }

    pub fn feed(self: *Surface, bytes: []const u8) !void {
        if (self.output_error) |err| return err;
        self.stream.nextSlice(bytes);
        self.revision +%= 1;
        if (self.output_error) |err| return err;
        if (self.stream.handler.semantic_failure) return error.TerminalStateFailure;
    }

    /// Returns whether content dimensions changed. Translation alone has no effect.
    /// A zero-area window retains its last valid terminal dimensions while hidden.
    pub fn applyBounds(self: *Surface, bounds: core.Rect) !bool {
        _ = try core.Rect.init(bounds.x, bounds.y, bounds.w, bounds.h);
        if (bounds.empty()) return false;
        if (bounds.w > std.math.maxInt(u16) or bounds.h > std.math.maxInt(u16)) return error.InvalidSize;
        var size = self.size;
        size.columns = @intCast(bounds.w);
        size.rows = @intCast(bounds.h);
        return self.resize(size);
    }

    pub fn resize(self: *Surface, size: Size) !bool {
        try validate(size);
        if (std.meta.eql(size, self.size)) return false;
        if (self.output_error) |err| return err;
        try self.stream.handler.resize(.{
            .cols = size.columns,
            .rows = size.rows,
            .cell_size_px = if (size.cell_width == 0) null else .{ .width = size.cell_width, .height = size.cell_height },
        });
        self.size = size;
        self.revision +%= 1;
        if (self.output_error) |err| return err;
        return true;
    }

    pub fn scroll(self: *Surface, behavior: vt.Terminal.ScrollViewport) void {
        self.terminal.scrollViewport(behavior);
        self.viewport_revision +%= 1;
        self.revision +%= 1;
    }

    pub fn selectAt(self: *Surface, x: u16, y: u16, extend: bool) !void {
        const screen = self.terminal.screens.active;
        const pin = screen.pages.pin(.{ .viewport = .{ .x = x, .y = y } }) orelse return;
        const start = if (extend) (if (screen.selection) |sel| sel.start() else pin) else pin;
        try screen.select(vt.Selection.init(start, pin, false));
        self.revision +%= 1;
    }

    pub fn clearSelection(self: *Surface) void {
        if (self.terminal.screens.active.selection == null) return;
        self.terminal.screens.active.clearSelection();
        self.revision +%= 1;
    }

    pub fn selectionText(self: *Surface, a: std.mem.Allocator) !?[:0]const u8 {
        const screen = self.terminal.screens.active;
        const selection = screen.selection orelse return null;
        return try screen.selectionString(a, .{ .sel = selection, .trim = false });
    }

    pub fn plainText(self: *Surface, allocator: std.mem.Allocator) ![]const u8 {
        return self.terminal.plainString(allocator);
    }

    fn owner(handler: *vt.TerminalStream.Handler) *Surface {
        return @fieldParentPtr("terminal", handler.terminal);
    }
    fn writeReply(handler: *vt.TerminalStream.Handler, bytes: []const u8) void {
        const self = owner(handler);
        if (self.output_error != null) return;
        self.sink.write(self.sink.context, bytes) catch |err| {
            self.output_error = err;
        };
    }
    fn reportSize(handler: *vt.TerminalStream.Handler) ?vt.size_report.Size {
        const size = owner(handler).size;
        if (size.cell_width == 0) return null;
        return .{ .columns = size.columns, .rows = size.rows, .cell_width = size.cell_width, .cell_height = size.cell_height };
    }
    fn reportStatus(handler: *vt.TerminalStream.Handler, report: vt.osc.Command.ProgramStatus.Report) void {
        const self = owner(handler);
        if (self.sink.status) |callback| callback(self.sink.context, report);
    }
    fn deviceAttributes(_: *vt.TerminalStream.Handler) vt.device_attributes.Attributes {
        return .{};
    }
};

const Capture = struct {
    bytes: std.ArrayList(u8) = .empty,
    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *Capture = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(std.testing.allocator, bytes);
    }
    fn sink(self: *Capture) Sink {
        return .{ .context = self, .write = write };
    }
    fn deinit(self: *Capture) void {
        self.bytes.deinit(std.testing.allocator);
    }
};

test "screen state survives split input, alternate screen, and geometry changes" {
    var output: Capture = .{};
    defer output.deinit();
    const surface = try Surface.create(std.testing.io, std.testing.allocator, .{ .columns = 20, .rows = 5, .cell_width = 8, .cell_height = 16 }, output.sink());
    defer surface.destroy();
    try surface.feed("hello \xe4\xb8");
    try surface.feed("\x96\xe7\x95\x8c");
    try surface.feed("\x1b[?1049hother\x1b[?1049l");
    const text = try surface.plainText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello 世界", text);
    try std.testing.expect(!try surface.applyBounds(try core.Rect.init(40, 50, 20, 5)));
    try std.testing.expect(try surface.applyBounds(try core.Rect.init(0, 0, 30, 8)));
    try std.testing.expect(!try surface.applyBounds(try core.Rect.init(0, 0, 0, 0)));
    try std.testing.expectEqual(@as(u16, 30), surface.size.columns);
}

test "terminal queries return through the owning surface sink" {
    var output: Capture = .{};
    defer output.deinit();
    const surface = try Surface.create(std.testing.io, std.testing.allocator, .{ .columns = 20, .rows = 5, .cell_width = 8, .cell_height = 16 }, output.sink());
    defer surface.destroy();
    try surface.feed("hi\x1b[6n\x1b[18t");
    try std.testing.expectEqualStrings("\x1b[1;3R\x1b[8;5;20t", output.bytes.items);
}

test "Kitty direct image bytes and placements are retained and deleted" {
    var output: Capture = .{};
    defer output.deinit();
    const surface = try Surface.create(std.testing.io, std.testing.allocator, .{ .columns = 20, .rows = 5, .cell_width = 8, .cell_height = 16 }, output.sink());
    defer surface.destroy();
    try surface.feed("\x1b_Ga=T,f=24,s=1,v=1,i=42;/wAA\x1b\\");
    const storage = &surface.terminal.screens.active.kitty_images;
    const image = storage.imageById(42) orelse return error.ImageMissing;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, image.data.complete);
    try std.testing.expect(storage.placements.count() > 0);
    try surface.feed("\x1b_Ga=d,d=I,i=42;\x1b\\");
    try std.testing.expect(storage.imageById(42) == null);
}

test "chunked Kitty PNG uses the installed decoder" {
    var output: Capture = .{};
    defer output.deinit();
    const surface = try Surface.create(std.testing.io, std.testing.allocator, .{ .columns = 20, .rows = 5, .cell_width = 8, .cell_height = 16 }, output.sink());
    defer surface.destroy();
    try surface.feed("\x1b_Ga=T,f=100,i=7,m=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ\x1b\\");
    try std.testing.expect(surface.terminal.screens.active.kitty_images.imageById(7) == null);
    try surface.feed("\x1b_Gm=0;AAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\");
    const image = surface.terminal.screens.active.kitty_images.imageById(7) orelse return error.ImageMissing;
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.data.complete);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes.items, "i=7;OK") != null);
}

test "OSC 7501 reports go to the owning callback; other surfaces stay independent" {
    const Observer = struct {
        output: Capture = .{},
        state: ?vt.osc.Command.ProgramStatus.State = null,
        fn write(context: *anyopaque, bytes: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try self.output.bytes.appendSlice(std.testing.allocator, bytes);
        }
        fn status(context: *anyopaque, report: vt.osc.Command.ProgramStatus.Report) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.state = report.state;
        }
    };
    var observer: Observer = .{};
    defer observer.output.deinit();
    var other_output: Capture = .{};
    defer other_output.deinit();
    const a = try Surface.create(std.testing.io, std.testing.allocator, .{ .columns = 20, .rows = 5, .cell_width = 8, .cell_height = 16 }, .{
        .context = &observer,
        .write = Observer.write,
        .status = Observer.status,
    });
    defer a.destroy();
    const b = try Surface.create(std.testing.io, std.testing.allocator, .{ .columns = 20, .rows = 5, .cell_width = 8, .cell_height = 16 }, other_output.sink());
    defer b.destroy();
    try a.feed("left\x1b]7501;state=working\x1b\\\x1b]7501;?\x1b\\");
    try b.feed("right\x1b]7501;?\x1b\\");
    try std.testing.expectEqual(vt.osc.Command.ProgramStatus.State.working, observer.state.?);
    try std.testing.expect(observer.output.bytes.items.len > 0);
    try std.testing.expectEqual(@as(usize, 0), other_output.bytes.items.len);
    const text = try b.plainText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("right", text);
}

test "reply failures reach the host instead of silently losing protocol bytes" {
    const Broken = struct {
        fn write(_: *anyopaque, _: []const u8) !void {
            return error.SinkClosed;
        }
    };
    var context: u8 = 0;
    const surface = try Surface.create(std.testing.io, std.testing.allocator, .{ .columns = 20, .rows = 5, .cell_width = 8, .cell_height = 16 }, .{ .context = &context, .write = Broken.write });
    defer surface.destroy();
    try std.testing.expectError(error.SinkClosed, surface.feed("\x1b[6n"));
    try std.testing.expectError(error.SinkClosed, surface.feed("later"));
}

test "resize sends negotiated in-band size reports and preserves valid state on rejection" {
    var output: Capture = .{};
    defer output.deinit();
    const surface = try Surface.create(std.testing.io, std.testing.allocator, .{ .columns = 20, .rows = 5, .cell_width = 8, .cell_height = 16 }, output.sink());
    defer surface.destroy();
    try surface.feed("\x1b[?2048h");
    output.bytes.clearRetainingCapacity();
    _ = try surface.resize(.{ .columns = 30, .rows = 10, .cell_width = 8, .cell_height = 16 });
    try std.testing.expectEqualStrings("\x1b[48;10;30;160;240t", output.bytes.items);
    try std.testing.expectError(error.InvalidSize, surface.resize(.{ .columns = 0, .rows = 1 }));
    try std.testing.expectEqual(@as(u16, 30), surface.size.columns);
}
